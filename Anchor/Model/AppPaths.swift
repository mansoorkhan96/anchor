import Foundation

enum AppPaths {
    static var support: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Anchor", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var torrents: URL {
        let url = support.appending(path: "Torrents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// yt-dlp, ffmpeg, ffprobe, Deno and tools.json for video downloads.
    static var tools: URL {
        let url = support.appending(path: "Tools", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Per-download working folders yt-dlp writes into before the result is moved to the download folder.
    static var mediaWork: URL {
        let url = support.appending(path: "Media Work", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var library: URL { support.appending(path: "downloads.json") }
    /// Copy of the list as it was last loaded successfully.
    static var libraryBackup: URL { support.appending(path: "downloads.backup.json") }
}
