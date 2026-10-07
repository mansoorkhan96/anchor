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

@Suite struct CleanupScanTests {
    func write(_ name: String, in dir: URL, age: TimeInterval = 0, now: Date = Date()) throws -> URL {
        let url = dir.appending(path: name)
        try Data(repeating: 1, count: 2048).write(to: url)
        if age > 0 {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        return url
    }

    func item(_ name: String, in dir: URL, state: DownloadState = .completed, completed: Date? = nil) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://a.com/\(name)")!, fileName: name, directory: dir,
                                category: FileCategory.detect(fileName: name))
        item.state = state
        item.completedAt = completed
        if let completed { item.createdAt = completed }
        return item
    }

    @Test func leftoversSkipOwnedFreshAndOtherFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        _ = try write("owned.mp4.drift-part", in: dir, age: 7200, now: now)
        let orphan = try write("orphan.zip.drift-part", in: dir, age: 7200, now: now)
        _ = try write("fresh.zip.drift-part", in: dir, now: now)
        _ = try write("notes.txt", in: dir, age: 7200, now: now)
        let sub = dir.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try write("deep.zip.drift-part", in: sub, age: 7200, now: now)

        let owner = item("owned.mp4", in: dir, state: .paused)
        let found = Leftovers.find(in: [dir, dir], owned: [owner.partialFile.standardizedFileURL.path], now: now)
        #expect(found.map(\.path) == [orphan.standardizedFileURL.path])
        #expect(found.first?.stamp == FileStamp.read(orphan))
        #expect((found.first?.bytes ?? 0) > 0)
    }

    @Test func scanAdoptsBaselinesFindsCandidatesAndMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let old = now.addingTimeInterval(-100 * Fixture.day)
        _ = try write("legacy.mp4", in: dir, age: 100 * Fixture.day, now: now)
        _ = try write("recent.mp4", in: dir, now: now)
        _ = try write("orphan.mp4.drift-part", in: dir, age: 7200, now: now)

        let legacy = item("legacy.mp4", in: dir, completed: old)
        let recent = item("recent.mp4", in: dir, completed: old)
        let gone = item("gone.mp4", in: dir, completed: old)
        let unmounted = item("away.mp4", in: dir.appending(path: "not-mounted"), completed: old)
        var moving = item("moving.mp4", in: dir, completed: old)
        moving.pendingMove = PendingMove(kind: .archive, from: "/a", to: "/b", stamp: Fixture.stamp)

        let snapshot = CleanupSnapshot(items: [legacy, recent, gone, unmounted, moving], days: [.video: 30],
                                       revision: 3, now: now, folders: [dir])
        let result = CleanupScanner.scan(snapshot) { _ in nil }

        #expect(result.revision == 3)
        #expect(Set(result.baselines.keys) == [legacy.id, recent.id])
        #expect(result.baselines[legacy.id] == FileStamp.read(dir.appending(path: "legacy.mp4")))
        #expect(Array(result.candidates.keys) == [legacy.id])
        #expect(result.candidates[legacy.id]?.reason.days == 100)
        #expect(result.candidates[legacy.id]?.path == legacy.destination.standardizedFileURL.path)
        #expect(result.missing == [gone.id])
        #expect(result.leftovers.count == 1)

        // A baseline stamp never makes an item archivable.
        var adopted = legacy
        adopted.stamp = result.baselines[legacy.id]
        adopted.stampIsBaseline = true
        adopted.category = .apps
        adopted.fileName = "legacy.dmg"
        #expect(!CleanupRules.archiveCandidate(adopted, now: now, enabled: true))
    }

    @Test func spotlightDateBlocksAndCategoryNeverIsSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        _ = try write("old.mp4", in: dir, age: 100 * Fixture.day, now: now)
        let old = item("old.mp4", in: dir, completed: now.addingTimeInterval(-100 * Fixture.day))
        let used = CleanupScanner.scan(CleanupSnapshot(items: [old], days: [.video: 30], revision: 0, now: now, folders: [])) { _ in now }
        #expect(used.candidates.isEmpty)
        let never = CleanupScanner.scan(CleanupSnapshot(items: [old], days: [:], revision: 0, now: now, folders: [])) { _ in nil }
        #expect(never.candidates.isEmpty)
    }

    @Test func staleScanIsDiscarded() {
        let result = CleanupScanResult(revision: 4, candidates: [:], leftovers: [], missing: [], baselines: [:])
        #expect(result.isCurrent(revision: 4))
        #expect(!result.isCurrent(revision: 5), "an add during the scan bumped the revision")
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutput() async {
        let result = await ProcessRunner.run("/bin/echo", ["hi"], timeout: 5)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(String(decoding: result.data, as: UTF8.self) == "hi\n")
    }

    @Test func stdinIsEmpty() async {
        let result = await ProcessRunner.run("/bin/cat", [], timeout: 5)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.data.isEmpty)
    }

    @Test func killsOnTimeout() async {
        let start = Date()
        let result = await ProcessRunner.run("/bin/sleep", ["10"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func missingExecutableFails() async {
        let result = await ProcessRunner.run("/nonexistent/tool", [], timeout: 1)
        #expect(result.status != 0)
    }
}

@Suite struct InstallerInspectorTests {
    static let apfsContainer = "EF57347C-0000-11AA-AA11-00306543ECAC"

    func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func makeApp(_ name: String, in dir: URL, info: [String: String]) throws {
        let contents = dir.appending(path: "\(name).app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try plist(info).write(to: contents.appending(path: "Info.plist"))
    }

    @Test func picksTheImageDiskAndMountPoints() throws {
        let data = try plist(["system-entities": [
            ["dev-entry": "/dev/disk18s1", "content-hint": "Apple_APFS"],
            ["dev-entry": "/dev/disk19s1", "content-hint": "41504653-0000-11AA-AA11-00306543ECAC", "mount-point": "/tmp/m/dmg.1"],
            ["dev-entry": "/dev/disk19", "content-hint": Self.apfsContainer],
            ["dev-entry": "/dev/disk18", "content-hint": "GUID_partition_scheme"],
        ]])
        let info = try #require(InstallerInspector.parseAttach(data))
        #expect(info.root == "/dev/disk18")
        #expect(info.mountPoints == ["/tmp/m/dmg.1"])

        let hfs = try plist(["system-entities": [
            ["dev-entry": "/dev/disk7s1", "mount-point": "/tmp/m/dmg.2"], ["dev-entry": "/dev/disk7"],
        ]])
        #expect(InstallerInspector.parseAttach(hfs)?.root == "/dev/disk7")
        #expect(InstallerInspector.parseAttach(Data("junk".utf8)) == nil)
    }

    @Test func mapsAttachedImagesToTheirDisk() throws {
        let data = try plist(["images": [
            ["image-path": "/Users/x/Downloads/A.dmg", "system-entities": [["dev-entry": "/dev/disk5s1"], ["dev-entry": "/dev/disk5"]]],
            ["image-path": "/Users/x/B.dmg", "system-entities": [["dev-entry": "/dev/disk6"]]],
        ]])
        let images = try #require(InstallerInspector.attachedImages(infoPlist: data))
        #expect(images["/Users/x/Downloads/A.dmg"] == "/dev/disk5")
        #expect(images["/Users/x/B.dmg"] == "/dev/disk6")
        #expect(InstallerInspector.attachedImages(infoPlist: Data("junk".utf8)) == nil)
    }

    @Test func findsExactlyOneTopLevelApp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeApp("Foo", in: dir, info: ["CFBundleIdentifier": "com.x.foo", "CFBundleShortVersionString": "1.2"])
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "Applications"), withDestinationURL: URL(filePath: "/Applications"))
        let found = InstallerInspector.findApp(in: [dir])
        #expect(found.bundleID == "com.x.foo")
        #expect(found.version == "1.2")

        // A symlinked app (like an alias into /Applications) does not count.
        let other = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: other) }
        try makeApp("Bar", in: other, info: ["CFBundleIdentifier": "com.x.bar", "CFBundleVersion": "77"])
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "Bar.app"), withDestinationURL: other.appending(path: "Bar.app"))
        #expect(InstallerInspector.findApp(in: [dir]).bundleID == "com.x.foo")
        // CFBundleVersion fallback.
        #expect(InstallerInspector.findApp(in: [other]).version == "77")
        // Two apps across the image: unknown.
        #expect(InstallerInspector.findApp(in: [dir, other]).bundleID == nil)
        #expect(InstallerInspector.findApp(in: []).bundleID == nil)
    }

    /// Builds a small image in a temp folder (never a user's dmg), inspects it, and checks it is detached after.
    @Test(.timeLimit(.minutes(2))) func inspectsASyntheticImage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "src", directoryHint: .isDirectory)
        try makeApp("Foo", in: source, info: ["CFBundleIdentifier": "com.x.foo", "CFBundleShortVersionString": "2.5"])
        let dmg = dir.appending(path: "Foo.dmg")
        let created = await ProcessRunner.run("/usr/bin/hdiutil", ["create", "-srcfolder", source.path, "-volname", "DriftTest",
                                                                  "-format", "UDZO", "-ov", "-quiet", dmg.path], timeout: 60)
        try #require(created.status == 0)
        let stamp = try #require(FileStamp.read(dmg))

        let info = try #require(await InstallerInspector.inspect(dmg, expected: stamp))
        #expect(!info.failed)
        #expect(info.bundleID == "com.x.foo")
        #expect(info.version == "2.5")
        #expect(info.stamp == stamp)
        let attached = try #require(await InstallerInspector.attachedImages())
        #expect(attached[InstallerInspector.normalized(dmg.path)] == nil, "detached after inspection")
        #expect(await InstallerInspector.isMounted(dmg) == false)

        var other = stamp
        other.fileID += 1
        #expect(await InstallerInspector.inspect(dmg, expected: other) == nil, "changed file is skipped")
    }

    @Test func notAnImageFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appending(path: "Fake.dmg")
        try Data("not a disk image".utf8).write(to: fake)
        let stamp = try #require(FileStamp.read(fake))
        let info = try #require(await InstallerInspector.inspect(fake, expected: stamp))
        #expect(info.failed)
        #expect(info.bundleID == nil)
    }
}

