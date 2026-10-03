import Foundation
import Testing
@testable import Drift

@Suite struct SegmentPlannerTests {
    @Test func plansContiguousCoverage() {
        let total: Int64 = 100 * 1_048_576 + 7
        let segments = SegmentPlanner.plan(total: total, connections: 16)
        #expect(segments.count == 16)
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == total - 1)
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(a.end + 1 == b.start)
        }
        #expect(segments.reduce(0) { $0 + $1.length } == total)
    }

    @Test func smallFilesGetFewerSegments() {
        #expect(SegmentPlanner.plan(total: 3 * 1_048_576, connections: 16).count == 3)
        #expect(SegmentPlanner.plan(total: 10, connections: 16).count == 1)
        #expect(SegmentPlanner.plan(total: 0, connections: 16).isEmpty)
    }

    @Test func splitsLargestBusySegment() {
        var segments = [
            Segment(start: 0, end: 9_999_999, received: 9_000_000),
            Segment(start: 10_000_000, end: 19_999_999, received: 1_000_000),
        ]
        let new = SegmentPlanner.splitLargest(&segments, busy: [0, 1])
        #expect(new == 2)
        #expect(segments[1].end + 1 == segments[2].start)
        #expect(segments[2].end == 19_999_999)
        #expect(segments[1].remaining + segments[2].remaining == 9_000_000)
    }

    @Test func refusesTinySplits() {
        var segments = [Segment(start: 0, end: 1_500_000, received: 0)]
        #expect(SegmentPlanner.splitLargest(&segments, busy: [0]) == nil)
    }

    @Test func pendingSkipsBusyAndComplete() {
        let segments = [
            Segment(start: 0, end: 9, received: 10),
            Segment(start: 10, end: 19),
            Segment(start: 20, end: 29),
        ]
        #expect(SegmentPlanner.nextPending(segments, busy: [1]) == 2)
    }
}

@Suite struct FileNamingTests {
    @Test func parsesContentDisposition() {
        #expect(FileNaming.fileName(fromContentDisposition: #"attachment; filename="report final.pdf""#) == "report final.pdf")
        #expect(FileNaming.fileName(fromContentDisposition: "attachment; filename*=UTF-8''na%C3%AFve%20file.zip") == "naïve file.zip")
        #expect(FileNaming.fileName(fromContentDisposition: #"attachment; filename="a.txt"; filename*=UTF-8''b.txt"#) == "b.txt")
        #expect(FileNaming.fileName(fromContentDisposition: "inline") == nil)
    }

    @Test func sanitizesSlashes() {
        #expect(FileNaming.sanitize("../etc/passwd") == "-etc-passwd")
    }

    @Test func namesFromURL() {
        #expect(FileNaming.fileName(from: URL(string: "https://x.com/files/My%20App.dmg?token=1")!) == "My App.dmg")
    }

    @Test func uniqueNamesAvoidCollisions() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "a.zip"))
        #expect(FileNaming.unique("a.zip", in: dir) == "a (2).zip")
        #expect(FileNaming.unique("a.zip", in: dir, taken: ["a (2).zip"]) == "a (3).zip")
        #expect(FileNaming.unique("b.zip", in: dir) == "b.zip")
    }
}

@Suite struct MiscTests {
    @Test func detectsCategories() {
        #expect(FileCategory.detect(fileName: "movie.MKV") == .video)
        #expect(FileCategory.detect(fileName: "Xcode.dmg") == .apps)
        #expect(FileCategory.detect(fileName: "song.flac") == .music)
        #expect(FileCategory.detect(fileName: "noext") == .other)
    }

    @Test func formatsBytes() {
        #expect(Format.bytes(0) == "0 B")
        #expect(Format.bytes(1_500) == "1.5 KB")
        #expect(Format.bytes(3_800_000_000) == "3.8 GB")
        #expect(Format.progress(2_100_000_000, of: 3_800_000_000) == "2.1 of 3.8 GB")
        #expect(Format.progress(500_000, of: 3_800_000_000) == "500 KB of 3.8 GB")
        #expect(Format.duration(3725) == "1h 2m")
    }

    @Test func detectsClipboardLinks() {
        #expect(ClipboardWatcher.downloadLink(in: "https://a.com/x.zip") != nil)
        #expect(ClipboardWatcher.downloadLink(in: "https://a.com/page") == nil)
        #expect(ClipboardWatcher.downloadLink(in: "magnet:?xt=urn:btih:abc") != nil)
        #expect(ClipboardWatcher.downloadLink(in: "hello https://a.com/x.zip") == nil)
    }

