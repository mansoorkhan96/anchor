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
