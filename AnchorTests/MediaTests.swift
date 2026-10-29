import Foundation
import Testing
@testable import Anchor

// MARK: - Helpers

/// Writes an executable shell script that prints `output` and exits with `status`.
@discardableResult
private func fakeTool(_ name: String, in dir: URL, output: String, status: Int32 = 0) throws -> URL {
    let url = dir.appending(path: name)
    try "#!/bin/sh\necho '\(output)'\nexit \(status)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// A minimal zip (stored entries) with the given names and external attributes; contents are not needed by the inspector.
private func makeZip(_ entries: [(name: String, attributes: UInt32)]) -> Data {
    var local = Data()
    var central = Data()
    func le16(_ v: UInt16, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func le32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    for entry in entries {
        let name = Data(entry.name.utf8)
        let offset = UInt32(local.count)
        le32(0x04034b50, &local); le16(20, &local); le16(0, &local); le16(0, &local); le16(0, &local); le16(0, &local)
        le32(0, &local); le32(0, &local); le32(0, &local); le16(UInt16(name.count), &local); le16(0, &local)
        local.append(name)
        le32(0x02014b50, &central); le16(0x031E, &central); le16(20, &central); le16(0, &central); le16(0, &central)
        le16(0, &central); le16(0, &central); le32(0, &central); le32(0, &central); le32(0, &central)
        le16(UInt16(name.count), &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central)
        le32(entry.attributes, &central); le32(offset, &central)
        central.append(name)
    }
    var end = Data()
    le32(0x06054b50, &end); le16(0, &end); le16(0, &end)
    le16(UInt16(entries.count), &end); le16(UInt16(entries.count), &end)
    le32(UInt32(central.count), &end); le32(UInt32(local.count), &end); le16(0, &end)
    return local + central + end
}

private let regularFile: UInt32 = 0o100644 << 16

// MARK: - Detection

@Suite struct MediaLinkDetectorTests {
    @Test func knownHostsAndSubdomains() {
        let links = ["https://www.youtube.com/watch?v=x", "https://youtu.be/x", "https://m.youtube.com/watch?v=x",
                     "https://music.youtube.com/watch?v=x", "https://www.instagram.com/reel/x/", "https://www.tiktok.com/@a/video/1",
                     "https://vm.tiktok.com/x", "https://www.pinterest.com/pin/1/", "https://pin.it/x", "https://x.com/a/status/1",
                     "https://twitter.com/a/status/1", "https://vimeo.com/1", "https://www.facebook.com/watch?v=1",
                     "https://fb.watch/x", "https://www.reddit.com/r/a/comments/b", "https://v.redd.it/x", "https://www.twitch.tv/x",
                     "https://www.dailymotion.com/video/x", "https://soundcloud.com/a/b", "https://www.bilibili.com/video/x",
                     "http://YOUTUBE.com./watch?v=x"]
        for link in links {
            #expect(MediaLinkDetector.isLikelyMedia(URL(string: link)!), "\(link)")
        }
    }

    @Test func rejectsLookalikesAndOtherSchemes() {
        let links = ["https://notyoutube.com/x", "https://youtube.com.evil.example/x", "https://example.com/video.mp4",
                     "ftp://youtube.com/x", "magnet:?xt=urn:btih:abc", "file:///Users/a/youtube.com"]
        for link in links {
            #expect(!MediaLinkDetector.isLikelyMedia(URL(string: link)!), "\(link)")
        }
    }

    @Test func genericExtractor() {
        #expect(MediaLinkDetector.isGeneric(extractor: "generic", key: "Generic"))
        #expect(MediaLinkDetector.isGeneric(extractor: nil, key: nil))
        #expect(!MediaLinkDetector.isGeneric(extractor: "youtube", key: "Youtube"))
    }
}

// MARK: - Model

@Suite struct MediaItemDecodingTests {
    @Test func oldLibraryWithoutMediaFieldsDecodes() throws {
        let json = """
        {"id":"8D1E6F2A-7A4B-4C33-9E55-0F6B1C2D3E4F","kind":"http","url":"https://example.com/a.zip","fileName":"a.zip",
         "directory":"file:///tmp/","category":"archives","receivedBytes":0,"segments":[],"supportsRanges":false,
         "state":{"queued":{}},"createdAt":700000000,"openWhenDone":false,"headers":{}}
        """
        let item = try JSONDecoder().decode(DownloadItem.self, from: Data(json.utf8))
        #expect(item.kind == .http)
        #expect(item.mediaQuality == nil)
        #expect(item.mediaInfo == nil)
        #expect(item.mediaProcessing == false)
    }

    @Test func mediaItemRoundTrips() throws {
        var item = DownloadItem(url: URL(string: "https://youtu.be/x")!, fileName: "Clip.mp4",
                                directory: URL(filePath: "/tmp"), category: .video, kind: .media)
        item.mediaQuality = .p720
        item.mediaInfo = MediaInfo(title: "Clip", extractor: "youtube", thumbnail: URL(string: "https://i.ytimg.com/a.jpg"), duration: 19)
        item.mediaPhase = .merging
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.kind == .media)
        #expect(decoded.mediaQuality == .p720)
        #expect(decoded.mediaInfo == item.mediaInfo)
        // Live only.
        #expect(decoded.mediaProcessing == false)
    }

    @Test func categoryFilterIncludesMedia() {
        let item = DownloadItem(url: URL(string: "https://youtu.be/x")!, fileName: "Clip.mp4",
                                directory: URL(filePath: "/tmp"), category: .video, kind: .media)
        #expect(SidebarFilter.category(.video).matches(item))
        #expect(!SidebarFilter.torrents.matches(item))
    }
}

// MARK: - Manifest and versions

@Suite struct ToolManifestTests {
    @Test func roundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "tools.json")
        var manifest = ToolManifest()
        manifest[.ytdlp] = ToolRecord(version: "2026.08.19", source: .managed, path: "/x/yt-dlp/yt-dlp_macos",
                                      installedAt: Date(timeIntervalSince1970: 1_790_000_000), sha256: "ab", runtime: nil)
        manifest[.deno] = ToolRecord(version: "22.3.0", source: .system, path: "/opt/homebrew/bin/node",
                                     installedAt: Date(timeIntervalSince1970: 1_790_000_100), sha256: nil, runtime: "node")
        try manifest.save(to: url)
        #expect(ToolManifest.load(from: url) == manifest)
        #expect(ToolManifest.load(from: url)[.deno]?.runtime == "node")
    }

    @Test func missingOrBrokenFileIsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ToolManifest.load(from: dir.appending(path: "nope.json")) == ToolManifest())
        let broken = dir.appending(path: "broken.json")
        try Data("{".utf8).write(to: broken)
        #expect(ToolManifest.load(from: broken) == ToolManifest())
    }

    @Test func parsesVersions() {
        #expect(ToolVersion.parse("deno 2.9.7 (stable, release, aarch64-apple-darwin)\nv8 15.0") == "2.9.7")
        #expect(ToolVersion.parse("v22.1.0") == "22.1.0")
        #expect(ToolVersion.parse("1.2.11") == "1.2.11")
        #expect(ToolVersion.parse("2026.08.19\n") == "2026.08.19")
        #expect(ToolVersion.parse("ffmpeg version 9.0.2-https://www.martin-riedl.de Copyright (c) 2000-2026") == "9.0.2")
        #expect(ToolVersion.parse("ffmpeg version 7.1.1 Copyright (c) 2000-2025 the FFmpeg developers") == "7.1.1")
        #expect(ToolVersion.parse("ffmpeg version N-127260-g7bc3576910-https://www.martin-riedl.de Copyright") == "N-127260-g7bc3576910")
        #expect(ToolVersion.parse("") == nil)
    }

    @Test func comparesVersions() {
        #expect(ToolVersion.isAtLeast("2.3.0", "2.3"))
        #expect(ToolVersion.isAtLeast("2.9.7", "2.3"))
        #expect(!ToolVersion.isAtLeast("2.2.9", "2.3"))
        #expect(!ToolVersion.isAtLeast("1.2.10", "1.2.11"))
        #expect(ToolVersion.isAtLeast("1.2.11", "1.2.11"))
        #expect(ToolVersion.isAtLeast("22.0.0", "22"))
        #expect(!ToolVersion.isAtLeast("20.11.1", "22"))
        #expect(!ToolVersion.isAtLeast("garbage", "1"))
    }

    @Test func runtimeMinimums() {
        #expect(JSRuntime.minimum("deno") == "2.3")
        #expect(JSRuntime.minimum("node") == "22")
        #expect(JSRuntime.minimum("bun") == "1.2.11")
        #expect(JSRuntime.order == ["deno", "node", "bun"])
    }
}

