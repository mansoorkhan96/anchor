import Foundation
import Testing
@testable import Drift

/// A fresh temp folder per test; tests never touch the user's Downloads or library.
func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "DriftCleanupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct FileStampTests {
    @Test func sameFileAndRenameKeepTheStamp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.bin")
        try Data("hello".utf8).write(to: a)
        let first = try #require(FileStamp.read(a))
        #expect(FileStamp.read(a) == first)
        #expect(first.size == 5)
        let b = dir.appending(path: "b.bin")
        try FileManager.default.moveItem(at: a, to: b)
        #expect(FileStamp.read(b) == first)
    }

    @Test func rewritingWithSameSizeChangesTheStamp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.bin")
        try Data("aaaa".utf8).write(to: a)
        let before = try #require(FileStamp.read(a))
        try Data("bbbb".utf8).write(to: a, options: .atomic)
        let after = try #require(FileStamp.read(a))
        #expect(after != before)
        #expect(after.size == before.size)
    }

    @Test func nilForSymlinkFolderAndMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "real.bin")
        try Data("x".utf8).write(to: target)
        let link = dir.appending(path: "link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let folder = dir.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FileStamp.read(link) == nil)
        #expect(FileStamp.read(folder) == nil)
        #expect(FileStamp.read(dir.appending(path: "missing.bin")) == nil)
        #expect(FileStamp.read(target) != nil)
    }

    @Test func survivesJSONRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.bin")
        try Data("hello".utf8).write(to: a)
        let stamp = try #require(FileStamp.read(a))
        let back = try JSONDecoder().decode(FileStamp.self, from: JSONEncoder().encode(stamp))
        #expect(back == stamp)
        #expect(FileStamp.read(a) == back)
    }
}

@Suite struct CleanupDecodingTests {
    @Test func oldItemsDecodeWithoutNewFields() throws {
        let old = """
        {"id":"7E1B68C6-35D8-44D6-8C12-B179B025D8BD","kind":"http","url":"https://a.com/x.dmg","fileName":"x.dmg",
         "directory":"file:///tmp/","category":"apps","receivedBytes":10,"segments":[],"supportsRanges":true,
         "state":{"completed":{}},"createdAt":800000000,"openWhenDone":false,"headers":{}}
        """
        let item = try JSONDecoder().decode(DownloadItem.self, from: Data(old.utf8))
        #expect(item.state == .completed)
        #expect(item.keep == nil)
        #expect(item.stamp == nil)
        #expect(item.stampIsBaseline == nil)
        #expect(item.openedAt == nil)
        #expect(item.archivedAt == nil)
        #expect(item.archivedFrom == nil)
        #expect(item.archivedName == nil)
        #expect(item.pendingMove == nil)
        #expect(item.installer == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        let stamp = FileStamp(volume: "V", fileID: 42, created: Date(timeIntervalSince1970: 1_000.25),
                              modified: Date(timeIntervalSince1970: 2_000.125), size: 99)
        var item = DownloadItem(url: URL(string: "https://a.com/x.dmg")!, fileName: "x.dmg",
                                directory: URL(filePath: "/tmp"), category: .apps)
        item.keep = true
        item.stamp = stamp
        item.stampIsBaseline = true
        item.openedAt = Date(timeIntervalSince1970: 3_000)
        item.archivedAt = Date(timeIntervalSince1970: 4_000)
        item.archivedFrom = "/tmp/from"
        item.archivedName = "old.dmg"
        item.pendingMove = PendingMove(kind: .restore, from: "/a", to: "/b", stamp: stamp)
        item.installer = InstallerInfo(stamp: stamp, bundleID: "com.x", version: "1.2", failed: false)
        let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(back.keep == true)
        #expect(back.stamp == stamp)
        #expect(back.stampIsBaseline == true)
        #expect(back.openedAt == item.openedAt)
        #expect(back.archivedAt == item.archivedAt)
        #expect(back.archivedFrom == "/tmp/from")
        #expect(back.archivedName == "old.dmg")
        #expect(back.pendingMove == item.pendingMove)
        #expect(back.installer == item.installer)
    }
}

