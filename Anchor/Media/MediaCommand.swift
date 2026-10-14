import Foundation
import Synchronization

/// The quality picker in the New Download window.
enum MediaQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `playable`: the best stream that plays without converting, offered when Best would need converting and the
    /// height options don't already cover it (portrait videos, or files with no size info, like Instagram's).
    case best, playable, p2160, p1440, p1080, p720, p480, p360, p240, p144, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: "Best"
        case .playable: "No conversion"
        case .p2160: "4K"
        case .audio: "Audio only"
        default: "\(maxHeight ?? 0)p"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .p360: 360
        case .p240: 240
        case .p144: 144
        case .best, .playable, .audio: nil
        }
    }

    var isAudio: Bool { self == .audio }
    /// Extension used for the name until the real one is known.
    var expectedExtension: String { isAudio ? "m4a" : "mp4" }
    var category: FileCategory { isAudio ? .music : .video }
}

/// The ffmpeg video arguments for converting to H.264: the hardware encoder when ffmpeg has it, else x264.
enum MediaEncoder {
    /// The most a video of this size needs, by its short side (so a 1080×1920 reel counts as 1080p).
    static func maxBitrate(shortSide: Int) -> Int {
        switch shortSide {
        case 2000...: 35_000_000
        case 1300...: 16_000_000
        case 1000...: 8_000_000
        case 700...: 5_000_000
        default: 2_500_000
        }
    }

    /// Twice the source's bitrate (H.264 needs about that to match VP9 or AV1), at least 1 Mbps and at most
    /// `maxBitrate`. Without a known source bitrate, `maxBitrate`.
    static func bitrate(shortSide: Int, sourceBitsPerSecond: Double?) -> Int {
        let cap = maxBitrate(shortSide: shortSide)
        guard let source = sourceBitsPerSecond, source.isFinite, source > 0 else { return cap }
        return min(cap, max(1_000_000, Int(source * 2)))
    }

    static func arguments(shortSide: Int, hardware: Bool, sourceBitsPerSecond: Double? = nil) -> [String] {
        hardware ? ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate(shortSide: shortSide, sourceBitsPerSecond: sourceBitsPerSecond) / 1000)k"]
            : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
    }

    /// Whether this ffmpeg can encode with VideoToolbox. Asked once per ffmpeg.
    static func hasHardwareEncoder(ffmpegDirectory: URL) -> Bool {
        let path = ffmpegDirectory.appending(path: "ffmpeg").path
        if let known = cache.withLock({ $0[path] }) { return known }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var found = false
        if (try? process.run()) != nil {
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            found = String(decoding: output, as: UTF8.self).contains("h264_videotoolbox")
        }
        cache.withLock { $0[path] = found }
        return found
    }

    private static let cache = Mutex<[String: Bool]>([:])

    /// The file's length in seconds, from ffprobe; nil when it can't tell.
    static func duration(of file: URL, ffprobe: URL, tools: MediaToolPaths) async -> Double? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = ffprobe
            process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1",
                                 file.path]
            process.environment = MediaCommand.environment(tools: tools)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let seconds = Double(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        }.value
    }
}

/// Converting a VP9 or AV1 download to an H.264 MP4 with ffmpeg, run by Anchor after yt-dlp so it can show progress.
struct MediaConversion: Equatable, Sendable {
    /// The video's shorter side in pixels.
    var shortSide: Int
    /// Whether ffmpeg has the VideoToolbox encoder.
    var hardware: Bool
    /// The video's length in seconds, for the percentage and the source bitrate; nil shows the conversion without one.
    var duration: Double?

    static let outputName = "converted.mp4"

    /// `sourceBytes`: the downloaded file's size, which with the duration gives the source bitrate.
    func arguments(input: URL, output: URL, sourceBytes: Int64? = nil) -> [String] {
        let source = sourceBytes.flatMap { bytes in duration.flatMap { $0 > 0 ? Double(bytes) * 8 / $0 : nil } }
        return ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", input.path,
                "-map", "0:v:0", "-map", "0:a:0?"]
            + MediaEncoder.arguments(shortSide: shortSide, hardware: hardware, sourceBitsPerSecond: source)
            + ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
               "-progress", "pipe:1", "-nostats", output.path]
    }
}