// MARK: - Discovery

@Suite struct ToolDiscoveryTests {
    @Test func searchDirectoriesOrder() {
        let dirs = ToolDiscovery.searchDirectories(path: "/usr/bin:/opt/homebrew/bin:/custom/bin::/bin").map(\.path)
        #expect(dirs == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/custom/bin", "/bin"])
    }

    @Test func ffmpegNeedsBothToolsAndAWorkingVersion() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b, c, d) = (root.appending(path: "a"), root.appending(path: "b"), root.appending(path: "c"), root.appending(path: "d"))
        for dir in [a, b, c, d] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try fakeTool("ffmpeg", in: a, output: "ffmpeg version 1.0 Copyright")
        try fakeTool("ffmpeg", in: b, output: "ffmpeg version 2.0 Copyright", status: 1)
        try fakeTool("ffprobe", in: b, output: "ffprobe version 2.0")
        try fakeTool("ffmpeg", in: c, output: "ffmpeg version 7.1.1 Copyright (c)")
        try fakeTool("ffprobe", in: c, output: "ffprobe version 7.1.1")
        try fakeTool("ffmpeg", in: d, output: "ffmpeg version 8.0 Copyright")
        try fakeTool("ffprobe", in: d, output: "ffprobe version 8.0")

        let found = await ToolDiscovery.findFFmpeg(in: [a, b, c, d])
        #expect(found?.path.path == c.appending(path: "ffmpeg").path)
        #expect(found?.version == "7.1.1")
        #expect(await ToolDiscovery.findFFmpeg(in: [a, b]) == nil)
    }

    @Test func jsRuntimePrefersDenoAndSkipsOldCopies() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b, c) = (root.appending(path: "a"), root.appending(path: "b"), root.appending(path: "c"))
        for dir in [a, b, c] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try fakeTool("node", in: a, output: "v22.3.0")
        try fakeTool("deno", in: b, output: "deno 2.1.0 (stable, release, aarch64-apple-darwin)")
        try fakeTool("deno", in: c, output: "deno 2.4.1 (stable, release, aarch64-apple-darwin)")

        let found = await ToolDiscovery.findJSRuntime(in: [a, b, c])
        #expect(found?.name == "deno")
        #expect(found?.path.path == c.appending(path: "deno").path)
        #expect(found?.version == "2.4.1")
    }

    @Test func jsRuntimeMinimumVersions() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeTool("node", in: root, output: "v20.11.1")
        try fakeTool("bun", in: root, output: "1.2.10")
        #expect(await ToolDiscovery.findJSRuntime(in: [root]) == nil)

        try fakeTool("bun", in: root, output: "1.2.11")
        let found = await ToolDiscovery.findJSRuntime(in: [root])
        #expect(found?.name == "bun")

        try fakeTool("node", in: root, output: "v22.0.0")
        #expect(await ToolDiscovery.findJSRuntime(in: [root])?.name == "node")
    }
}

// MARK: - Sources and checksums

@Suite struct ToolSourcesTests {
    static let sums = """
    1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  yt-dlp
    0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos
    07E54B0865303C864006925913BCE2604F8EE8CC6F18699BAC9C309F9328A6D8  yt-dlp_macos.zip
    nothex  broken
    """

    @Test func findsChecksumEntries() {
        #expect(Checksums.entry(named: "yt-dlp_macos", in: Self.sums) == "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202")
        #expect(Checksums.entry(named: "yt-dlp_macos.zip", in: Self.sums) == "07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8")
        #expect(Checksums.entry(named: "yt-dlp_linux", in: Self.sums) == nil)
        #expect(Checksums.entry(named: "broken", in: Self.sums) == nil)
        // Deno's file has no trailing newline; Riedl's uses the same "<hash>  <name>" form.
        let deno = "5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c  deno-aarch64-apple-darwin.zip"
        #expect(Checksums.entry(named: "deno-aarch64-apple-darwin.zip", in: deno) == "5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c")
        #expect(Checksums.entry(named: "ffmpeg.zip", in: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924 *ffmpeg.zip\n")
                == "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924")
    }

    @Test func validatesTags() {
        #expect(ToolSources.isValidTag("2026.08.19", for: .ytdlp))
        #expect(ToolSources.isValidTag("v2.9.7", for: .deno))
        #expect(!ToolSources.isValidTag("2.9.7", for: .deno))
        #expect(!ToolSources.isValidTag("../x", for: .ytdlp))
        #expect(!ToolSources.isValidTag("v2.9.7/../../evil", for: .deno))
        #expect(!ToolSources.isValidTag("", for: .ytdlp))
    }

    @Test func pinsAssetURLs() throws {
        let yt = try #require(ToolSources.ytdlpRelease(tag: "2026.08.19"))
        #expect(yt.version == "2026.08.19")
        #expect(yt.assets.map(\.url.absoluteString) == ["https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos.zip"])
        #expect(yt.assets.first?.checksumURL.absoluteString == "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/SHA2-256SUMS")
        #expect(yt.assets.first?.checksumName == "yt-dlp_macos.zip")

        let deno = try #require(ToolSources.denoRelease(tag: "v2.9.7"))
        #expect(deno.version == "2.9.7")
        #expect(deno.assets.first?.url.absoluteString == "https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip")
        #expect(deno.assets.first?.checksumURL.absoluteString == "https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip.sha256sum")
        #expect(deno.assets.first?.teamID == "2H4KBF436B")
        #expect(ToolSources.ytdlpRelease(tag: "../evil") == nil)
    }

    @Test func parsesRiedlRedirect() throws {
        let release = try #require(ToolSources.riedlRelease(fromLocation: "/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip"))
        #expect(release.version == "9.0.2")
        #expect(release.assets.map(\.url.absoluteString) == [
            "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip",
            "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffprobe.zip",
        ])
        #expect(release.assets.map(\.checksumURL.absoluteString) == [
            "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip.sha256",
            "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffprobe.zip.sha256",
        ])
        #expect(release.assets.allSatisfy { $0.teamID == "KU3N25YGLU" })
        // Absolute form from the same host works too.
        #expect(ToolSources.riedlRelease(fromLocation: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip")?.version == "9.0.2")
        for bad in ["/download/macos/amd64/1789931006_9.0.2/ffmpeg.zip", "/download/linux/arm64/1_9.0.2/ffmpeg.zip",
                    "/download/macos/arm64/../../x/ffmpeg.zip", "https://evil.example/download/macos/arm64/1_9.0.2/ffmpeg.zip",
                    "/download/macos/arm64/1789931890_9.0.2/ffprobe.zip"] {
            #expect(ToolSources.riedlRelease(fromLocation: bad) == nil, "\(bad)")
        }
    }

    @Test func pinnedTeamIDs() {
        #expect(ToolSources.denoTeamID == "2H4KBF436B")
        #expect(ToolSources.riedlTeamID == "KU3N25YGLU")
    }
}