@Suite struct ArchiverTests {
    struct Setup {
        let dir: URL, source: URL, archive: URL
        var item: DownloadItem
    }

    func setup() throws -> Setup {
        let dir = try makeTempDir()
        let source = dir.appending(path: "Downloads", directoryHint: .isDirectory)
        let archive = dir.appending(path: "Drift Archive/2026-10 October", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("installer".utf8).write(to: source.appending(path: "App.dmg"))
        var item = Fixture.installer()
        item.directory = source
        item.stamp = FileStamp.read(source.appending(path: "App.dmg"))
        return Setup(dir: dir, source: source, archive: archive, item: item)
    }

    func archive(_ s: inout Setup) throws {
        let target = Archiver.target(for: s.item.fileName, in: s.archive)
        let move = PendingMove(kind: .archive, from: s.item.destination.path, to: target.path, stamp: try #require(s.item.stamp))
        try Archiver.move(move).get()
        CleanupRules.applyMove(move, to: &s.item, now: Date())
    }

    @Test func archiveAndRestoreRoundTripWithCollision() throws {
        var s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        try Data("someone else".utf8).write(to: s.archive.appending(path: "App.dmg"))
        let stamp = s.item.stamp

        try archive(&s)
        #expect(s.item.fileName == "App (2).dmg")
        #expect(s.item.directory.standardizedFileURL == s.archive.standardizedFileURL)
        #expect(FileStamp.read(s.item.destination) == stamp, "a rename keeps the identity")
        #expect(!FileManager.default.fileExists(atPath: s.source.appending(path: "App.dmg").path))

        let plan = Archiver.planRestore(s.item, revision: 1, fallback: s.dir)
        let move = try #require(plan.move)
        #expect(move.to == s.source.appending(path: "App.dmg").path)
        try Archiver.move(move).get()
        CleanupRules.applyMove(move, to: &s.item, now: Date())
        #expect(s.item.fileName == "App.dmg")
        #expect(s.item.directory.standardizedFileURL.path == s.source.standardizedFileURL.path)
        #expect(s.item.keep == true)
        #expect(s.item.archivedAt == nil)
        #expect(FileStamp.read(s.item.destination) == stamp)
    }

    @Test func restoreAddsASuffixWhenTheNameIsTaken() throws {
        var s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        try archive(&s)
        try Data("new download".utf8).write(to: s.source.appending(path: "App.dmg"))
        let move = try #require(Archiver.planRestore(s.item, revision: 1, fallback: s.dir).move)
        #expect(URL(filePath: move.to).lastPathComponent == "App (2).dmg")
    }

    @Test func restoreFallsBackToTheDefaultFolder() throws {
        var s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        try archive(&s)
        s.item.archivedFrom = s.dir.appending(path: "gone").path
        let move = try #require(Archiver.planRestore(s.item, revision: 1, fallback: s.dir).move)
        #expect(move.to == s.dir.appending(path: "App.dmg").path)
    }

    @Test func restoreRefusesAMissingOrChangedFile() throws {
        var s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        try archive(&s)
        try Data("edited".utf8).write(to: s.item.destination, options: .atomic)
        let changed = Archiver.planRestore(s.item, revision: 1, fallback: s.dir)
        #expect(changed.move == nil && changed.failure != nil)
        try FileManager.default.removeItem(at: s.item.destination)
        let missing = Archiver.planRestore(s.item, revision: 1, fallback: s.dir)
        #expect(missing.move == nil && missing.failure != nil)
    }

    @Test func moveRefusesChangedSourceOrTakenTarget() throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let stamp = try #require(s.item.stamp)
        let from = s.item.destination.path
        var other = stamp
        other.fileID += 1
        let changed = PendingMove(kind: .archive, from: from, to: s.archive.appending(path: "App.dmg").path, stamp: other)
        #expect(throws: ArchiveError.changed) { try Archiver.move(changed).get() }
        try Data("taken".utf8).write(to: s.archive.appending(path: "App.dmg"))
        let taken = PendingMove(kind: .archive, from: from, to: s.archive.appending(path: "App.dmg").path, stamp: stamp)
        #expect(throws: ArchiveError.targetExists) { try Archiver.move(taken).get() }
        #expect(FileStamp.read(s.item.destination) == stamp, "source untouched")
    }

    @Test func reconcilesRecordedMovesAgainstTheDisk() throws {
        var s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let stamp = try #require(s.item.stamp)
        let target = s.archive.appending(path: "App.dmg").path
        s.item.pendingMove = PendingMove(kind: .archive, from: s.item.destination.path, to: target, stamp: stamp)
        #expect(Archiver.reconcile([s.item]) == [s.item.id: .notMoved])
        try FileManager.default.moveItem(atPath: s.item.destination.path, toPath: target)
        try Data("different".utf8).write(to: s.item.destination)
        #expect(Archiver.reconcile([s.item]) == [s.item.id: .completed])
        try FileManager.default.removeItem(atPath: target)
        #expect(Archiver.reconcile([s.item]) == [s.item.id: .unknown])
    }

    @Test func monthFolderName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        #expect(Archiver.monthFolderName(date) == "2026-10 October")
    }
}