/// Reads ffmpeg's `-progress` output: blocks of `key=value` lines, each ending with `progress=continue` or `end`.
struct MediaConversionProgress: Sendable {
    let duration: Double?
    private var seconds: Double = 0
    private var speed: Double?

    init(duration: Double?) { self.duration = duration }

    /// The fraction done and seconds left, at the end of each block; nil for other lines.
    mutating func feed(_ line: String) -> (fraction: Double?, eta: Double?)? {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "out_time_us", "out_time_ms":
            // Both are microseconds (out_time_ms is misnamed in ffmpeg).
            if let value = Double(parts[1]), value >= 0 { seconds = value / 1_000_000 }
        case "speed":
            speed = Double(parts[1].replacingOccurrences(of: "x", with: "")).flatMap { $0 > 0 ? $0 : nil }
        case "progress":
            guard let duration, duration > 0 else { return (nil, nil) }
            let fraction = parts[1] == "end" ? 1 : min(1, seconds / duration)
            let eta = speed.map { max(0, duration - seconds) / $0 }
            return (fraction, eta)
        default:
            break
        }
        return nil
    }
}

/// What a media download is doing after the streams have arrived. Live only.
enum MediaPhase: Hashable, Sendable {
    /// Joining the separate video and audio streams.
    case merging
    case converting(fraction: Double?, eta: Double?)
    /// Any other yt-dlp step (extracting audio, fixing up).
    case processing

    /// Short enough for the row's size column.
    var label: String {
        switch self {
        case .merging: "Merging…"
        case .converting: "Converting to MP4…"
        case .processing: "Processing…"
        }
    }

    /// The longer explanation, for the details panel and the row's tooltip.
    var detail: String {
        switch self {
        case .merging: "Joining the video and audio into one file"
        case .converting(let fraction, let eta):
            ["Converting to MP4 so it plays in QuickTime", fraction.map { "\(Int($0 * 100))%" },
             eta.map { "\(Format.duration($0)) left" }].compactMap { $0 }.joined(separator: " · ")
        case .processing: "Finishing up"
        }
    }
}

/// What yt-dlp said about the video, kept with the download.
struct MediaInfo: Codable, Hashable, Sendable {
    var title: String
    var extractor: String?
    var thumbnail: URL?
    var duration: Double?
}

/// The executables a yt-dlp run uses.
struct MediaToolPaths: Equatable, Sendable {
    var ytdlp: URL
    /// Folder holding ffmpeg and ffprobe.
    var ffmpegDirectory: URL
    /// deno, node or bun.
    var jsRuntime: String
    var jsRuntimePath: URL
    /// Anchor's Tools folder, the only extra entry on PATH.
    var toolsDirectory: URL
}

/// Builds yt-dlp command lines. The user's file name is never part of them: yt-dlp writes `media.<ext>` into a
/// per-download working folder and Anchor renames the result.
enum MediaCommand {
    static let progressPrefix = "ANCHOR "
    static let postprocessPrefix = "ANCHORPP "
    static let progressTemplate = "download:ANCHOR %(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"
    static let postprocessTemplate = "postprocess:ANCHORPP %(progress.postprocessor)s|%(progress.status)s"
    static let outputStem = "media"

    /// Ignore user config and plugins; use only the chosen JavaScript runtime and the solver scripts yt-dlp ships with.
    static func isolationArguments(tools: MediaToolPaths) -> [String] {
        ["--ignore-config", "--no-plugin-dirs",
         "--no-js-runtimes", "--js-runtimes", "\(tools.jsRuntime):\(tools.jsRuntimePath.path)",
         "--no-remote-components"]
    }

    /// The stream order: highest resolution first, then H.264 (QuickTime plays it on every Mac, unlike VP9 and
    /// AV1), then MP4 and M4A.
    static let formatSort = "res,vcodec:h264,ext:mp4:m4a"

