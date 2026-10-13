import Foundation

/// The parts of yt-dlp's `--dump-single-json` output the New Download window shows.
struct MediaProbeResult: Decodable, Equatable, Sendable {
    struct Format: Decodable, Equatable, Sendable {
        var ext: String?
        var vcodec: String?
        var acodec: String?
        var height: Int?
        var width: Int?
        var filesize: Int64?
        var filesizeApprox: Int64?
        var abr: Double?

        enum CodingKeys: String, CodingKey {
            case ext, vcodec, acodec, height, width, filesize, abr
            case filesizeApprox = "filesize_approx"
        }

        var size: Int64? { filesize ?? filesizeApprox }
        // An unknown codec (Instagram's progressive MP4s) is assumed present, as yt-dlp does; "none" means absent.
        var hasVideo: Bool { (vcodec ?? "unknown") != "none" }
        var hasAudio: Bool { (acodec ?? "unknown") != "none" }
        var isH264: Bool { vcodec.map { $0.hasPrefix("avc") || $0.hasPrefix("h264") } ?? false }
        /// H.264 or HEVC tagged hvc1: what QuickTime plays on every Apple silicon Mac. Unknown codecs count as playable.
        var playsInQuickTime: Bool {
            guard let vcodec, vcodec != "none" else { return true }
            return isH264 || vcodec.hasPrefix("hvc1")
        }
    }

    var title: String?
    var extractor: String?
    var extractorKey: String?
    var duration: Double?
    var uploader: String?
    var thumbnail: URL?
    var filesizeApprox: Int64?
    var type: String?
    var formats: [Format]?

    enum CodingKeys: String, CodingKey {
        case title, extractor, duration, uploader, thumbnail, formats
        case extractorKey = "extractor_key"
        case filesizeApprox = "filesize_approx"
        case type = "_type"
    }

    static func decode(_ data: Data) throws -> MediaProbeResult {
        try JSONDecoder().decode(MediaProbeResult.self, from: data)
    }

    var isGeneric: Bool { MediaLinkDetector.isGeneric(extractor: extractor, key: extractorKey) }
    var isPlaylist: Bool { type == "playlist" || type == "multi_video" }

    var info: MediaInfo {
        MediaInfo(title: title ?? "Video", extractor: extractor, thumbnail: thumbnail, duration: duration)
    }

    /// The qualities worth offering: Best, each standard height the video actually has, and Audio only.
    /// Portrait videos only get Best and Audio only, since a height cap means something different for them.
    var availableQualities: [MediaQuality] {
        let video = (formats ?? []).filter(\.hasVideo)
        let heights = video.compactMap(\.height)
        let portrait = video.contains { ($0.width ?? 0) > 0 && ($0.height ?? 0) > ($0.width ?? 0) }
        var options: [MediaQuality] = [.best]
        if !portrait, let tallest = heights.max() {
            let levels = MediaQuality.allCases.filter { $0.maxHeight != nil }
            // A level is offered when some stream is at least that tall, so 1080p shows for a 1088-pixel stream,
            // but only up to the tallest stream (no 4K option for a 1080p video).
            options += levels.filter { level in
                guard let cap = level.maxHeight else { return false }
                return cap <= tallest && heights.contains { $0 >= cap && levelFor($0) == cap }
            }
        }
        // Best needs converting: offer the best file that doesn't, unless a height option already is that file.
        if conversionHeight(.best) != nil, let playable = bestPlayable?.format,
           !options.contains(where: { $0.maxHeight != nil && $0.maxHeight == playable.height.map(levelFor) }) {
            options.insert(.playable, at: 1)
        }
        if (formats ?? []).contains(where: \.hasAudio) || formats == nil { options.append(.audio) }
        return options
    }

    /// The choice the New Download window starts on: Best, unless Best needs converting; then the best option that
    /// doesn't.
    var defaultQuality: MediaQuality {
        let options = availableQualities
        guard conversionHeight(.best) != nil else { return .best }
        return options.first { !$0.isAudio && $0 != .best && conversionHeight($0) == nil } ?? .best
    }

    /// yt-dlp's order within a selector (`MediaCommand.formatSort`): tallest, then H.264, then MP4.
    private static func ranksBelow(_ a: Format, _ b: Format) -> Bool {
        if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
        if a.isH264 != b.isH264 { return !a.isH264 }
        let (ma, mb) = (a.ext == "mp4", b.ext == "mp4")
        if ma != mb { return !ma }
        return (a.size ?? 0) < (b.size ?? 0)
    }

    /// What No conversion picks (see `MediaCommand.qualityArguments`): the best video-only stream that plays without
    /// converting, else the best such file with audio built in (Instagram's progressive MP4, for example).
    /// nil when every stream is VP9 or AV1.
    private var bestPlayable: (format: Format, hasAudio: Bool)? {
        let playable = (formats ?? []).filter { $0.hasVideo && $0.playsInQuickTime }
        if let video = playable.filter({ !$0.hasAudio }).max(by: Self.ranksBelow) { return (video, false) }
        if let combined = playable.filter(\.hasAudio).max(by: Self.ranksBelow) { return (combined, true) }
        return nil
    }

