import Foundation
import Testing
@testable import Anchor

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
        // Splitting costs a reconnect: under 4 MiB left isn't worth it, 4 MiB is.
        var small = [Segment(start: 0, end: (4 << 20) - 2, received: 0)]
        #expect(SegmentPlanner.splitLargest(&small, busy: [0]) == nil)
        var enough = [Segment(start: 0, end: (4 << 20) - 1, received: 0)]
        #expect(SegmentPlanner.splitLargest(&enough, busy: [0]) == 1)
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

@Suite struct PersistenceTests {
    /// Items saved by older versions (missing newer fields) must still load.
    @Test func decodesItemsSavedByOlderVersions() throws {
        let old = """
        {"id":"7E1B68C6-35D8-44D6-8C12-B179B025D8BD","kind":"http","url":"https://a.com/x.zip","fileName":"x.zip",
         "directory":"file:///tmp/","category":"archives","receivedBytes":10,"segments":[],"supportsRanges":true,
         "state":{"paused":{}},"createdAt":800000000,"openWhenDone":false,"headers":{}}
        """
        let item = try JSONDecoder().decode(DownloadItem.self, from: Data(old.utf8))
        #expect(item.fileName == "x.zip")
        #expect(item.state == .paused)
        #expect(item.speedLimitKB == nil)
    }

    @Test func roundTripsCurrentItems() throws {
        var item = DownloadItem(url: URL(string: "https://a.com/x.zip")!, fileName: "x.zip",
                                directory: URL(filePath: "/tmp"), category: .archives)
        item.speedLimitKB = 500
        item.uploadedBytes = 99
        let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(back.speedLimitKB == 500)
        #expect(back.uploadedBytes == 0)
    }
}

@Suite struct ProbeParsingTests {
    private func response(_ status: Int, _ headers: [String: String], url: String = "https://example.com/files/setup.dmg") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func partialContentGivesSizeAndRanges() {
        let r = Probe.parse(response(206, ["Content-Range": "bytes 0-0/52428800", "ETag": "\"abc\""]),
                            requested: URL(string: "https://example.com/files/setup.dmg")!)
        #expect(r.totalBytes == 52_428_800)
        #expect(r.supportsRanges)
        #expect(r.validator == "\"abc\"")
        #expect(r.fileName == "setup.dmg")
    }

    @Test func fullResponseUsesAcceptRanges() {
        let yes = Probe.parse(response(200, ["Content-Length": "1000", "Accept-Ranges": "bytes"]),
                              requested: URL(string: "https://example.com/a.zip")!)
        #expect(yes.totalBytes == 1000)
        #expect(yes.supportsRanges)
        let no = Probe.parse(response(200, ["Content-Length": "1000", "Last-Modified": "Mon, 12 Oct 2026 10:00:00 GMT"]),
                             requested: URL(string: "https://example.com/a.zip")!)
        #expect(!no.supportsRanges)
        #expect(no.validator == "Mon, 12 Oct 2026 10:00:00 GMT", "Last-Modified is the validator without an ETag")
    }

    @Test func unknownSizeHasNoRanges() {
        let r = Probe.parse(response(200, [:]), requested: URL(string: "https://example.com/stream")!)
        #expect(r.totalBytes == nil)
        #expect(!r.supportsRanges)
    }

    @Test func contentDispositionNamesTheFile() {
        let r = Probe.parse(response(200, ["Content-Length": "5", "Content-Disposition": "attachment; filename=\"Report Q3.pdf\""],
                                     url: "https://example.com/download?id=7"),
                            requested: URL(string: "https://example.com/download?id=7")!)
        #expect(r.fileName == "Report Q3.pdf")
    }
}

@Suite struct RateLimiterTests {
    @Test func unlimitedNeverWaits() {
        let limiter = RateLimiter()
        #expect(limiter.reserve(10_000_000) == .zero)
    }

    @Test func waitsForTheBytesOverTheLimit() {
        let limiter = RateLimiter()
        limiter.limit = 1_000
        // The bucket starts empty: 500 bytes at 1000 B/s means about half a second.
        let wait = limiter.reserve(500)
        #expect(wait >= .milliseconds(450) && wait <= .milliseconds(500))
        limiter.limit = 0
        #expect(limiter.reserve(500) == .zero, "turning the limit off stops the waiting")
        #expect(limiter.limit == 0)
    }
}