// MARK: - Verification

@Suite struct ToolVerificationTests {
    @Test func checksumPassAndFail() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "abc")
        try Data("abc".utf8).write(to: file)
        let good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try FileHash.sha256(of: file) == good)
        try ToolInstaller.verifyChecksum(of: file, expected: good.uppercased())
        #expect(throws: ToolInstallError.self) {
            try ToolInstaller.verifyChecksum(of: file, expected: String(repeating: "0", count: 64))
        }
        #expect(throws: ToolInstallError.self) { try ToolInstaller.verifyChecksum(of: file, expected: nil) }
    }

    @Test func zipInspectorListsAndValidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appending(path: "ok.zip")
        try makeZip([("_internal/", 0o040755 << 16), ("_internal/Python", regularFile), ("yt-dlp_macos", 0o100755 << 16)]).write(to: ok)
        let entries = try ZipInspector.entries(of: ok)
        #expect(entries.map(\.name) == ["_internal/", "_internal/Python", "yt-dlp_macos"])
        try ZipInspector.validate(entries)
    }

    @Test func zipInspectorRejectsTraversalAndLinks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad: [(String, UInt32)] = [("../evil", regularFile), ("/abs/path", regularFile), ("a/../../b", regularFile),
                                       ("a\\..\\b", regularFile), ("", regularFile), ("link", 0o120777 << 16)]
        for (index, entry) in bad.enumerated() {
            let zip = dir.appending(path: "bad\(index).zip")
            try makeZip([("fine", regularFile), entry]).write(to: zip)
            #expect(throws: ToolInstallError.self, "\(entry.0)") { try ZipInspector.validate(ZipInspector.entries(of: zip)) }
        }
        let notZip = dir.appending(path: "plain.zip")
        try Data("hello".utf8).write(to: notZip)
        #expect(throws: ToolInstallError.self) { try ZipInspector.entries(of: notZip) }
    }

    @Test func extractionRunsOnlyOnSafeZips() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try fakeTool("tool", in: source, output: "1.0")
        let zip = dir.appending(path: "tool.zip")
        let made = await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", source.appending(path: "tool").path, zip.path], timeout: 20)
        #expect(made.status == 0)
        let out = dir.appending(path: "out")
        try await ToolInstaller.extract(zip, to: out)
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "tool").path))
    }

    @Test func signatureCheckFailsClosed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try fakeTool("deno", in: dir, output: "deno 2.9.7")
        #expect(await CodeSignature.verify(script, teamID: ToolSources.denoTeamID) == false)
        #expect(await CodeSignature.verify(URL(filePath: "/bin/ls"), teamID: ToolSources.riedlTeamID) == false)
        #expect(await CodeSignature.verify(dir.appending(path: "missing"), teamID: ToolSources.riedlTeamID) == false)
    }

    @Test func requirementPinsTeam() {
        #expect(CodeSignature.requirement(teamID: "KU3N25YGLU") == "anchor apple generic and certificate leaf[subject.OU] = \"KU3N25YGLU\"")
    }
}

// MARK: - yt-dlp command line

@Suite struct MediaCommandTests {
    static let tools = MediaToolPaths(ytdlp: URL(filePath: "/T/yt-dlp/yt-dlp_macos"), ffmpegDirectory: URL(filePath: "/opt/homebrew/bin"),
                                      jsRuntime: "deno", jsRuntimePath: URL(filePath: "/T/deno"), toolsDirectory: URL(filePath: "/T"))

    @Test func qualityArguments() {
        let sort = ["-S", "res,vcodec:h264,ext:mp4:m4a", "--merge-output-format", "mp4/mkv"]
        #expect(MediaCommand.qualityArguments(.best) == ["-f", "bv*+ba/b"] + sort)
        #expect(MediaCommand.qualityArguments(.playable) == ["-f", "bv[vcodec!^=?vp][vcodec!^=?av01]+ba/b[vcodec!^=?vp][vcodec!^=?av01]/bv*+ba/b"] + sort)
        #expect(MediaCommand.qualityArguments(.p1080) == ["-f", "bv*[height<=1080]+ba/b[height<=1080]"] + sort)
        #expect(MediaCommand.qualityArguments(.p720) == ["-f", "bv*[height<=720]+ba/b[height<=720]"] + sort)
        #expect(MediaCommand.qualityArguments(.p480) == ["-f", "bv*[height<=480]+ba/b[height<=480]"] + sort)
        #expect(MediaCommand.qualityArguments(.audio) == ["-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a"])
        for quality in MediaQuality.allCases {
            #expect(!MediaCommand.qualityArguments(quality).contains("--remux-video"))
        }
    }

    @Test func downloadArguments() {
        let work = URL(filePath: "/W/abc")
        let args = MediaCommand.downloadArguments(url: URL(string: "https://youtu.be/x")!, quality: .p720, workDirectory: work,
                                                  tools: Self.tools, limitBytesPerSecond: 0)
        #expect(Array(args.prefix(2)) == ["--ignore-config", "--no-plugin-dirs"])
        #expect(args.containsSequence(["--no-js-runtimes", "--js-runtimes", "deno:/T/deno"]))
        #expect(args.containsSequence(["-P", "temp:/W/abc", "-P", "home:/W/abc", "-o", "media.%(ext)s"]))
        #expect(args.containsSequence(["--print", "after_move:filepath"]))
        #expect(args.containsSequence(["--print", "before_dl:ANCHORTITLE %(title)s"]))
        #expect(args.containsSequence(["--ffmpeg-location", "/opt/homebrew/bin"]))
        #expect(args.containsSequence(["--newline", "--no-playlist", "--no-mtime", "--progress"]))
        #expect(args.contains("--no-remote-components"))
        #expect(args.containsSequence(["-f", "bv*[height<=720]+ba/b[height<=720]"]))
        #expect(Array(args.suffix(2)) == ["--", "https://youtu.be/x"])
        #expect(!args.contains("--limit-rate"))
        #expect(args.containsSequence(["--concurrent-fragments", "4"]), "fragmented sites download 4 pieces at a time")
        #expect(args.contains { $0.hasPrefix("download:ANCHOR ") })
    }

