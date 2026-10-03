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

    /// Extra request headers forwarded from the browser (cookies, referer, user agent).
    var headers: [String: String] = [:]

    // Torrent fields
    var torrentGID: String?
    var torrentFile: URL?
    var peers: Int = 0
    var seeders: Int = 0

    // Live, not persisted
    var speed: Double = 0
    var connections: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, kind, url, fileName, directory, category, totalBytes, receivedBytes, segments
        case supportsRanges, validator, state, createdAt, completedAt, openWhenDone, headers, nameFromServer, overwrite
        case torrentGID, torrentFile
    }

    init(url: URL, fileName: String, directory: URL, category: FileCategory, kind: DownloadKind = .http) {
        self.url = url
        self.fileName = fileName
        self.directory = directory
        self.category = category
        self.kind = kind
    }

    var destination: URL { directory.appending(path: fileName) }
    var partialFile: URL { directory.appending(path: fileName + ".drift-part") }

    var progress: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var eta: TimeInterval? {
        guard let totalBytes, speed > 1, state == .downloading else { return nil }
        return Double(totalBytes - receivedBytes) / speed
    }
}