    /// The video stream yt-dlp will pick for a quality: for No conversion, the best one that plays as is; otherwise
    /// the tallest within the cap, then H.264, then MP4.
    func chosenVideo(_ quality: MediaQuality) -> Format? {
        guard !quality.isAudio else { return nil }
        if quality == .playable { return bestPlayable?.format }
        let candidates = (formats ?? []).filter { format in
            format.hasVideo && quality.maxHeight.map { (format.height ?? 0) <= $0 } ?? true
        }
        return candidates.max { a, b in
            if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
            if a.isH264 != b.isH264 { return !a.isH264 }
            return (a.ext == "mp4") != (b.ext == "mp4") && b.ext == "mp4"
        }
    }

    /// When the quality only exists in a codec QuickTime can't play (VP9, AV1): the video's shorter side, which sets
    /// the conversion's bitrate limit. nil when no conversion is needed.
    func conversionHeight(_ quality: MediaQuality) -> Int? {
        guard let video = chosenVideo(quality), !video.playsInQuickTime else { return nil }
        let sides = [video.width, video.height].compactMap { $0 }.filter { $0 > 0 }
        return sides.min() ?? quality.maxHeight ?? 1080
    }

    /// The standard level a stream height belongs to: the largest level not taller than it.
    private func levelFor(_ height: Int) -> Int {
        MediaQuality.allCases.compactMap(\.maxHeight).filter { $0 <= height }.max() ?? 0
    }

    /// A rough size for a quality, following the same preferences as the yt-dlp arguments
    /// (highest resolution within the cap, MP4 first, M4A audio first). nil when the site gives no sizes.
    func estimatedSize(_ quality: MediaQuality) -> Int64? {
        let formats = formats ?? []
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo }
            .max { a, b in
                let (ma, mb) = (a.ext == "m4a", b.ext == "m4a")
                if ma != mb { return !ma }
                return (a.abr ?? 0) < (b.abr ?? 0)
            }
        if quality.isAudio { return audio?.size ?? formats.filter(\.hasAudio).compactMap(\.size).min() }

        if quality == .playable {
            guard let playable = bestPlayable, let size = playable.format.size else { return nil }
            return playable.hasAudio ? size : size + (audio?.size ?? 0)
        }
        func fits(_ format: Format) -> Bool { quality.maxHeight.map { (format.height ?? 0) <= $0 } ?? true }
        if let video = formats.filter({ $0.hasVideo && !$0.hasAudio && fits($0) }).max(by: Self.ranksBelow), let size = video.size {
            return size + (audio?.size ?? 0)
        }
        if let combined = formats.filter({ $0.hasVideo && $0.hasAudio && fits($0) }).max(by: Self.ranksBelow), let size = combined.size {
            return size
        }
        return quality == .best ? filesizeApprox : nil
    }
}

/// Asks yt-dlp whether a link is a video. One probe at a time (a new one stops the previous), 20 s timeout,
/// stopped when the calling task is cancelled.
@MainActor
final class MediaProber {
    static let shared = MediaProber()
    static let timeout: TimeInterval = 20

    enum Outcome: Equatable {
        case media(MediaProbeResult)
        /// Generic page, playlist, error or timeout: treat the link as an ordinary download.
        case notMedia(String?)
    }

    private var current: MediaProcess?

    func probe(_ url: URL, tools: MediaToolPaths) async -> Outcome {
        if let current {
            self.current = nil
            await current.terminate(grace: 1)
        }
        guard !Task.isCancelled else { return .notMedia(nil) }
        let collector = OutputCollector()
        let finished = AsyncStream<Int32>.makeStream()
        let process = MediaProcess(executable: tools.ytdlp, arguments: MediaCommand.probeArguments(url: url, tools: tools),
                                   environment: MediaCommand.environment(tools: tools),
                                   onLine: { collector.add($0) },
                                   onFinish: { status in
                                       finished.continuation.yield(status)
                                       finished.continuation.finish()
                                   })
        do {
            try process.start()
        } catch {
            return .notMedia(error.localizedDescription)
        }
        current = process
        let timer = Task {
            try? await Task.sleep(for: .seconds(Self.timeout))
            guard !Task.isCancelled else { return }
            collector.timedOut = true
            await process.terminate(grace: 1)
        }
        let status = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await value in finished.stream { status = value }
            return status
        } onCancel: {
            Task { await process.terminate(grace: 1) }
        }
        timer.cancel()
        if current === process { current = nil }

        guard !Task.isCancelled else { return .notMedia(nil) }
        if collector.timedOut { return .notMedia("Timed out") }
        guard status == 0, let json = collector.json, let result = try? MediaProbeResult.decode(json) else {
            return .notMedia(collector.error)
        }
        if result.isGeneric || result.isPlaylist { return .notMedia(nil) }
        return .media(result)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var jsonLine: String?
    private var lastError: String?
    private var expired = false

    var timedOut: Bool {
        get { lock.withLock { expired } }
        set { lock.withLock { expired = newValue } }
    }

    func add(_ line: String) {
        lock.withLock {
            if line.hasPrefix("{") {
                jsonLine = line
            } else if line.hasPrefix("ERROR:") {
                lastError = MediaErrors.message(from: line)
            }
        }
    }

    var json: Data? { lock.withLock { jsonLine.map { Data($0.utf8) } } }
    var error: String? { lock.withLock { lastError } }
}