@Suite struct LibraryWriterTests {
    @Test func lowerSeqAfterHigherIsIgnored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "lib.json")
        let writer = LibraryWriter(url: url)
        writer.enqueue(Data("new".utf8), seq: 2) { _ in }
        writer.enqueue(Data("old".utf8), seq: 1) { _ in }
        #expect(writer.writeNowSync(Data("old again".utf8), seq: 1))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }

    @Test func writeNowSyncLandsAfterQueuedWrites() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "lib.json")
        let writer = LibraryWriter(url: url) { data, url in
            Thread.sleep(forTimeInterval: 0.05)
            try data.write(to: url, options: .atomic)
        }
        for seq in 1...3 { writer.enqueue(Data("queued \(seq)".utf8), seq: seq) { _ in } }
        #expect(writer.writeNowSync(Data("final".utf8), seq: 4))
        #expect(try String(contentsOf: url, encoding: .utf8) == "final")
    }

    @Test func failedWriteReportsFalse() throws {
        let writer = LibraryWriter(url: URL(filePath: "/nonexistent/lib.json")) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        #expect(!writer.writeNowSync(Data("x".utf8), seq: 1))
    }
}

@Suite struct SaveTrackerTests {
    @Test func olderSaveFinishingLateLeavesStoreDirty() {
        var tracker = SaveTracker()
        tracker.changed()
        let first = tracker.beginSave()
        tracker.changed()
        tracker.finished(first, success: true)
        #expect(tracker.isDirty)
        let second = tracker.beginSave()
        #expect(second.seq > first.seq)
        tracker.finished(second, success: true)
        #expect(!tracker.isDirty)
        tracker.finished(first, success: true)
        #expect(!tracker.isDirty)
    }

    @Test func failedSaveLeavesStoreDirty() {
        var tracker = SaveTracker()
        tracker.changed()
        let save = tracker.beginSave()
        tracker.finished(save, success: false)
        #expect(tracker.isDirty)
    }

    @Test func successfulSaveCleans() {
        var tracker = SaveTracker()
        #expect(!tracker.isDirty)
        tracker.changed()
        #expect(tracker.isDirty)
        let save = tracker.beginSave()
        tracker.finished(save, success: true)
        #expect(!tracker.isDirty)
    }
}

@Suite struct CleanupSettingsTests {
    @Test func cleanupDaysRoundTripThroughDefaults() throws {
        let name = "DriftCleanupTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppSettings.loadCleanupDays(from: defaults).isEmpty)
        AppSettings.storeCleanupDays([.video: 30, .apps: 7, .music: 0], in: defaults)
        #expect(AppSettings.loadCleanupDays(from: defaults) == [.video: 30, .apps: 7])
        defaults.set(["video": 14, "bogus": 3, "other": -5], forKey: "cleanupDays")
        #expect(AppSettings.loadCleanupDays(from: defaults) == [.video: 14])
    }
}

/// Shared fixtures for the pure rule tests (no disk access).
enum Fixture {
    static let base = Date(timeIntervalSince1970: 1_000_000)
    static let day: TimeInterval = 86_400
    static let stamp = FileStamp(volume: "VOL", fileID: 7, created: base, modified: base, size: 100)

    static func item(_ name: String = "movie.mp4", category: FileCategory = .video, completed: Date = base) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://a.com/\(name)")!, fileName: name,
                                directory: URL(filePath: "/tmp/drift-fixture"), category: category)
        item.state = .completed
        item.createdAt = completed
        item.completedAt = completed
        item.stamp = stamp
        return item
    }

    static func installer(version: String = "1.9") -> DownloadItem {
        var item = item("App.dmg", category: .apps)
        item.installer = InstallerInfo(stamp: stamp, bundleID: "com.example.app", version: version, failed: false)
        return item
    }

    static let archiveFacts = ArchiveFacts(current: stamp, archiveVolume: "VOL", installedVersions: ["1.9"],
                                           mounted: false, sharedPath: false)
}