@Suite struct SidebarFilterTests {
    private func item(_ state: DownloadState, kind: DownloadKind = .http, category: FileCategory = .documents) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://example.com/f")!, fileName: "f", directory: URL(filePath: "/tmp"),
                                category: category, kind: kind)
        item.state = state
        return item
    }

    @Test func statesLandInTheRightLists() {
        #expect(SidebarFilter.downloading.matches(item(.downloading)))
        #expect(SidebarFilter.downloading.matches(item(.connecting)))
        #expect(SidebarFilter.queued.matches(item(.queued)))
        #expect(SidebarFilter.queued.matches(item(.paused)), "paused downloads wait in Queued")
        #expect(SidebarFilter.completed.matches(item(.completed)))
        #expect(SidebarFilter.failed.matches(item(.failed("404"))))
        #expect(!SidebarFilter.completed.matches(item(.downloading)))
        #expect(SidebarFilter.all.matches(item(.failed("x"))))
    }

    @Test func torrentsAreNotInCategories() {
        let torrent = item(.downloading, kind: .torrent, category: .documents)
        #expect(SidebarFilter.torrents.matches(torrent))
        #expect(!SidebarFilter.category(.documents).matches(torrent))
        #expect(SidebarFilter.category(.documents).matches(item(.completed)))
        #expect(!SidebarFilter.cleanup.matches(item(.completed)), "Tidy lists use their own queries")
    }
}

@Suite struct MoveSelectionTests {
    private func item(_ state: DownloadState, in folder: String = "/tmp/a") -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://example.com/f")!, fileName: "f", directory: URL(filePath: folder),
                                category: .documents)
        item.state = state
        return item
    }

    @Test func onlyFinishedDownloadsMove() {
        let done = item(.completed), running = item(.downloading), paused = item(.paused), failed = item(.failed("x"))
        let all = [done, running, paused, failed]
        let moved = DownloadStore.movable(Set(all.map(\.id)), in: all, to: URL(filePath: "/tmp/b"))
        #expect(moved == [done.id])
    }

    @Test func skipsFilesAlreadyThereAndUnselected() {
        let here = item(.completed, in: "/tmp/b"), other = item(.completed), unselected = item(.completed)
        let moved = DownloadStore.movable([here.id, other.id], in: [here, other, unselected], to: URL(filePath: "/tmp/b/"))
        #expect(moved == [other.id])
    }
}

@Suite struct LineReaderTests {
    private final class Lines: @unchecked Sendable {
        var all: [String] = []
    }

    @Test func splitsAcrossChunksAndCarriageReturns() {
        let lines = Lines()
        let reader = LineReader { lines.all.append($0) }
        reader.feed(Data("ANCHOR 1".utf8))
        reader.feed(Data("0%\rANCHOR 20%\r\nnext\n\n".utf8))
        reader.feed(Data("tail".utf8))
        #expect(lines.all == ["ANCHOR 10%", "ANCHOR 20%", "next"], "empty lines are dropped")
        reader.finish()
        #expect(lines.all.last == "tail", "the last line without a newline still arrives")
    }
}