@Suite struct CleanupTrashTests {
    @Test func fileReplacedAfterTheScanIsSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        func make(_ name: String) throws -> (DownloadItem, TrashEntry) {
            let url = dir.appending(path: name)
            try Data("original".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * Fixture.day)], ofItemAtPath: url.path)
            var item = DownloadItem(url: URL(string: "https://a.com/\(name)")!, fileName: name, directory: dir, category: .video)
            item.state = .completed
            item.completedAt = now.addingTimeInterval(-90 * Fixture.day)
            item.stamp = FileStamp.read(url)
            let entry = TrashEntry(id: item.id, name: name, path: item.destination.standardizedFileURL.path, stamp: try #require(item.stamp),
                                   rule: TrashEntry.Rule(item: item, days: 30, sharedPath: false))
            return (item, entry)
        }
        let (_, keep) = try make("replaced.mp4")
        let (unchangedItem, unchanged) = try make("unchanged.mp4")
        // Replaced after the scan: same name, new file.
        try Data("replacement".utf8).write(to: dir.appending(path: "replaced.mp4"), options: .atomic)

        var trashed: [String] = []
        let outcome = CleanupTrasher.trash([keep, unchanged], now: now, lastUsed: { _ in nil }) { trashed.append($0.lastPathComponent) }
        #expect(trashed == ["unchanged.mp4"])
        #expect(outcome.trashedIDs == [unchangedItem.id])
        #expect(outcome.problems.map(\.name) == ["replaced.mp4"])
        #expect(outcome.problems.first?.reason == "changed since the last scan")
    }

    @Test func recentUseSinceTheScanIsSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let url = dir.appending(path: "a.mp4")
        try Data("a".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * Fixture.day)], ofItemAtPath: url.path)
        var item = DownloadItem(url: URL(string: "https://a.com/a.mp4")!, fileName: "a.mp4", directory: dir, category: .video)
        item.state = .completed
        item.completedAt = now.addingTimeInterval(-90 * Fixture.day)
        item.stamp = FileStamp.read(url)
        let entry = TrashEntry(id: item.id, name: "a.mp4", path: url.standardizedFileURL.path, stamp: try #require(item.stamp),
                               rule: TrashEntry.Rule(item: item, days: 30, sharedPath: false))
        var calls = 0
        let outcome = CleanupTrasher.trash([entry], now: now, lastUsed: { _ in now }) { _ in calls += 1 }
        #expect(calls == 0)
        #expect(outcome.trashedIDs.isEmpty)
        #expect(outcome.problems.count == 1)
    }

    @Test func trashFailureIsReported() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "x.drift-part")
        try Data("x".utf8).write(to: url)
        let entry = TrashEntry(id: nil, name: "x.drift-part", path: url.standardizedFileURL.path, stamp: try #require(FileStamp.read(url)), rule: nil)
        let outcome = CleanupTrasher.trash([entry], now: Date(), lastUsed: { _ in nil }) { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(outcome.trashedPaths.isEmpty)
        #expect(outcome.problems.map(\.name) == ["x.drift-part"])
    }

    @Test func cleanupDoesNotRunInTheTestHost() {
        #expect(AppEnvironment.isRunningTests)
    }
}