    @Test func playlistQualitiesPreferPlayableStreams() {
        let sort = ["-S", "res,vcodec:h264,ext:mp4:m4a", "--merge-output-format", "mp4/mkv"]
        let playable = "[vcodec!^=?vp][vcodec!^=?av01]"
        #expect(MediaCommand.qualityArguments(.p720, playableOnly: true)
                == ["-f", "bv[height<=720]\(playable)+ba/b[height<=720]\(playable)/bv*[height<=720]+ba/b[height<=720]"] + sort)
        #expect(MediaCommand.qualityArguments(.best, playableOnly: true) == ["-f", "bv\(playable)+ba/b\(playable)/bv*+ba/b"] + sort)
        #expect(MediaCommand.qualityArguments(.audio, playableOnly: true) == MediaCommand.qualityArguments(.audio))
        #expect(MediaQuality.playlistOptions == [.best, .p1080, .p720, .p480, .p360, .audio])
    }

    @Test func subtitleArguments() {
        let english = MediaSubtitle(code: "en", name: "English", automatic: false)
        let auto = MediaSubtitle(code: "en-orig", name: "English", automatic: true)
        #expect(MediaCommand.subtitleArguments(english, quality: .p1080) == ["--write-subs", "--sub-langs", "en", "--embed-subs"])
        #expect(MediaCommand.subtitleArguments(auto, quality: .best) == ["--write-auto-subs", "--sub-langs", "en-orig", "--embed-subs"])
        #expect(MediaCommand.subtitleArguments(english, quality: .audio).isEmpty, "audio files have nowhere to put them")
        #expect(MediaCommand.subtitleArguments(nil, quality: .best).isEmpty)
        let args = MediaCommand.downloadArguments(url: URL(string: "https://youtu.be/x")!, quality: .p720, subtitle: english,
                                                  workDirectory: URL(filePath: "/W"), tools: Self.tools, limitBytesPerSecond: 0)
        #expect(args.containsSequence(["--write-subs", "--sub-langs", "en", "--embed-subs"]))
        #expect(Array(args.suffix(2)) == ["--", "https://youtu.be/x"])
    }

    @Test func limitRateUsesTheSmallerLimit() {
        #expect(MediaCommand.limit(global: 0, itemKB: nil) == 0)
        #expect(MediaCommand.limit(global: 2_000_000, itemKB: nil) == 2_000_000)
        #expect(MediaCommand.limit(global: 0, itemKB: 500) == 500_000)
        #expect(MediaCommand.limit(global: 2_000_000, itemKB: 500) == 500_000)
        #expect(MediaCommand.limit(global: 300_000, itemKB: 500) == 300_000)
        let args = MediaCommand.downloadArguments(url: URL(string: "https://youtu.be/x")!, quality: .best, workDirectory: URL(filePath: "/W"),
                                                  tools: Self.tools, limitBytesPerSecond: 500_000)
        #expect(args.containsSequence(["--limit-rate", "500000"]))
        #expect(!args.contains("--concurrent-fragments"), "the limit applies per fragment, so one at a time")
    }

    @Test func probeArguments() {
        let args = MediaCommand.probeArguments(url: URL(string: "https://youtu.be/x")!, tools: Self.tools)
        #expect(Array(args.prefix(2)) == ["--ignore-config", "--no-plugin-dirs"])
        #expect(args.containsSequence(["--dump-single-json", "--no-playlist", "--flat-playlist", "--playlist-items", "1:300", "--skip-download"]),
                "a playlist is listed without opening every video, and only its first 300")
        #expect(args.containsSequence(["--no-js-runtimes", "--js-runtimes", "deno:/T/deno"]))
        #expect(Array(args.suffix(2)) == ["--", "https://youtu.be/x"])
    }

    @Test func minimalEnvironment() {
        let env = MediaCommand.environment(tools: Self.tools, home: "/Users/me", temp: "/tmp/x")
        #expect(env["PATH"] == "/T:/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/me")
        #expect(Set(env.keys) == ["PATH", "HOME", "LANG", "TMPDIR"])
    }
}

extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<($0 + sequence.count)]) == sequence }
    }
}

// MARK: - Playlists and subtitles