    /// `convert`: the video will be converted to H.264 afterwards (by Anchor, see `MediaConversion`), so merge into
    /// MKV, which holds any codec, instead of an MP4 that QuickTime can't play anyway.
    static func qualityArguments(_ quality: MediaQuality, convert: Bool = false) -> [String] {
        if quality.isAudio { return ["-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a"] }
        // No conversion: the best stream that isn't VP9 or AV1 (unknown codecs count, like Instagram's progressive
        // MP4s), falling back to anything.
        let playable = "[vcodec!^=?vp][vcodec!^=?av01]"
        let format = quality == .playable ? "bv\(playable)+ba/b\(playable)/bv*+ba/b"
            : quality.maxHeight.map { "bv*[height<=\($0)]+ba/b[height<=\($0)]" } ?? "bv*+ba/b"
        // Codecs MP4 can't hold fall back to MKV instead of failing.
        return ["-f", format, "-S", formatSort, "--merge-output-format", convert ? "mkv" : "mp4/mkv"]
    }

    /// The download cap in bytes per second: the smaller of the global limit and the item's own; 0 = none.
    static func limit(global: Int64, itemKB: Int?) -> Int64 {
        let item = itemKB.map { Int64($0) * 1000 } ?? 0
        let limits = [global, item].filter { $0 > 0 }
        return limits.min() ?? 0
    }

    static func downloadArguments(url: URL, quality: MediaQuality, convert: Bool = false, workDirectory: URL,
                                  tools: MediaToolPaths, limitBytesPerSecond: Int64, cookies: [String] = []) -> [String] {
        var args = isolationArguments(tools: tools) + cookies
        args += ["--newline", "--no-playlist", "--no-mtime", "--progress",
                 "--progress-template", progressTemplate, "--progress-template", postprocessTemplate,
                 "--ffmpeg-location", tools.ffmpegDirectory.path]
        args += qualityArguments(quality, convert: convert)
        args += ["-P", "temp:\(workDirectory.path)", "-P", "home:\(workDirectory.path)",
                 "-o", "\(outputStem).%(ext)s", "--print", "after_move:filepath"]
        if limitBytesPerSecond > 0 {
            args += ["--limit-rate", "\(limitBytesPerSecond)"]
        } else {
            // Sites that serve video in fragments (HLS/DASH: Twitch, Vimeo, many news sites) download 4 at a time.
            // Not with a speed limit, which yt-dlp applies to each fragment download separately.
            args += ["--concurrent-fragments", "4"]
        }
        // "--" so a link can never be read as an option.
        args += ["--", url.absoluteString]
        return args
    }

    static func probeArguments(url: URL, tools: MediaToolPaths, cookies: [String] = []) -> [String] {
        isolationArguments(tools: tools) + cookies + ["--dump-single-json", "--no-playlist", "--skip-download", "--no-warnings",
                                            "--", url.absoluteString]
    }

    /// A minimal environment: nothing inherited (no YTDLP_*, PYTHON* or proxy variables), PATH limited to the
    /// Tools folder and the system folders.
    static func environment(tools: MediaToolPaths, home: String = NSHomeDirectory(),
                            temp: String = NSTemporaryDirectory()) -> [String: String] {
        ["PATH": "\(tools.toolsDirectory.path):/usr/bin:/bin", "HOME": home, "LANG": "en_US.UTF-8", "TMPDIR": temp]
    }
}

/// One progress report from the download template. Every field is nil when yt-dlp printed NA.
struct MediaProgress: Equatable, Sendable {
    var downloaded: Int64?
    var total: Int64?
    var estimate: Int64?
    var speed: Double?
    var eta: Double?
}

/// The lines Anchor cares about in yt-dlp's output.
enum MediaOutput: Equatable, Sendable {
    case progress(MediaProgress)
    /// Merging or fixing up after the download.
    case processing(MediaPhase)
    case error(String)
    /// The final file, from `--print after_move:filepath`.
    case path(String)
    /// A warning that the site answered 429 Too Many Requests: worth mentioning if the run then fails.
    case rateLimited