@Suite struct ArchivePruneTests {
    @Test func removesEmptyMonthFolderAndRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "Drift Archive", directoryHint: .isDirectory)
        let month = root.appending(path: "2026-10 October", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try Data().write(to: month.appending(path: ".DS_Store"))

        Archiver.pruneEmptyFolders(from: month, root: root)
        #expect(!FileManager.default.fileExists(atPath: month.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: dir.path), "nothing above the root is touched")
    }

    @Test func keepsFoldersWithFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "Drift Archive", directoryHint: .isDirectory)
        let empty = root.appending(path: "2026-09 September", directoryHint: .isDirectory)
        let full = root.appending(path: "2026-10 October", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: full.appending(path: "App.dmg"))

        Archiver.pruneEmptyFolders(from: full, root: root)
        #expect(FileManager.default.fileExists(atPath: full.appending(path: "App.dmg").path))
        Archiver.pruneEmptyFolders(from: empty, root: root)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(FileManager.default.fileExists(atPath: root.path), "the root still holds another month")
    }

    @Test func ignoresFoldersOutsideTheRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "Drift Archive", directoryHint: .isDirectory)
        let outside = dir.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        Archiver.pruneEmptyFolders(from: outside, root: root)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func restoringTheLastFileRemovesItsMonthFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "Drift Archive", directoryHint: .isDirectory)
        let month = root.appending(path: "2026-10 October", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let file = month.appending(path: "App.dmg")
        try Data("installer".utf8).write(to: file)
        let back = dir.appending(path: "App.dmg")
        try FileManager.default.moveItem(at: file, to: back)

        Archiver.pruneEmptyFolders(from: file.deletingLastPathComponent(), root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: back.path))
    }
}
