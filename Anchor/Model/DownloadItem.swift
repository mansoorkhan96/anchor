import Foundation

/// A byte range of a file fetched by one connection. `end` is inclusive.
struct Segment: Codable, Hashable, Sendable {
    var start: Int64
    var end: Int64
    var received: Int64 = 0

    var length: Int64 { end - start + 1 }
    var nextOffset: Int64 { start + received }
    var remaining: Int64 { max(0, length - received) }
    var isComplete: Bool { remaining == 0 }
}

enum DownloadKind: String, Codable, Sendable {
    case http
    case torrent
    /// A video or audio page downloaded with yt-dlp.
    case media
}

enum DownloadState: Codable, Hashable, Sendable {
    case queued
    case connecting
    case downloading
    case paused
    case completed
    case failed(String)

    var isActive: Bool { self == .connecting || self == .downloading }
    var isFinished: Bool { self == .completed }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: DownloadKind = .http
    var url: URL
    var fileName: String
    var directory: URL
    var category: FileCategory
    var totalBytes: Int64?
    var receivedBytes: Int64 = 0
    var segments: [Segment] = []
    var supportsRanges = false
    var validator: String?
    var state: DownloadState = .queued
    var createdAt = Date()
    var completedAt: Date?
    var openWhenDone = false
    /// Set when the name was guessed from the URL; the engine swaps in the server's filename on first probe.
    var nameFromServer: Bool?
    /// The user chose to replace an existing file with this name; it goes to the Trash when the download finishes.
    var overwrite: Bool?
    /// When the download joined the waiting line; it starts after everything queued before it.
    var queuedAt: Date?
    /// Higher priority downloads leave the queue first.
    var priority: Priority?
    /// Torrent contents, with per-file include and priority choices.
    var files: [TorrentFile]?
    /// The file indexes last sent to aria2.
    var appliedSelection: [Int]?
    /// This download's own speed cap in KB/s (on top of the global limit); nil = no cap.
    var speedLimitKB: Int?
    /// Torrent: keeps uploading after finishing, until the seed ratio is reached.
    var seeding: Bool?
    var uploadSpeed: Double = 0
    var uploadedBytes: Int64 = 0

    // Cleanup
    /// The user marked Keep: never suggested in Cleanup, never archived.
    var keep: Bool?
    /// Identity of the finished file, recorded at completion (or adopted later, see `stampIsBaseline`).
    var stamp: FileStamp?
    /// The stamp was adopted after the fact; such items are never archived automatically.
    var stampIsBaseline: Bool?
    /// Last time the file was opened from Anchor.
    var openedAt: Date?
    /// When the archiver moved the file; non-nil means "in the archive".
    var archivedAt: Date?
    /// The directory path the file was archived from, used by Restore.
    var archivedFrom: String?
    /// The file name before archiving, used by Restore.
    var archivedName: String?
    /// Set and saved before an archive or restore move, cleared after.
    var pendingMove: PendingMove?
    /// Cached result of inspecting the installer.
    var installer: InstallerInfo?

    /// Extra request headers forwarded from the browser (cookies, referer, user agent).
    var headers: [String: String] = [:]

    // Media fields (optional, so libraries saved before video downloads still load)
    var mediaQuality: MediaQuality?
    var mediaInfo: MediaInfo?
    /// Set when the chosen quality is only available as VP9 or AV1: the video's shorter side, for the H.264 bitrate.
    var mediaConvertHeight: Int?
    /// The site's cookies the browser extension sent with the link, so yt-dlp downloads as the signed-in user.
    var cookieJar: [BrowserCookie]?
    /// yt-dlp's own words for the last failure; the failed state holds the plain version.
    var mediaError: String?
    /// From a playlist: the best stream QuickTime plays within the quality, never converted (its codecs weren't probed).
    var mediaPlayableOnly: Bool?
    /// Subtitles to embed in the video.
    var mediaSubtitle: MediaSubtitle?

    // Torrent fields
    var torrentGID: String?
    var torrentFile: URL?
    var peers: Int = 0
    var seeders: Int = 0

    // Live, not persisted
    var speed: Double = 0
    var connections: Int = 0
    /// Media: merging, converting or otherwise finishing up after the download; nil while downloading.
    var mediaPhase: MediaPhase?
    /// Media: when the last attempt failed, so a retry that fails again visibly changes something.
    var failedAt: Date?
    var mediaProcessing: Bool { mediaPhase != nil }

    enum CodingKeys: String, CodingKey {
        case id, kind, url, fileName, directory, category, totalBytes, receivedBytes, segments
        case supportsRanges, validator, state, createdAt, completedAt, openWhenDone, headers, nameFromServer, overwrite, queuedAt, priority, files, appliedSelection, speedLimitKB, seeding
        case torrentGID, torrentFile
        case keep, stamp, stampIsBaseline, openedAt, archivedAt, archivedFrom, archivedName, pendingMove, installer
        case mediaQuality, mediaInfo, mediaConvertHeight, cookieJar, mediaError, mediaPlayableOnly, mediaSubtitle
    }

    init(url: URL, fileName: String, directory: URL, category: FileCategory, kind: DownloadKind = .http) {
        self.url = url
        self.fileName = fileName
        self.directory = directory
        self.category = category
        self.kind = kind
    }

    var destination: URL { directory.appending(path: fileName) }
    var partialFile: URL { directory.appending(path: fileName + Self.partialSuffix) }

    static let partialSuffix = ".anchor-part"

    var progress: Double {
        if case .converting(let fraction?, _) = mediaPhase { return fraction }
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var eta: TimeInterval? {
        if case .converting(_, let eta) = mediaPhase { return eta }
        guard let totalBytes, speed > 1, state == .downloading else { return nil }
        return Double(totalBytes - receivedBytes) / speed
    }
}