@Suite struct ProgressStatusTests {
    private func item(_ state: DownloadState, kind: DownloadKind = .http, received: Int64 = 380, total: Int64? = 1000,
                      speed: Double = 0, phase: MediaPhase? = nil) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://example.com/f")!, fileName: "f", directory: URL(filePath: "/tmp"),
                                category: .video, kind: kind)
        item.state = state
        item.receivedBytes = received
        item.totalBytes = total
        item.speed = speed
        item.mediaPhase = phase
        return item
    }

    @Test func downloadingShowsPercentAndSpeed() {
        let status = ProgressStatus(item: item(.downloading, speed: 8_400_000))
        #expect(status.stage() == "Downloading")
        #expect(status.detail == "38% · \(Format.speed(8_400_000))")
        #expect(status.compactDetail == "38%")
        #expect(status.showsBar)
    }

    @Test func convertingShowsTimeLeft() {
        let converting = item(.downloading, kind: .media, phase: .converting(fraction: 0.42, eta: 72))
        let status = ProgressStatus(item: converting)
        #expect(status.stage() == "Converting to MP4")
        #expect(status.stage(short: true) == "Converting")
        #expect(status.detail == "42% · 1m 12s left")
        #expect(status.compactDetail == "42% · 1m 12s")
        #expect(status.fraction == 0.42)
    }

    @Test func pausedConversionKeepsItsPlace() {
        let paused = item(.paused, kind: .media, phase: .converting(fraction: 0.6, eta: 30))
        let status = ProgressStatus(item: paused)
        #expect(status.stage() == "Conversion paused")
        #expect(status.stage(short: true) == "Paused")
        #expect(status.detail == "60%", "no time left while paused")
        #expect(status.compactDetail == "60%")
        #expect(ProgressStatus(item: item(.paused, kind: .media, phase: .merging)).stage() == "Merging paused")
    }

    @Test func mergingHasAFullDimmedBarAndNoNumbers() {
        let status = ProgressStatus(item: item(.downloading, kind: .media, phase: .merging))
        #expect(status.stage() == "Merging")
        #expect(status.fraction == 1)
        #expect(status.dimmed)
        #expect(status.detail.isEmpty)
    }

    @Test func quietStatesAndFinished() {
        #expect(ProgressStatus(item: item(.completed)).stage() == nil, "finished rows have no progress line")
        let queued = ProgressStatus(item: item(.queued))
        #expect(queued.stage() == "Queued")
        #expect(queued.detail.isEmpty && !queued.showsBar)
        let failed = ProgressStatus(item: item(.failed("Server said 404")))
        #expect(failed.stage() == "Failed")
        #expect(failed.detail.isEmpty && !failed.showsBar)
        #expect(ProgressStatus(item: item(.downloading, total: nil, speed: 1000)).detail == Format.speed(1000),
                "no percentage without a known size")
    }

    @Test func seedingShowsUploadSpeed() {
        var seeding = item(.completed, kind: .torrent)
        seeding.seeding = true
        seeding.uploadSpeed = 2048
        let status = ProgressStatus(item: seeding)
        #expect(status.stage() == "Seeding")
        #expect(status.detail == "↑ \(Format.speed(2048))")
        #expect(!status.showsBar)
    }
}

@Suite struct RetryAfterTests {
    @Test func readsSecondsAndDates() throws {
        #expect(HTTPDownload.retryAfterSeconds("120") == 120)
        #expect(HTTPDownload.retryAfterSeconds(" 5 ") == 5)
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = try #require(TimeZone(identifier: "GMT"))
        let now = try #require(gmt.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10)))
        #expect(HTTPDownload.retryAfterSeconds("Mon, 12 Oct 2026 10:00:30 GMT", now: now) == 30)
        #expect(HTTPDownload.retryAfterSeconds("Mon, 12 Oct 2026 09:00:00 GMT", now: now) == 0, "a date in the past means now")
        #expect(HTTPDownload.retryAfterSeconds(nil) == nil)
        #expect(HTTPDownload.retryAfterSeconds("soon") == nil)
    }
}

@Suite struct ToolFingerprintTests {
    @Test func unchangedSystemToolIsTrusted() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "anchor-fp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let node = dir.appending(path: "node")
        try Data("#!/bin/sh\necho v22.0.0\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        var record = ToolRecord(version: "22.0.0", source: .system, path: node.path, installedAt: Date(), sha256: nil,
                                runtime: "node", fingerprint: ToolDiscovery.fingerprint(of: node))
        #expect(ToolDiscovery.isUnchanged(record, tool: .deno))

        // An upgrade changes size or date: look again.
        try Data("#!/bin/sh\necho v23.0.0 with more bytes\n".utf8).write(to: node)
        #expect(!ToolDiscovery.isUnchanged(record, tool: .deno))

        record.fingerprint = nil
        #expect(!ToolDiscovery.isUnchanged(record, tool: .deno), "old manifests without a fingerprint are checked again")
        record.fingerprint = ToolDiscovery.fingerprint(of: node)
        #expect(!ToolDiscovery.isUnchanged(record, tool: .ffmpeg), "ffmpeg also needs ffprobe beside it")
        record.source = .managed
        #expect(!ToolDiscovery.isUnchanged(record, tool: .deno), "only system copies are trusted this way")
    }
}