@Suite struct PlaylistProbeTests {
    @Test func listsAPlaylistsVideosInOrder() throws {
        let json = #"""
        {"_type":"playlist","title":"Coding Challenges","uploader":"The Coding Train","extractor_key":"YoutubeTab","playlist_count":246,
         "entries":[
          {"_type":"url","ie_key":"Youtube","url":"https://www.youtube.com/watch?v=a","title":"One","duration":834,
           "thumbnails":[{"url":"https://i.ytimg.com/a/1.jpg","width":120},{"url":"https://i.ytimg.com/a/2.jpg","width":168}]},
          {"_type":"url","url":"https://www.youtube.com/watch?v=b","title":"Two"},
          {"_type":"url","url":"https://www.youtube.com/watch?v=a","title":"One again"},
          {"_type":"url","url":"c","title":"A bare id"}
         ]}
        """#
        let result = try MediaProbeResult.decode(Data(json.utf8))
        #expect(result.isPlaylist)
        #expect(result.playlistCount == 246)
        let videos = result.videos
        #expect(videos.map(\.title) == ["One", "Two"], "repeats and bare ids are dropped")
        #expect(videos[0].duration == 834)
        #expect(videos[0].thumbnail == URL(string: "https://i.ytimg.com/a/2.jpg"), "the first thumbnail at least 160 wide")
        #expect(videos[1].thumbnail == nil)
        let allTitled = videos.allSatisfy(\.titled)
        #expect(allTitled)
    }

    @Test func untitledEntriesGetAStandIn() throws {
        // Dailymotion lists a channel's videos without titles.
        let json = #"{"_type":"playlist","entries":[{"_type":"url","url":"https://www.dailymotion.com/video/x7tgad0"}]}"#
        let videos = try MediaProbeResult.decode(Data(json.utf8)).videos
        #expect(videos.map(\.title) == ["Video 1"])
        #expect(videos[0].titled == false, "renamed when yt-dlp reports the real title")
    }

    @Test func flattensAChannelsTabs() throws {
        let json = #"""
        {"_type":"playlist","title":"Channel","entries":[
          {"_type":"playlist","title":"Channel - Videos","entries":[{"_type":"url","url":"https://www.youtube.com/watch?v=v1","title":"V1"}]},
          {"_type":"playlist","title":"Channel - Shorts","entries":[{"_type":"url","url":"https://www.youtube.com/shorts/s1","title":"S1"}]},
          {"_type":"playlist","title":"Channel - Live","url":"https://www.youtube.com/@c/streams"}
        ]}
        """#
        let result = try MediaProbeResult.decode(Data(json.utf8))
        #expect(result.videos.map(\.title) == ["V1", "S1"], "a tab without its own entries isn't a video")
    }

    @Test func channelLinksProbeTheirVideosTab() {
        func probe(_ link: String) -> String { MediaLinkDetector.probeURL(for: URL(string: link)!).absoluteString }
        #expect(probe("https://www.youtube.com/@TheCodingTrain") == "https://www.youtube.com/@TheCodingTrain/videos")
        #expect(probe("https://youtube.com/@TheCodingTrain/") == "https://youtube.com/@TheCodingTrain/videos")
        #expect(probe("https://www.youtube.com/channel/UCabc") == "https://www.youtube.com/channel/UCabc/videos")
        #expect(probe("https://m.youtube.com/c/name") == "https://m.youtube.com/c/name/videos")
        // Already a tab, a playlist, a video, or another site: unchanged.
        for link in ["https://www.youtube.com/@a/shorts", "https://www.youtube.com/playlist?list=PL1",
                     "https://www.youtube.com/watch?v=x&list=PL1", "https://vimeo.com/@a", "https://www.youtube.com/@a/videos"] {
            #expect(probe(link) == link)
        }
    }

    @Test func subtitleOptionsPutTheVideosLanguageFirst() throws {
        let json = #"""
        {"title":"t","extractor":"youtube","language":"en",
         "subtitles":{"fr":[{"ext":"vtt","name":"French"}],"en-US":[{"ext":"vtt","name":"English (United States)"}],
                      "de":[{"ext":"vtt","name":"German"}],"live_chat":[{"ext":"json"}],"es":[]},
         "automatic_captions":{"en-orig":[{"ext":"vtt","name":"English (Original)"}],"fr":[{"ext":"vtt","name":"French"}]}}
        """#
        let options = try MediaProbeResult.decode(Data(json.utf8)).subtitleOptions
        #expect(options.map(\.code) == ["en-US", "fr", "de"],
                "the spoken language first, then by name (French, German); no live chat, no empty languages")
        #expect(!options.contains { $0.automatic }, "the uploader's own English beats the automatic captions")
    }

    @Test func automaticCaptionsWhenThereAreNoOthers() throws {
        let json = #"""
        {"title":"t","extractor":"youtube","language":"en",
         "automatic_captions":{"en-orig":[{"ext":"vtt","name":"English (Original)"}],"en":[{"ext":"vtt"}],"de":[{"ext":"vtt"}]}}
        """#
        let options = try MediaProbeResult.decode(Data(json.utf8)).subtitleOptions
        #expect(options == [MediaSubtitle(code: "en-orig", name: "English (Original)", automatic: true)],
                "only the original speech recognition, not the ~150 machine translations")
        #expect(options[0].title == "English (Original) (auto-generated)")
        let none = try MediaProbeResult.decode(Data(#"{"title":"t","extractor":"x"}"#.utf8))
        #expect(none.subtitleOptions.isEmpty)
    }

    @Test func playlistAndSubtitleFieldsRoundTrip() throws {
        var item = DownloadItem(url: URL(string: "https://youtu.be/x")!, fileName: "01 Clip.mp4", directory: URL(filePath: "/D"),
                                category: .video, kind: .media)
        item.mediaPlayableOnly = true
        item.mediaSubtitle = MediaSubtitle(code: "en", name: "English", automatic: false)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.mediaPlayableOnly == true)
        #expect(decoded.mediaSubtitle == item.mediaSubtitle)
    }
}

// MARK: - Progress parsing

@Suite struct MediaProgressTests {
    @Test func parsesProgressLines() throws {
        let line = try #require(MediaOutput.parse("ANCHOR  42.0%|130048|309288|NA|5288855.727422576|3"))
        guard case .progress(let p) = line else { Issue.record("not progress"); return }
        #expect(p.downloaded == 130048)
        #expect(p.total == 309288)
        #expect(p.estimate == nil)
        #expect(p.speed == 5288855.727422576)
        #expect(p.eta == 3)
    }

    @Test func naValuesBecomeNil() throws {
        guard case .progress(let p) = try #require(MediaOutput.parse("ANCHOR NA|1024|NA|NA|NA|NA")) else {
            Issue.record("not progress"); return
        }
        #expect(p.downloaded == 1024)
        #expect(p.total == nil)
        #expect(p.estimate == nil)
        #expect(p.speed == nil)
        #expect(p.eta == nil)
        guard case .progress(let e) = try #require(MediaOutput.parse("ANCHOR   5.1%|2048|NA|40000.5|none|12")) else {
            Issue.record("not progress"); return
        }
        #expect(e.estimate == 40000)
        #expect(e.speed == nil)
    }

    @Test func titleLines() {
        #expect(MediaOutput.parse("ANCHORTITLE Midnight Sun | Iceland") == .title("Midnight Sun | Iceland"))
        #expect(MediaOutput.parse("ANCHORTITLE NA") == nil)
        #expect(MediaOutput.parse("ANCHORTITLE   ") == nil)
    }

    @Test func otherLines() {
        #expect(MediaOutput.parse("ANCHORPP Merger|started") == .processing(.merging))
        #expect(MediaOutput.parse("ANCHORPP FixupM3u8|started") == .processing(.processing))
        #expect(MediaOutput.parse("ANCHORPP MoveFiles|finished") == nil)
        #expect(MediaOutput.parse("[youtube] abc: Downloading webpage") == nil)
        #expect(MediaOutput.parse("ERROR: [youtube] abc: This video is unavailable") == .error("This video is unavailable"))
        #expect(MediaOutput.parse("ERROR: Unable to download: HTTP Error 403") == .error("Unable to download: HTTP Error 403"))
        #expect(MediaOutput.parse("/W/abc/media.mp4") == .path("/W/abc/media.mp4"))
    }

    @Test func trackerAddsFinishedStreams() {
        var tracker = MediaProgressTracker()
        var snap = tracker.update(MediaProgress(downloaded: 1000, total: 223779, estimate: nil, speed: 10, eta: 5))
        #expect(snap.received == 1000)
        #expect(snap.total == 223779)
        snap = tracker.update(MediaProgress(downloaded: 223779, total: 223779, estimate: nil, speed: 10, eta: 0))
        // The audio stream starts over at a small count.
        snap = tracker.update(MediaProgress(downloaded: 1024, total: 309288, estimate: nil, speed: 10, eta: 9))
        #expect(snap.received == 223779 + 1024)
        #expect(snap.total == Int64(223779 + 309288))
        snap = tracker.update(MediaProgress(downloaded: 4096, total: nil, estimate: 310000, speed: nil, eta: nil))
        #expect(snap.received == 223779 + 4096)
        #expect(snap.total == Int64(223779 + 310000))
    }

    /// With 4 fragments at a time yt-dlp's count can step back a little (seen: 21661572 then 21566692).
    @Test func smallStepBackIsNotANewStream() {
        var tracker = MediaProgressTracker()
        _ = tracker.update(MediaProgress(downloaded: 21_661_572, total: nil, estimate: 41_759_691, speed: nil, eta: nil))
        let snap = tracker.update(MediaProgress(downloaded: 21_566_692, total: nil, estimate: 41_916_182, speed: nil, eta: nil))
        #expect(snap.received == 21_661_572, "progress holds instead of jumping past 100%")
        #expect(snap.total == 41_916_182)
        let next = tracker.update(MediaProgress(downloaded: 22_000_000, total: nil, estimate: 41_916_182, speed: nil, eta: nil))
        #expect(next.received == 22_000_000)
    }
}

// MARK: - Process ownership

@Suite struct MediaProcessTests {
    @Test func generationGate() {
        var gate = GenerationGate()
        let first = gate.next()
        #expect(gate.accepts(first))
        let second = gate.next()
        #expect(!gate.accepts(first))
        #expect(gate.accepts(second))
    }

    @Test func reportsLinesAndStatus() async throws {
        let lines = LineBox()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = MediaProcess(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "echo one; echo two 1>&2; exit 3"],
                                       environment: ["PATH": "/usr/bin:/bin"], onLine: { lines.append($0) },
                                       onFinish: { continuation.resume(returning: $0) })
            do { try process.start() } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 3)
        #expect(Set(lines.all) == ["one", "two"])
    }

    @Test func terminateStopsAndWaits() async throws {
        let process = MediaProcess(executable: URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:],
                                   onLine: { _ in }, onFinish: { _ in })
        try process.start()
        let pid = process.pid
        let started = Date()
        await process.terminate()
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(!process.isRunning)
        #expect(kill(pid, 0) != 0)
    }

    @Test func escalatesToKill() async throws {
        let process = MediaProcess(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while true; do sleep 1; done"],
                                   environment: ["PATH": "/usr/bin:/bin"], onLine: { _ in }, onFinish: { _ in })
        try process.start()
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        await process.terminate(grace: 0.5)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(!process.isRunning)
    }

    /// Pausing a merge or conversion freezes yt-dlp and the ffmpeg it started; resuming continues both.
    @Test func suspendFreezesTheWholeTree() async throws {
        let process = MediaProcess(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "sleep 30 & wait"],
                                   environment: ["PATH": "/usr/bin:/bin"], onLine: { _ in }, onFinish: { _ in })
        try process.start()
        try await Task.sleep(for: .milliseconds(300))
        var children = [pid_t](repeating: 0, count: 8)
        let count = proc_listchildpids(process.pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        let child = try #require(count > 0 ? children[0] : nil)

        process.suspend()
        #expect(process.isSuspended)
        #expect(stopped(process.pid) && stopped(child))
        process.resume()
        #expect(!process.isSuspended)
        #expect(!stopped(process.pid) && !stopped(child))

        // Cancelling while frozen still ends it.
        process.suspend()
        let started = Date()
        await process.terminate(grace: 1)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(!process.isRunning)
        kill(child, SIGKILL)
    }

    private func stopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_stat == SSTOP
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

// MARK: - Finishing

@Suite struct MediaFinisherTests {
    @Test func movesTheResultAndCleansUp() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appending(path: "work")
        let dest = root.appending(path: "dest")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: work.appending(path: "media.mp4"))

        let name = try MediaFinisher.finish(printedPath: work.appending(path: "media.mp4").path, workDirectory: work,
                                            stem: "Me at the zoo", into: dest, taken: [])
        #expect(name == "Me at the zoo.mp4")
        #expect(FileManager.default.fileExists(atPath: dest.appending(path: "Me at the zoo.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test func avoidsExistingNames() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: work.appending(path: "media.m4a"))
        try Data("old".utf8).write(to: root.appending(path: "Song.m4a"))
        let name = try MediaFinisher.finish(printedPath: work.appending(path: "media.m4a").path, workDirectory: work,
                                            stem: "Song", into: root, taken: ["Song (2).m4a"])
        #expect(name == "Song (3).m4a")
        #expect(try String(contentsOf: root.appending(path: "Song.m4a"), encoding: .utf8) == "old")
    }

    @Test func rejectsPathsOutsideTheWorkDirectory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appending(path: "work")
        let outside = root.appending(path: "secret.txt")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: work.appending(path: "media.mp4"), withDestinationURL: outside)

        for printed in [outside.path, work.appending(path: "../secret.txt").path, work.appending(path: "media.mp4").path,
                        work.appending(path: "missing.mp4").path, root.appending(path: "work-evil/media.mp4").path] {
            #expect(throws: MediaFinishError.self, "\(printed)") {
                try MediaFinisher.finish(printedPath: printed, workDirectory: work, stem: "x", into: root, taken: [])
            }
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

// MARK: - Probe results

@Suite struct MediaProbeResultTests {
    static let json = """
    {"title":"Me at the zoo","extractor":"youtube","extractor_key":"Youtube","duration":19,"uploader":"jawed",
     "thumbnail":"https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg","filesize_approx":475961,"_type":"video",
     "formats":[
       {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":309288,"abr":129},
       {"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus","filesize":280000,"abr":140},
       {"format_id":"134","ext":"mp4","vcodec":"avc1","acodec":"none","height":360,"filesize":223779},
       {"format_id":"136","ext":"mp4","vcodec":"avc1","acodec":"none","height":720,"filesize_approx":900000},
       {"format_id":"18","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":360,"filesize":500000}
     ]}
    """

    @Test func decodesAndEstimates() throws {
        let result = try MediaProbeResult.decode(Data(Self.json.utf8))
        #expect(result.title == "Me at the zoo")
        #expect(!result.isGeneric)
        #expect(result.info.duration == 19)
        #expect(result.uploader == "jawed")
        #expect(result.estimatedSize(.best) == Int64(900000 + 309288))
        #expect(result.estimatedSize(.p480) == Int64(223779 + 309288))
        #expect(result.estimatedSize(.audio) == 309288)
    }

    @Test func genericAndPlaylistsAreNotMedia() throws {
        let generic = try MediaProbeResult.decode(Data(#"{"title":"Page","extractor":"generic","extractor_key":"Generic"}"#.utf8))
        #expect(generic.isGeneric)
        let playlist = try MediaProbeResult.decode(Data(#"{"title":"List","extractor":"youtube:tab","extractor_key":"YoutubeTab","_type":"playlist"}"#.utf8))
        #expect(playlist.isPlaylist)
    }
}

@Suite struct MediaQualityOptionTests {
    private func result(_ formats: [(Int?, Int?, String, String)]) throws -> MediaProbeResult {
        let list = formats.map { h, w, v, a in
            ["height": h as Any, "width": w as Any, "vcodec": v, "acodec": a, "ext": "mp4"].compactMapValues { $0 is NSNull ? nil : $0 }
        }
        let json = try JSONSerialization.data(withJSONObject: ["title": "x", "extractor": "youtube", "formats": list])
        return try MediaProbeResult.decode(json)
    }

    @Test func offersEveryLevelTheVideoHas() throws {
        let r = try result([(2160, 3840, "vp9", "none"), (1440, 2560, "vp9", "none"), (1080, 1920, "avc1", "none"),
                            (720, 1280, "avc1", "none"), (480, 854, "avc1", "none"), (360, 640, "avc1", "none"),
                            (240, 426, "avc1", "none"), (144, 256, "avc1", "none"), (nil, nil, "none", "mp4a")])
        #expect(r.availableQualities == [.best, .p2160, .p1440, .p1080, .p720, .p480, .p360, .p240, .p144, .audio])
        #expect(r.defaultQuality == .p1080, "4K and 1440p need converting, so start on the tallest that doesn't")
    }

    @Test func noLevelsAboveTheTallestStream() throws {
        let r = try result([(1088, 1920, "avc1", "none"), (720, 1280, "avc1", "none"), (nil, nil, "none", "mp4a")])
        #expect(r.availableQualities == [.best, .p1080, .p720, .audio])
    }

    @Test func portraitVideosOnlyGetBestAndAudio() throws {
        let r = try result([(1920, 1080, "avc1", "mp4a"), (1280, 720, "avc1", "mp4a")])
        #expect(r.availableQualities == [.best, .audio])
    }

    @Test func newLevelsMapToHeightCaps() {
        #expect(MediaQuality.p2160.title == "4K")
        #expect(MediaQuality.p1440.title == "1440p")
        #expect(MediaCommand.qualityArguments(.p1440).prefix(2) == ["-f", "bv*[height<=1440]+ba/b[height<=1440]"])
        #expect(MediaQuality(rawValue: "p720") == .p720, "existing saved values still decode")
    }

    @Test func onlyVP9AndAV1QualitiesNeedConverting() throws {
        let r = try result([(2160, 3840, "vp09.00.50.08", "none"), (1440, 2560, "av01.0.12M.08", "none"),
                            (1080, 1920, "av01.0.08M.08", "none"), (1080, 1920, "avc1.640028", "none"),
                            (720, 1280, "vp09.00.31.08", "none"), (720, 1280, "avc1.4D401F", "none"),
                            (nil, nil, "none", "mp4a")])
        #expect(r.conversionHeight(.best) == 2160)
        #expect(r.chosenVideo(.playable)?.vcodec == "avc1.640028")
        #expect(r.conversionHeight(.playable) == nil)
        #expect(r.conversionHeight(.p2160) == 2160)
        #expect(r.conversionHeight(.p1440) == 1440)
        #expect(r.conversionHeight(.p1080) == nil, "an H.264 stream exists at 1080p")
        #expect(r.conversionHeight(.p720) == nil)
        #expect(r.conversionHeight(.audio) == nil)
        #expect(r.chosenVideo(.p1080)?.vcodec == "avc1.640028")
    }

    @Test func convertingReencodesToH264MP4() {
        #expect(MediaEncoder.arguments(shortSide: 2160, hardware: true) == ["-c:v", "h264_videotoolbox", "-b:v", "35000k"])
        #expect(MediaEncoder.arguments(shortSide: 720, hardware: false).contains("libx264"))
        let args = MediaCommand.qualityArguments(.p2160, convert: true)
        #expect(args[args.firstIndex(of: "--merge-output-format")! + 1] == "mkv")
        #expect(!args.contains("--recode-video"), "Anchor converts afterwards so it can show progress")
        #expect(MediaCommand.qualityArguments(.p1080).last == "mp4/mkv")
        let ffmpeg = MediaConversion(shortSide: 2160, hardware: true, duration: 60)
            .arguments(input: URL(filePath: "/w/media.mkv"), output: URL(filePath: "/w/converted.mp4"))
        #expect(ffmpeg.contains("h264_videotoolbox"))
        #expect(ffmpeg.suffix(4) == ["-progress", "pipe:1", "-nostats", "/w/converted.mp4"])
        #expect(ffmpeg.containsSequence(["-map", "0:s?"]), "embedded subtitles survive the conversion")
        #expect(ffmpeg.containsSequence(["-c:s", "mov_text"]), "as the text track MP4 holds")
    }

    @Test func conversionBitrateFollowsTheSource() {
        // The Instagram reel: 1080×1920 VP9 at about 1 Mbps, 56 s, 7 MB. It used to get 16 Mbps (about 112 MB).
        let reel = MediaConversion(shortSide: 1080, hardware: true, duration: 56)
            .arguments(input: URL(filePath: "/w/media.mkv"), output: URL(filePath: "/w/converted.mp4"), sourceBytes: 7_000_000)
        #expect(reel[reel.firstIndex(of: "-b:v")! + 1] == "2000k")
        #expect(MediaEncoder.bitrate(shortSide: 1080, sourceBitsPerSecond: 50_000_000) == 8_000_000, "capped by size")
        #expect(MediaEncoder.bitrate(shortSide: 2160, sourceBitsPerSecond: 100_000) == 1_000_000, "at least 1 Mbps")
        #expect(MediaEncoder.bitrate(shortSide: 1080, sourceBitsPerSecond: nil) == 8_000_000)
    }

    @Test func portraitConversionUsesTheShortSide() throws {
        let reel = try result([(1920, 1080, "vp09.00.40.08", "none"), (nil, nil, "none", "mp4a")])
        #expect(reel.conversionHeight(.best) == 1080)
    }

    @Test func bestPrefersInstagramsPlayableFile() throws {
        // The reel: VP9 DASH streams up to 1080×1920, plus progressive MP4s with no codec or size info (H.264, 5 MB).
        let json = #"{"title":"r","extractor":"Instagram","formats":[{"format_id":"a","vcodec":"none","acodec":"mp4a.40.5","ext":"m4a"},{"format_id":"1","ext":"mp4"},{"format_id":"v","vcodec":"vp09.00.40.08","acodec":"none","height":1920,"width":1080,"ext":"mp4"}]}"#
        let reel = try MediaProbeResult.decode(Data(json.utf8))
        #expect(reel.conversionHeight(.best) == 1080, "Best is the 1080p VP9, converted")
        #expect(reel.conversionHeight(.playable) == nil, "the progressive MP4 plays as is")
        #expect(reel.chosenVideo(.playable)?.vcodec == nil)
        #expect(reel.availableQualities == [.best, .playable, .audio])
        #expect(reel.defaultQuality == .playable, "start on the file that needs no conversion")
    }

    @Test func readsConversionProgress() {
        var progress = MediaConversionProgress(duration: 100)
        #expect(progress.feed("frame=120") == nil)
        #expect(progress.feed("out_time_us=25000000") == nil)
        #expect(progress.feed("speed=2.5x") == nil)
        let update = progress.feed("progress=continue")
        #expect(update?.fraction == 0.25)
        #expect(update?.eta == 30)
        #expect(progress.feed("speed=N/A") == nil)
        #expect(progress.feed("progress=end")?.fraction == 1)
        var unknown = MediaConversionProgress(duration: nil)
        _ = unknown.feed("out_time_us=1000000")
        #expect(unknown.feed("progress=continue")?.fraction == nil)
    }

    @Test func phaseLabels() {
        #expect(MediaPhase.merging.label == "Merging…")
        #expect(MediaPhase.converting(fraction: 0.42, eta: 125).detail == "Converting to MP4 so it plays in QuickTime · 42% · 2m 5s left")
        var item = DownloadItem(url: URL(string: "https://youtu.be/x")!, fileName: "a.mp4", directory: URL(filePath: "/tmp"),
                                category: .video, kind: .media)
        item.totalBytes = 100
        item.receivedBytes = 100
        item.mediaPhase = .converting(fraction: 0.3, eta: 10)
        #expect(item.progress == 0.3, "the bar follows the conversion")
    }
}

@Suite struct MediaFailureTests {
    static let youtubeBotCheck = "Sign in to confirm you\u{2019}re not a bot. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp for how to manually pass cookies."

    @Test func sortsCommonErrors() {
        #expect(MediaErrors.kind(of: Self.youtubeBotCheck) == .botCheck, "the bot check, not the generic sign-in case")
        #expect(MediaErrors.kind(of: "Private video. Sign in if you've been granted access to this video") == .signIn)
        #expect(MediaErrors.kind(of: "Sign in to confirm your age. This video may be inappropriate for some users.") == .signIn)
        #expect(MediaErrors.kind(of: "The uploader has not made this video available in your country") == .region)
        #expect(MediaErrors.kind(of: "Video unavailable. This video has been removed by the uploader") == .unavailable)
        #expect(MediaErrors.kind(of: "Unable to download webpage: <urlopen error [Errno 60] Operation timed out>") == .network)
        #expect(MediaErrors.kind(of: "Requested format is not available") == .other)
    }

    @Test func mentionsRateLimiting() {
        #expect(MediaOutput.parse("WARNING: [youtube] h5R-cg1M_Oc: Unable to download webpage: HTTP Error 429: Too Many Requests (caused by <HTTPError 429: Too Many Requests>)") == .rateLimited)
        #expect(MediaOutput.parse("WARNING: [youtube] Unable to fetch GVS PO Token for web client") == nil)
        let limited = Self.youtubeBotCheck + " " + MediaErrors.rateLimitNote
        #expect(MediaErrors.kind(of: limited) == .botCheck)
        #expect(MediaErrors.friendly(limited).contains("limiting requests from your network"))
        #expect(!MediaErrors.friendly(Self.youtubeBotCheck).contains("limiting"))
    }

    @Test func plainWordsAndNextSteps() {
        #expect(MediaErrors.friendly(Self.youtubeBotCheck).contains("confirm you're not a bot"))
        #expect(!MediaErrors.friendly(Self.youtubeBotCheck).contains("--cookies"), "no command-line flags for users")
        #expect(MediaErrors.friendly("Requested format is not available") == "Requested format is not available",
                "unknown errors keep yt-dlp's words")
        #expect(MediaFailure.botCheck.wantsCookies && MediaFailure.signIn.wantsCookies && !MediaFailure.region.wantsCookies)
        #expect(MediaFailure.botCheck.retryable && MediaFailure.network.retryable && !MediaFailure.unavailable.retryable)
    }
}

@Suite struct MediaCookiesTests {
    static let session = BrowserCookie(domain: ".youtube.com", path: "/", secure: true, hostOnly: false, expires: nil,
                                       name: "SID", value: "abc")
    static let hostOnly = BrowserCookie(domain: "www.youtube.com", path: "/", secure: true, hostOnly: true,
                                        expires: 1_900_000_000.7, name: "__Secure-YEC", value: "x=y")

    @Test func writesNetscapeFormat() {
        let text = MediaCookies.netscape([Self.session, Self.hostOnly])
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "# Netscape HTTP Cookie File")
        #expect(lines[1] == ".youtube.com\tTRUE\t/\tTRUE\t0\tSID\tabc", "session cookies have expiry 0")
        #expect(lines[2] == "www.youtube.com\tFALSE\t/\tTRUE\t1900000000\t__Secure-YEC\tx=y", "host-only cookies keep the bare host")
    }

    @Test func skipsCookiesThatWouldBreakTheFile() {
        var bad = Self.session
        bad.value = "a\tb"
        #expect(MediaCookies.netscape([bad]).split(separator: "\n").count == 1)
    }

    @Test func rebuildsFromACookieHeader() {
        let jar = MediaCookies.jar(fromHeader: "SID=abc; PREF=f6=40000000&tz=Asia.Karachi; bad", url: URL(string: "https://www.youtube.com/watch?v=x")!)
        #expect(jar.map(\.name) == ["SID", "PREF"])
        #expect(jar.allSatisfy { $0.domain == ".youtube.com" && !$0.hostOnly })
        #expect(jar[1].value == "f6=40000000&tz=Asia.Karachi", "only the first = splits")
    }

    @Test func onlyTheExtensionsCookiesAreUsed() {
        #expect(MediaCookies.choose(jar: [Self.session]) == .jar([Self.session]))
        #expect(MediaCookies.choose(jar: nil) == .none, "no browser cookie store is ever read")
        #expect(MediaCookies.choose(jar: []) == .none)
    }

    @Test func argumentsAndAPrivateFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "anchor-cookies-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MediaCookies.none.arguments(writingTo: dir).isEmpty)
        let args = MediaCookies.jar([Self.session]).arguments(writingTo: dir)
        let file = dir.appending(path: "cookies.txt")
        #expect(args == ["--cookies", file.path])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600, "only this user can read the cookies")
    }

    @Test func cookiesGoBeforeTheLink() {
        let tools = MediaCommandTests.tools
        let args = MediaCommand.downloadArguments(url: URL(string: "https://youtu.be/x")!, quality: .best, workDirectory: URL(filePath: "/W"),
                                                  tools: tools, limitBytesPerSecond: 0, cookies: ["--cookies", "/W/c.txt"])
        #expect(args.containsSequence(["--cookies", "/W/c.txt"]))
        #expect(Array(args.suffix(2)) == ["--", "https://youtu.be/x"])
        let probe = MediaCommand.probeArguments(url: URL(string: "https://youtu.be/x")!, tools: tools, cookies: ["--cookies", "/W/c.txt"])
        #expect(probe.containsSequence(["--cookies", "/W/c.txt"]))
    }

    @Test func decodesTheExtensionsCookies() throws {
        // The shape the extension sends (from chrome.cookies, trimmed to what yt-dlp needs).
        let json = #"[{"domain":".youtube.com","path":"/","secure":true,"hostOnly":false,"expires":1900000000,"name":"SID","value":"abc"},{"domain":"www.youtube.com","path":"/","secure":true,"hostOnly":true,"name":"S","value":"1"}]"#
        let jar = try JSONDecoder().decode([BrowserCookie].self, from: Data(json.utf8))
        #expect(jar.count == 2)
        #expect(jar[1].expires == nil, "session cookies have no expiry")
    }
}