    @Test func parsesHTTPRequests() {
        let raw = Data("POST /add HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nOrigin: chrome-extension://abc\r\n\r\nhello".utf8)
        let request = HTTPRequest(raw)
        #expect(request?.method == "POST")
        #expect(request?.path == "/add")
        #expect(request?.headers["origin"] == "chrome-extension://abc")
        #expect(request.map { String(decoding: $0.body, as: UTF8.self) } == "hello")
        #expect(HTTPRequest(Data("POST /add HTTP/1.1\r\nContent-Length: 10\r\n\r\nhi".utf8)) == nil)
    }

    @Test func ordersMenuBarRecents() {
        let dir = URL(filePath: "/tmp")
        func item(_ name: String, _ t: Double, done: Bool) -> DownloadItem {
            var i = DownloadItem(url: URL(string: "https://a/\(name)")!, fileName: name, directory: dir, category: .other)
            i.createdAt = Date(timeIntervalSince1970: t)
            i.state = done ? .completed : .paused
            return i
        }
        let items = [item("old-open", 10, done: false), item("new-done", 30, done: true),
                     item("mid-open", 20, done: false), item("oldest-done", 5, done: true)]
        #expect(DownloadStore.recent(items, order: .newest, limit: 10).map(\.fileName)
                == ["new-done", "mid-open", "old-open", "oldest-done"])
        #expect(DownloadStore.recent(items, order: .unfinishedFirst, limit: 10).map(\.fileName)
                == ["mid-open", "old-open", "new-done", "oldest-done"])
        #expect(DownloadStore.recent(items, order: .unfinishedFirst, limit: 3).count == 3)
    }

    @Test func sortsBySizeAndDate() {
        let dir = URL(filePath: "/tmp")
        var a = DownloadItem(url: URL(string: "https://a/1")!, fileName: "a", directory: dir, category: .other)
        var b = DownloadItem(url: URL(string: "https://a/2")!, fileName: "b", directory: dir, category: .other)
        a.totalBytes = 10
        b.totalBytes = 20
        a.createdAt = Date(timeIntervalSince1970: 100)
        b.createdAt = Date(timeIntervalSince1970: 50)
        #expect([a, b].sorted(by: .largest).map(\.fileName) == ["b", "a"])
        #expect([a, b].sorted(by: .smallest).map(\.fileName) == ["a", "b"])
        #expect([a, b].sorted(by: .newest).map(\.fileName) == ["a", "b"])
        #expect([a, b].sorted(by: .oldest).map(\.fileName) == ["b", "a"])
    }
}

@Suite struct TorrentSelectionTests {
    private func file(_ index: Int, _ priority: Priority, done: Bool = false, included: Bool = true) -> TorrentFile {
        TorrentFile(index: index, path: "f\(index)", length: 100, completed: done ? 100 : 0, included: included, priority: priority)
    }

    @Test func downloadsHighPriorityFilesFirst() {
        let files = [file(1, .normal), file(2, .high), file(3, .low)]
        #expect(TorrentSelection.phase(files) == [2])
        #expect(TorrentSelection.hasLaterPhase(files, selected: [2]))
    }

    @Test func addsNextPriorityOnceTheFirstIsDone() {
        let files = [file(1, .normal), file(2, .high, done: true), file(3, .low)]
        #expect(TorrentSelection.phase(files) == [1, 2])
        let later = [file(1, .normal, done: true), file(2, .high, done: true), file(3, .low)]
        #expect(TorrentSelection.phase(later) == [1, 2, 3])
        #expect(!TorrentSelection.hasLaterPhase(later, selected: [1, 2, 3]))
    }

    @Test func neverSelectsSkippedFiles() {
        let files = [file(1, .normal), file(2, .normal, included: false), file(3, .normal)]
        #expect(TorrentSelection.phase(files) == [1, 3])
        #expect(!TorrentSelection.hasLaterPhase(files, selected: [1, 3]))
    }

    @Test func allNormalDownloadsEverythingAtOnce() {
        let files = [file(1, .normal), file(2, .normal)]
        #expect(TorrentSelection.phase(files) == [1, 2])
    }
}