    static func parse(_ raw: String) -> MediaOutput? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(MediaCommand.postprocessPrefix) {
            let fields = line.dropFirst(MediaCommand.postprocessPrefix.count).split(separator: "|")
            let name = fields.first.map(String.init) ?? ""
            let status = fields.count > 1 ? String(fields[1]) : ""
            // Moving the finished file isn't worth a "Processing" state.
            guard status == "started", name != "MoveFiles" else { return nil }
            return .processing(name == "Merger" ? .merging : .processing)
        }
        if line.hasPrefix(MediaCommand.progressPrefix.trimmingCharacters(in: .whitespaces) + " ") {
            let fields = line.dropFirst(MediaCommand.progressPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6 else { return nil }
            func number(_ text: String) -> Double? {
                guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
                return value
            }
            func bytes(_ text: String) -> Int64? { number(text).map { Int64($0) } }
            return .progress(MediaProgress(downloaded: bytes(fields[1]), total: bytes(fields[2]), estimate: bytes(fields[3]),
                                           speed: number(fields[4]), eta: number(fields[5])))
        }
        if line.hasPrefix("ERROR:") { return .error(MediaErrors.message(from: line)) }
        if line.hasPrefix("WARNING:"), line.contains("HTTP Error 429") { return .rateLimited }
        if line.hasPrefix("/") { return .path(line) }
        return nil
    }
}

/// A browser cookie as the extension sends it (from chrome.cookies).
struct BrowserCookie: Codable, Hashable, Sendable {
    var domain: String
    var path: String
    var secure: Bool
    /// Sent only to `domain` itself, not its subdomains.
    var hostOnly: Bool
    /// Seconds since 1970; nil for a session cookie.
    var expires: Double?
    var name: String
    var value: String
}

/// Where yt-dlp gets cookies from, so sites like YouTube see a signed-in browser instead of asking whether
/// it's a bot: a browser's own cookie store (the user chose it), the cookies the extension sent with the link,
/// or none.
enum MediaCookies: Equatable, Sendable {
    case none
    case browser(String)
    case jar([BrowserCookie])

    static let fileName = "cookies.txt"

    /// The yt-dlp names of the browsers it can read cookies from, with their apps' bundle IDs.
    static let browsers: [(name: String, title: String, bundleID: String)] = [
        ("brave", "Brave", "com.brave.Browser"), ("chrome", "Chrome", "com.google.Chrome"),
        ("edge", "Edge", "com.microsoft.edgemac"), ("firefox", "Firefox", "org.mozilla.firefox"),
        ("safari", "Safari", "com.apple.Safari"), ("vivaldi", "Vivaldi", "com.vivaldi.Vivaldi"),
        ("opera", "Opera", "com.operasoftware.Opera"), ("chromium", "Chromium", "org.chromium.Chromium"),
    ]

    static func title(ofBrowser name: String) -> String { browsers.first { $0.name == name }?.title ?? name }

    /// A browser the user picked wins (it has the full, current cookie store), then the extension's cookies.
    static func choose(browser: String, jar: [BrowserCookie]?) -> MediaCookies {
        if browsers.contains(where: { $0.name == browser }) { return .browser(browser) }
        if let jar, !jar.isEmpty { return .jar(jar) }
        return .none
    }