@Suite struct CleanupReasonTests {
    let now = Fixture.base.addingTimeInterval(100 * Fixture.day)

    func reason(_ item: DownloadItem, days: Int = 30, current: FileStamp? = Fixture.stamp, lastUsed: Date? = nil,
                shared: Bool = false, now: Date? = nil) -> CleanupReason? {
        CleanupRules.reason(for: item, now: now ?? self.now, days: days, current: current, lastUsed: lastUsed, sharedPath: shared)
    }

    @Test func oldUnusedFileIsSuggested() {
        let result = reason(Fixture.item())
        #expect(result?.text == "No recorded use in 100 days")
        #expect(result?.days == 100)
    }

    @Test func exclusions() {
        var notDone = Fixture.item(); notDone.state = .paused
        var seeding = Fixture.item(); seeding.seeding = true
        var kept = Fixture.item(); kept.keep = true
        var pending = Fixture.item()
        pending.pendingMove = PendingMove(kind: .archive, from: "/a", to: "/b", stamp: Fixture.stamp)
        var noStamp = Fixture.item(); noStamp.stamp = nil
        var torrent = Fixture.item(); torrent.kind = .torrent
        var edited = Fixture.stamp; edited.modified = Fixture.base.addingTimeInterval(1)

        #expect(reason(notDone) == nil)
        #expect(reason(seeding) == nil)
        #expect(reason(kept) == nil)
        #expect(reason(pending) == nil)
        #expect(reason(noStamp) == nil)
        #expect(reason(Fixture.item(), current: nil) == nil, "missing file")
        #expect(reason(torrent, current: nil) == nil, "torrent folder has no file stamp")
        #expect(reason(torrent) != nil, "single-file torrent")
        #expect(reason(Fixture.item(), shared: true) == nil)
        #expect(reason(Fixture.item(), days: 0) == nil, "Never")
        #expect(reason(Fixture.item(), current: edited) == nil, "file changed since download")
    }

    @Test func dayBoundary() {
        let boundary = Fixture.base.addingTimeInterval(30 * Fixture.day)
        #expect(reason(Fixture.item(), now: boundary) != nil)
        #expect(reason(Fixture.item(), now: boundary.addingTimeInterval(-1)) == nil)
    }

    @Test func recentActivityOfAnyKindBlocks() {
        let recent = now.addingTimeInterval(-2 * Fixture.day)
        var opened = Fixture.item(); opened.openedAt = recent
        var archived = Fixture.item(); archived.archivedAt = recent
        var touched = Fixture.stamp; touched.modified = recent
        var touchedItem = Fixture.item(); touchedItem.stamp = touched
        let recentlyDone = Fixture.item(completed: recent)

        #expect(reason(Fixture.item(), lastUsed: recent) == nil, "Spotlight last used")
        #expect(reason(opened) == nil, "opened from Drift")
        #expect(reason(archived) == nil, "archive clock starts at archivedAt")
        #expect(reason(touchedItem, current: touched) == nil, "modification date")
        #expect(reason(recentlyDone) == nil)
        #expect(reason(Fixture.item(), lastUsed: Fixture.base.addingTimeInterval(-Fixture.day)) != nil, "older dates don't block")
    }
}

@Suite struct ShouldArchiveTests {
    let now = Fixture.base.addingTimeInterval(2 * Fixture.day)

    func check(_ item: DownloadItem, enabled: Bool = true, facts: ArchiveFacts = Fixture.archiveFacts, now: Date? = nil) -> Bool {
        CleanupRules.shouldArchive(item, now: now ?? self.now, enabled: enabled, facts: facts)
    }

    @Test func happyPath() {
        #expect(check(Fixture.installer()))
    }

