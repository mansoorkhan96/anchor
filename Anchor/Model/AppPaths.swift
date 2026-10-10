import Foundation

enum AppPaths {
    static var support: URL {
        _ = migrated
        let url = URL.applicationSupportDirectory.appending(path: "Anchor", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let migrated: Void = migrateLegacySupport(
        from: URL.applicationSupportDirectory.appending(path: "Drift", directoryHint: .isDirectory),
        to: URL.applicationSupportDirectory.appending(path: "Anchor", directoryHint: .isDirectory))

    static func migrateLegacySupport(from legacy: URL, to current: URL) {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard !fm.fileExists(atPath: current.path),
              fm.fileExists(atPath: legacy.path, isDirectory: &isFolder), isFolder.boolValue,
              (try? fm.destinationOfSymbolicLink(atPath: legacy.path)) == nil else { return }
        do {
            try fm.moveItem(at: legacy, to: current)
            try? fm.createSymbolicLink(at: legacy, withDestinationURL: current)
        } catch {
            NSLog("Anchor: could not move \(legacy.path) to \(current.path): \(error)")
        }
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
