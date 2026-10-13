import Foundation

/// One file of a release, with where its published SHA-256 lives.
struct ReleaseAsset: Equatable, Sendable {
    /// The file name inside the release, also the name looked up in the checksum file.
    var checksumName: String
    var url: URL
    var checksumURL: URL
    /// The vendor's Apple Team ID the extracted executable must be signed with; nil when the vendor doesn't sign.
    var teamID: String?
    /// The executable inside the zip, checked for its signature and made executable.
    var executable: String
}

/// One pinned release: everything is downloaded from these exact URLs.
struct ToolRelease: Equatable, Sendable {
    var tool: ToolID
    var version: String
    var assets: [ReleaseAsset]
}

/// Where each tool comes from. Read from the current releases on 2026-10-12, see the plan's research notes.
enum ToolSources {
    /// Developer ID Application: Deno Land Inc.
    static let denoTeamID = "2H4KBF436B"
    /// Developer ID Application: Martin Riedl
    static let riedlTeamID = "KU3N25YGLU"

    static let ytdlpLatestAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    static let denoLatestAPI = URL(string: "https://api.github.com/repos/denoland/deno/releases/latest")!
    /// Martin Riedl's documented scripting URL; it redirects to the newest release build's folder.
    static let riedlLatest = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip")!
    static let riedlHost = "ffmpeg.martin-riedl.de"

    /// The yt-dlp folder inside Tools and the executable in it (the onedir build, see the plan's Deviations).
    static let ytdlpFolder = "yt-dlp"
    static let ytdlpExecutable = "yt-dlp_macos"

    /// Tags are used in URLs, so only plain version tags are accepted.
    static func isValidTag(_ tag: String, for tool: ToolID) -> Bool {
        let pattern: String
        switch tool {
        case .ytdlp: pattern = #"^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]+)?$"#
        case .deno: pattern = #"^v[0-9]+\.[0-9]+\.[0-9]+$"#
        case .ffmpeg: return false
        }
        return tag.range(of: pattern, options: .regularExpression) != nil
    }

    static func ytdlpRelease(tag: String) -> ToolRelease? {
        guard isValidTag(tag, for: .ytdlp) else { return nil }
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/"
        let asset = ReleaseAsset(checksumName: "yt-dlp_macos.zip", url: URL(string: base + "yt-dlp_macos.zip")!,
                                 checksumURL: URL(string: base + "SHA2-256SUMS")!, teamID: nil, executable: ytdlpExecutable)
        return ToolRelease(tool: .ytdlp, version: tag, assets: [asset])
    }

    static func denoRelease(tag: String) -> ToolRelease? {
        guard isValidTag(tag, for: .deno) else { return nil }
        let base = "https://github.com/denoland/deno/releases/download/\(tag)/"
        let name = "deno-aarch64-apple-darwin.zip"
        let asset = ReleaseAsset(checksumName: name, url: URL(string: base + name)!,
                                 checksumURL: URL(string: base + name + ".sha256sum")!, teamID: denoTeamID, executable: "deno")
        return ToolRelease(tool: .deno, version: String(tag.dropFirst()), assets: [asset])
    }

    /// Reads the redirect target of `riedlLatest`, e.g. `/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip`,
    /// and pins that build folder for ffmpeg and ffprobe.
    static func riedlRelease(fromLocation location: String) -> ToolRelease? {
        var path = location
        if let url = URL(string: location), url.scheme != nil {
            guard url.scheme == "https", url.host() == riedlHost else { return nil }
            path = url.path
        }
        let pattern = #"^/download/macos/arm64/([0-9]+)_([0-9]+(\.[0-9]+)*)/ffmpeg\.zip$"#
        guard let match = path.range(of: pattern, options: .regularExpression), match == path.startIndex..<path.endIndex else { return nil }
        let folder = path.split(separator: "/")[3]
        guard let underscore = folder.firstIndex(of: "_") else { return nil }
        let version = String(folder[folder.index(after: underscore)...])
        let base = "https://\(riedlHost)/download/macos/arm64/\(folder)/"
        let assets = ["ffmpeg", "ffprobe"].map { name in
            ReleaseAsset(checksumName: "\(name).zip", url: URL(string: base + "\(name).zip")!,
                         checksumURL: URL(string: base + "\(name).zip.sha256")!, teamID: riedlTeamID, executable: name)
        }
        return ToolRelease(tool: .ffmpeg, version: version, assets: assets)
    }

    // MARK: Network

    /// Resolves the newest release once; all assets then come from it.
    static func latestRelease(_ tool: ToolID) async throws -> ToolRelease {
        switch tool {
        case .ytdlp:
            guard let release = ytdlpRelease(tag: try await latestTag(ytdlpLatestAPI)) else { throw ToolInstallError.badRelease }
            return release
        case .deno:
            guard let release = denoRelease(tag: try await latestTag(denoLatestAPI)) else { throw ToolInstallError.badRelease }
            return release
        case .ffmpeg:
            // GET without following the redirect: the server answers HEAD inconsistently, and only the
            // Location header is needed (the zip itself is fetched later from the pinned folder).
            let request = URLRequest(url: riedlLatest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            let (_, response) = try await URLSession.shared.data(for: request, delegate: RedirectStopper())
            guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let release = riedlRelease(fromLocation: location) else { throw ToolInstallError.badRelease }
            return release
        }
    }

    private static func latestTag(_ api: URL) async throws -> String {
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Anchor", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { throw ToolInstallError.badRelease }
        return tag
    }
}

/// Hands back the redirect response itself instead of following it.
private final class RedirectStopper: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Checksum files: `<hex>  <name>` per line (`SHA2-256SUMS`, `.sha256sum`, `.sha256`), optionally `*<name>`.
enum Checksums {
    static func entry(named name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = parts[0].lowercased()
            var file = parts[1...].joined(separator: " ")
            if file.hasPrefix("*") { file.removeFirst() }
            guard file == name, isSHA256(hash) else { continue }
            return hash
        }
        return nil
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }
}