    @Test func itemConditions() {
        var pkg = Fixture.installer(); pkg.fileName = "App.pkg"
        var notApps = Fixture.installer(); notApps.category = .other
        var torrent = Fixture.installer(); torrent.kind = .torrent
        var notDone = Fixture.installer(); notDone.state = .paused
        var kept = Fixture.installer(); kept.keep = true
        var archived = Fixture.installer(); archived.archivedAt = Fixture.base
        var pending = Fixture.installer()
        pending.pendingMove = PendingMove(kind: .archive, from: "/a", to: "/b", stamp: Fixture.stamp)
        var noStamp = Fixture.installer(); noStamp.stamp = nil
        var baseline = Fixture.installer(); baseline.stampIsBaseline = true
        var noCompletion = Fixture.installer(); noCompletion.completedAt = nil

        #expect(!check(Fixture.installer(), enabled: false))
        for item in [pkg, notApps, torrent, notDone, kept, archived, pending, noStamp, baseline, noCompletion] {
            #expect(!check(item), "\(item.fileName)")
        }
        #expect(!check(Fixture.installer(), now: Fixture.base.addingTimeInterval(23 * 3600)), "24 hour grace period")
        #expect(check(Fixture.installer(), now: Fixture.base.addingTimeInterval(24 * 3600)))
    }

    @Test func fileAndInstallerConditions() {
        var other = Fixture.stamp; other.fileID = 8
        var facts = Fixture.archiveFacts
        facts.current = other
        #expect(!check(Fixture.installer(), facts: facts), "stamp mismatch")
        facts = Fixture.archiveFacts; facts.current = nil
        #expect(!check(Fixture.installer(), facts: facts), "missing file")
        facts = Fixture.archiveFacts; facts.archiveVolume = "OTHER"
        #expect(!check(Fixture.installer(), facts: facts), "different volume")
        facts = Fixture.archiveFacts; facts.archiveVolume = nil
        #expect(!check(Fixture.installer(), facts: facts), "unknown volume")
        facts = Fixture.archiveFacts; facts.sharedPath = true
        #expect(!check(Fixture.installer(), facts: facts), "shared path")
        facts = Fixture.archiveFacts; facts.mounted = true
        #expect(!check(Fixture.installer(), facts: facts), "mounted")
        facts = Fixture.archiveFacts; facts.installedVersions = []
        #expect(!check(Fixture.installer(), facts: facts), "not installed")

        var stale = Fixture.installer(); stale.installer?.stamp = other
        var failed = Fixture.installer(); failed.installer?.failed = true
        var noBundle = Fixture.installer(); noBundle.installer?.bundleID = nil
        var noVersion = Fixture.installer(); noVersion.installer?.version = nil
        var notInspected = Fixture.installer(); notInspected.installer = nil
        for item in [stale, failed, noBundle, noVersion, notInspected] { #expect(!check(item)) }
    }

    @Test func versionComparison() {
        var facts = Fixture.archiveFacts
        facts.installedVersions = ["1.10"]
        #expect(check(Fixture.installer(version: "1.9"), facts: facts), "1.10 >= 1.9")
        facts.installedVersions = ["1.9"]
        #expect(!check(Fixture.installer(version: "1.10"), facts: facts), "older installed")
        facts.installedVersions = ["1.2", "2.0"]
        #expect(check(Fixture.installer(version: "1.10"), facts: facts), "any installed copy new enough")
        #expect(CleanupRules.isInstalled(version: "124.3", installed: ["124.5"]))
        #expect(!CleanupRules.isInstalled(version: "124.5", installed: ["124.3"]))
    }
}

@Suite struct CleanupLockAndRecoveryTests {
    var pending: PendingMove { PendingMove(kind: .archive, from: "/d/App.dmg", to: "/d/Drift Archive/2026-10 October/App.dmg", stamp: Fixture.stamp) }

    @Test func storeMethodsSkipLockedItems() {
        var locked = Fixture.item("a.mp4"); locked.pendingMove = pending
        let free = Fixture.item("b.mp4")
        #expect(CleanupRules.unlocked([locked.id, free.id, UUID()], in: [locked, free]) == [free.id])
    }

