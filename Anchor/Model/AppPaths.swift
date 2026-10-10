import Foundation

enum AppPaths {
    static var support: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Drift", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var torrents: URL {
        let url = support.appending(path: "Torrents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var library: URL { support.appending(path: "downloads.json") }
    /// Copy of the list as it was last loaded successfully.
    static var libraryBackup: URL { support.appending(path: "downloads.backup.json") }
}