    /// yt-dlp's arguments. A jar is written to `directory/cookies.txt`, readable only by this user; it goes away
    /// with the folder.
    func arguments(writingTo directory: URL) -> [String] {
        switch self {
        case .none:
            return []
        case .browser(let name):
            return ["--cookies-from-browser", name]
        case .jar(let cookies):
            let file = directory.appending(path: Self.fileName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(Self.netscape(cookies).utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                return []
            }
            return ["--cookies", file.path]
        }
    }

    /// The Netscape cookies.txt format yt-dlp reads.
    static func netscape(_ cookies: [BrowserCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File"]
        for cookie in cookies where !cookie.name.isEmpty && !cookie.domain.isEmpty {
            // A tab or line break inside a field would corrupt the file.
            let fields = cookie.domain + cookie.path + cookie.name + cookie.value
            guard !fields.contains(where: { $0 == "\t" || $0.isNewline }) else { continue }
            let bare = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let domain = cookie.hostOnly ? bare : "." + bare
            lines.append([domain, cookie.hostOnly ? "FALSE" : "TRUE", cookie.path.isEmpty ? "/" : cookie.path,
                          cookie.secure ? "TRUE" : "FALSE", String(Int64(cookie.expires ?? 0)), cookie.name, cookie.value]
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// For an older extension that only sent a Cookie header: each cookie for the site's domain and its
    /// subdomains (www.youtube.com → .youtube.com).
    static func jar(fromHeader header: String, url: URL) -> [BrowserCookie] {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return [] }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return header.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return BrowserCookie(domain: "." + host, path: "/", secure: true, hostOnly: false, expires: nil,
                                 name: parts[0], value: parts[1])
        }
    }
}

/// What kind of failure yt-dlp reported, for a plain explanation and the right next step.
enum MediaFailure: Equatable, Sendable {
    /// "Sign in to confirm you're not a bot": signed-in cookies usually fix it.
    case botCheck
    /// Private, members-only or age-restricted: needs a signed-in browser.
    case signIn
    case region
    case unavailable
    case network
    case other

    /// Cookies from a signed-in browser can fix it.
    var wantsCookies: Bool { self == .botCheck || self == .signIn }
    /// Often temporary: worth one automatic retry.
    var retryable: Bool { self == .botCheck || self == .network }
}

enum MediaErrors {
    /// Added to a failure when yt-dlp saw a 429 before it.
    static let rateLimitNote = "(The site answered 429 Too Many Requests.)"

    static func kind(of message: String) -> MediaFailure {
        let text = message.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("not a bot") { return .botCheck }
        if has("private video", "this video is private", "members-only", "members only", "confirm your age",
               "age-restricted", "login required", "log in", "requires authentication", "sign in") { return .signIn }
        if has("available in your country", "geo restrict", "geo-restrict", "blocked it in your country") { return .region }
        if has("video unavailable", "this video is unavailable", "has been removed", "no longer available",
               "does not exist", "http error 404") { return .unavailable }
        if has("timed out", "connection reset", "network is unreachable", "unable to download webpage",
               "name resolution", "connection refused", "connection aborted", "remote end closed") { return .network }
        return .other
    }

    /// One plain sentence for the user; yt-dlp's own text is kept separately as details.
    static func friendly(_ message: String) -> String {
        switch kind(of: message) {
        case .botCheck:
            message.contains(rateLimitNote)
                ? "The site is limiting requests from your network and wants to confirm you're not a bot. Using your browser's cookies fixes this, or try again later."
                : "The site wants to confirm you're not a bot. Using your browser's cookies usually fixes this."
        case .signIn: "This video needs you to be signed in (it's private, for members, or age-restricted)."
        case .region: "This video isn't available in your country."
        case .unavailable: "This video is unavailable or was removed."
        case .network: "The connection dropped while downloading."
        case .other: message
        }
    }

    /// `ERROR: [youtube] abc: This video is unavailable` becomes `This video is unavailable`.
    static func message(from line: String) -> String {
        var text = line.hasPrefix("ERROR:") ? String(line.dropFirst(6)) : line
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            // Drop the video id that follows the extractor name.
            if let colon = text.range(of: ": "), !text[..<colon.lowerBound].contains(" ") {
                text = String(text[colon.upperBound...])
            }
        }
        return text.isEmpty ? "yt-dlp stopped with an error" : text
    }
}

/// Turns per-stream progress into one running total: yt-dlp reports the video and audio streams separately,
/// each counting from zero.
struct MediaProgressTracker: Sendable {
    private var base: Int64 = 0
    private var lastDownloaded: Int64 = 0
    private var lastTotal: Int64?

    mutating func update(_ progress: MediaProgress) -> (received: Int64, total: Int64?) {
        var downloaded = progress.downloaded ?? lastDownloaded
        if downloaded < lastDownloaded {
            if downloaded < lastDownloaded / 2 {
                // The next stream (audio after video) starts over near zero.
                base += lastTotal ?? lastDownloaded
            } else {
                // Concurrent fragments can report a slightly lower count; it isn't a new stream.
                downloaded = lastDownloaded
            }
        }
        lastDownloaded = downloaded
        if let total = progress.total ?? progress.estimate { lastTotal = total }
        return (base + downloaded, (progress.total ?? progress.estimate).map { base + $0 })
    }
}

enum MediaNaming {
    static let mediaExtensions: Set<String> = ["mp4", "m4a", "mkv", "webm", "mov", "mp3", "opus"]

    /// The name without a media extension the user may have typed, so "Clip.mp4" doesn't become "Clip.mp4.mp4".
    static func stem(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard mediaExtensions.contains(ext) else { return name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }
}