    @Test func missingFiles() {
        var pendingItem = Fixture.item(); pendingItem.pendingMove = pending
        var paused = Fixture.item(); paused.state = .paused
        #expect(CleanupRules.isMissing(Fixture.item(), directoryExists: true, fileExists: false))
        #expect(!CleanupRules.isMissing(Fixture.item(), directoryExists: false, fileExists: false), "unmounted drive")
        #expect(!CleanupRules.isMissing(Fixture.item(), directoryExists: true, fileExists: true))
        #expect(!CleanupRules.isMissing(pendingItem, directoryExists: true, fileExists: false))
        #expect(!CleanupRules.isMissing(paused, directoryExists: true, fileExists: false))
    }

    @Test func reconcileCompletedNotDoneAndUnknown() {
        var other = Fixture.stamp; other.fileID = 99
        let move = pending
        #expect(CleanupRules.reconcile(move) { $0 == move.to ? Fixture.stamp : nil } == .completed)
        #expect(CleanupRules.reconcile(move) { $0 == move.from ? Fixture.stamp : nil } == .notMoved)
        #expect(CleanupRules.reconcile(move) { _ in nil } == .unknown)
        #expect(CleanupRules.reconcile(move) { _ in other } == .unknown)
        // Moved, then a different file appeared at the old path: the entry follows the moved file only.
        #expect(CleanupRules.reconcile(move) { $0 == move.to ? Fixture.stamp : other } == .completed)
    }

    @Test func applyArchiveAndRestore() {
        var item = Fixture.installer()
        item.directory = URL(filePath: "/d")
        item.pendingMove = pending
        let now = Fixture.base
        CleanupRules.applyMove(pending, to: &item, now: now)
        #expect(item.directory.path == "/d/Drift Archive/2026-10 October")
        #expect(item.fileName == "App.dmg")
        #expect(item.archivedAt == now)
        #expect(item.archivedFrom == "/d")
        #expect(item.archivedName == "App.dmg")
        #expect(item.pendingMove == nil)

        let back = PendingMove(kind: .restore, from: pending.to, to: "/d/App (2).dmg", stamp: Fixture.stamp)
        item.pendingMove = back
        CleanupRules.applyMove(back, to: &item, now: now)
        #expect(item.directory.path == "/d")
        #expect(item.fileName == "App (2).dmg")
        #expect(item.archivedAt == nil && item.archivedFrom == nil && item.archivedName == nil)
        #expect(item.keep == true)
        #expect(item.pendingMove == nil)
    }

    @Test func archivePlanDroppedWhenAnythingChanged() {
        let item = Fixture.installer()
        #expect(CleanupRules.canLock(item, revision: 5, current: item, currentRevision: 5))
        #expect(!CleanupRules.canLock(item, revision: 5, current: item, currentRevision: 6), "revision changed")
        #expect(!CleanupRules.canLock(item, revision: 5, current: nil, currentRevision: 5), "removed")
        var moved = item; moved.directory = URL(filePath: "/elsewhere")
        var renamed = item; renamed.fileName = "Other.dmg"
        var kept = item; kept.keep = true
        var archived = item; archived.archivedAt = Fixture.base
        var locked = item; locked.pendingMove = pending
        var state = item; state.state = .failed("x")
        for current in [moved, renamed, kept, archived, locked, state] {
            #expect(!CleanupRules.canLock(item, revision: 5, current: current, currentRevision: 5))
        }
    }

    @Test func bannerThreshold() {
        let mb: Int64 = 1_000_000
        #expect(!CleanupRules.showsBanner(total: 400 * mb, dismissed: 0))
        #expect(CleanupRules.showsBanner(total: 600 * mb, dismissed: 0))
        #expect(!CleanupRules.showsBanner(total: 600 * mb, dismissed: 600 * mb))
        #expect(!CleanupRules.showsBanner(total: 1_000 * mb, dismissed: 600 * mb))
        #expect(CleanupRules.showsBanner(total: 1_200 * mb, dismissed: 600 * mb))
    }

    @Test func sharedPaths() {
        let a = Fixture.item("a.mp4"), b = Fixture.item("a.mp4"), c = Fixture.item("c.mp4")
        #expect(CleanupRules.sharedPaths([a, b, c]) == [a.destination.standardizedFileURL.path])
    }
}