/// A real download against a local server that says it supports ranges but answers every range request after
/// the probe with the whole file (as some mirrors do). The engine must switch to one stream and finish.
@Suite(.serialized) struct RangeFallbackTests {
    private static let server = #"""
import http.server, sys
BODY = bytes(range(256)) * (12 * 4096)  # 12 MiB, so the file is split into several segments
HONOR = len(sys.argv) > 1 and sys.argv[1] == "honor"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        r = self.headers.get("Range")
        if HONOR and r:
            start, end = r[6:].split("-")
            start = int(start); end = int(end) if end else len(BODY) - 1
            part = BODY[start:end + 1]
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(BODY)))
            self.send_header("Content-Length", str(len(part)))
            self.end_headers()
            try: self.wfile.write(part)
            except Exception: pass
            return
        if r == "bytes=0-":
            self.send_response(206)
            self.send_header("Content-Range", "bytes 0-%d/%d" % (len(BODY) - 1, len(BODY)))
        else:
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        try: self.wfile.write(BODY)
        except Exception: pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
"""#

    @Test(.timeLimit(.minutes(1))) func switchesToOneStreamWhenRangesAreIgnored() async throws {
        try await download(mode: "ignore")
    }

    /// The normal case: a server that honors ranges, downloaded over several connections.
    @Test(.timeLimit(.minutes(1))) func downloadsInPartsWhenRangesWork() async throws {
        try await download(mode: "honor")
    }

    private func download(mode: String) async throws {
        let python = Process()
        python.executableURL = URL(filePath: "/usr/bin/python3")
        python.arguments = ["-I", "-c", Self.server, mode]
        let out = Pipe()
        python.standardOutput = out
        python.standardError = FileHandle.nullDevice
        try python.run()
        defer { python.terminate() }
        let portLine = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        let port = try #require(Int(portLine.trimmingCharacters(in: .whitespacesAndNewlines)))

        let dir = FileManager.default.temporaryDirectory.appending(path: "anchor-range-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = DownloadItem(url: URL(string: "http://127.0.0.1:\(port)/file.bin")!, fileName: "file.bin", directory: dir,
                                category: .other)

        let result: DownloadEvent = await withCheckedContinuation { continuation in
            let once = OnceBox()
            let engine = HTTPDownload(item: item, maxConnections: 8) { event in
                switch event {
                case .completed, .failed: if once.claim() { continuation.resume(returning: event) }
                default: break
                }
            }
            engine.start()
            once.keep(engine)
        }
        guard case .completed(let name) = result else {
            Issue.record("download failed: \(result)")
            return
        }
        let data = try Data(contentsOf: dir.appending(path: name))
        #expect(data == Data(Array(0...255).map(UInt8.init)) .repeated(12 * 4096))
    }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var held: AnyObject?
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    func keep(_ object: AnyObject) { lock.withLock { held = object } }
}

private extension Data {
    func repeated(_ count: Int) -> Data {
        var result = Data(capacity: self.count * count)
        for _ in 0..<count { result.append(self) }
        return result
    }
}

@Suite struct StartOverTests {
    private func item(_ state: DownloadState, kind: DownloadKind = .http) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://example.com/f")!, fileName: "f", directory: URL(filePath: "/tmp"),
                                category: .other, kind: kind)
        item.state = state
        return item
    }

    @Test func offeredForStoppedAndFinishedDownloads() {
        #expect(DownloadStore.startOverKind(item(.failed("x"))) == .startOver)
        #expect(DownloadStore.startOverKind(item(.paused, kind: .media)) == .startOver)
        #expect(DownloadStore.startOverKind(item(.completed)) == .downloadAgain)
        #expect(DownloadStore.startOverKind(item(.downloading)) == nil, "pause it first")
        #expect(DownloadStore.startOverKind(item(.queued)) == nil)
        #expect(DownloadStore.startOverKind(item(.failed("x"), kind: .torrent)) == nil, "aria2 owns torrent data")
    }
}
