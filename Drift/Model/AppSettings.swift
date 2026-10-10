import Foundation
import Observation

enum SortOrder: String, CaseIterable, Identifiable {
    case newest, oldest, largest, smallest, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "Date Added, Newest First"
        case .oldest: "Date Added, Oldest First"
        case .largest: "Size, Largest First"
        case .smallest: "Size, Smallest First"
        case .name: "Name"
        }
    }
}

/// What to do when a download's file name already exists in the folder.
enum ExistingFileAction: String, CaseIterable, Identifiable {
    case ask, rename, overwrite

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask"
        case .rename: "Rename"
        case .overwrite: "Overwrite"
        }
    }
}

/// Order of the recent-downloads list in the menu bar.
enum MenuBarOrder: String, CaseIterable, Identifiable {
    case newest, unfinishedFirst

    var id: String { rawValue }
    var title: String { self == .newest ? "Newest" : "Unfinished first" }
}

/// User preferences, persisted to UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: "downloadFolder") } }
    var maxConcurrent: Int { didSet { defaults.set(maxConcurrent, forKey: "maxConcurrent") } }
    var connections: Int { didSet { defaults.set(connections, forKey: "connections") } }
    /// Whether downloads are throttled at all.
    var speedLimitEnabled: Bool { didSet { defaults.set(speedLimitEnabled, forKey: "speedLimitEnabled") } }
    /// The chosen limit in KB/s (1 KB = 1000 bytes), kept while the limit is switched off.
    var speedLimitKB: Int { didSet { defaults.set(speedLimitKB, forKey: "speedLimitKB") } }
    var categorySubfolders: Bool { didSet { defaults.set(categorySubfolders, forKey: "categorySubfolders") } }
    var clipboardMonitoring: Bool { didSet { defaults.set(clipboardMonitoring, forKey: "clipboardMonitoring") } }
    var browserIntegration: Bool { didSet { defaults.set(browserIntegration, forKey: "browserIntegration") } }
    var confirmBrowserDownloads: Bool { didSet { defaults.set(confirmBrowserDownloads, forKey: "confirmBrowserDownloads") } }
    var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") } }
    var menuBarOrder: MenuBarOrder { didSet { defaults.set(menuBarOrder.rawValue, forKey: "menuBarOrder") } }
    var menuBarCount: Int { didSet { defaults.set(menuBarCount, forKey: "menuBarCount") } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var showSpeedStrip: Bool { didSet { defaults.set(showSpeedStrip, forKey: "showSpeedStrip") } }
    var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "keepAwake") } }
    var seedTorrents: Bool { didSet { defaults.set(seedTorrents, forKey: "seedTorrents") } }
    var seedRatio: Double { didSet { defaults.set(seedRatio, forKey: "seedRatio") } }
    /// KB/s, 0 = unlimited.
    /// Torrent upload cap in KB/s: 0 is unlimited, -1 stops uploading (aria2 gets a 1 B/s cap, since 0 means unlimited there).
    var uploadLimitKB: Int { didSet { defaults.set(uploadLimitKB, forKey: "uploadLimitKB") } }
    /// One-shot: resets to `.nothing` after it runs.
    var whenDone: WhenDoneAction = .nothing
    var existingFileAction: ExistingFileAction { didSet { defaults.set(existingFileAction.rawValue, forKey: "existingFileAction") } }
    /// Days without recorded use before a file shows up in Cleanup, per category. Missing or 0 means Never.
    var cleanupDays: [FileCategory: Int] {
        didSet {
            Self.storeCleanupDays(cleanupDays, in: defaults)
            DownloadStore.shared.bumpCleanupRevision()
        }
    }
    /// Move dmg installers whose app is installed into the Drift Archive folder.
    var archiveInstallers: Bool {
        didSet {
            defaults.set(archiveInstallers, forKey: "archiveInstallers")
            DownloadStore.shared.bumpCleanupRevision()
        }
    }
    /// The cleanup total when the user last closed the banner; it comes back once the total grows by 500 MB.
    var cleanupBannerDismissedBytes: Int64 { didSet { defaults.set(cleanupBannerDismissedBytes, forKey: "cleanupBannerDismissedBytes") } }
    /// One-shot: the Settings window opens on this page (e.g. "cleanup") next time it appears.
    var requestedSettingsPage: String?

    private init() {
        defaults.register(defaults: [
            "maxConcurrent": 3, "connections": 16, "speedLimitKB": 0, "categorySubfolders": false,
            "clipboardMonitoring": true, "browserIntegration": true, "confirmBrowserDownloads": true,
            "notifications": true, "sortOrder": SortOrder.newest.rawValue,
            "menuBarOrder": MenuBarOrder.unfinishedFirst.rawValue, "menuBarCount": 5,
            "showMenuBarIcon": true, "showSpeedStrip": true, "keepAwake": true, "seedTorrents": false, "seedRatio": 1.0, "uploadLimitKB": 0, "existingFileAction": ExistingFileAction.ask.rawValue,
            "archiveInstallers": true, "cleanupBannerDismissedBytes": 0,
        ])
        downloadFolder = defaults.string(forKey: "downloadFolder").map { URL(filePath: $0) } ?? URL.downloadsDirectory
        maxConcurrent = defaults.integer(forKey: "maxConcurrent")
        connections = defaults.integer(forKey: "connections")
        let savedLimit = defaults.integer(forKey: "speedLimitKB")
        speedLimitEnabled = defaults.object(forKey: "speedLimitEnabled") as? Bool ?? (savedLimit > 0)
        speedLimitKB = savedLimit > 0 ? savedLimit : 2000
        categorySubfolders = defaults.bool(forKey: "categorySubfolders")
        clipboardMonitoring = defaults.bool(forKey: "clipboardMonitoring")
        browserIntegration = defaults.bool(forKey: "browserIntegration")
        confirmBrowserDownloads = defaults.bool(forKey: "confirmBrowserDownloads")
        notifications = defaults.bool(forKey: "notifications")
        sortOrder = SortOrder(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .newest
        menuBarOrder = MenuBarOrder(rawValue: defaults.string(forKey: "menuBarOrder") ?? "") ?? .unfinishedFirst
        menuBarCount = defaults.integer(forKey: "menuBarCount")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        showSpeedStrip = defaults.bool(forKey: "showSpeedStrip")
        keepAwake = defaults.bool(forKey: "keepAwake")
        seedTorrents = defaults.bool(forKey: "seedTorrents")
        seedRatio = defaults.double(forKey: "seedRatio")
        uploadLimitKB = defaults.integer(forKey: "uploadLimitKB")
        existingFileAction = ExistingFileAction(rawValue: defaults.string(forKey: "existingFileAction") ?? "") ?? .ask
        cleanupDays = Self.loadCleanupDays(from: defaults)
        archiveInstallers = defaults.bool(forKey: "archiveInstallers")
        cleanupBannerDismissedBytes = (defaults.object(forKey: "cleanupBannerDismissedBytes") as? NSNumber)?.int64Value ?? 0
    }

    func cleanupDays(for category: FileCategory) -> Int { cleanupDays[category] ?? 0 }

    /// Stored as `[String: Int]` (category raw value to days); unknown keys and non-positive days are dropped.
    nonisolated static func loadCleanupDays(from defaults: UserDefaults) -> [FileCategory: Int] {
        let raw = defaults.dictionary(forKey: "cleanupDays") as? [String: Int] ?? [:]
        var days: [FileCategory: Int] = [:]
        for (key, value) in raw where value > 0 {
            if let category = FileCategory(rawValue: key) { days[category] = value }
        }
        return days
    }

    nonisolated static func storeCleanupDays(_ days: [FileCategory: Int], in defaults: UserDefaults) {
        var raw: [String: Int] = [:]
        for (category, value) in days where value > 0 { raw[category.rawValue] = value }
        defaults.set(raw, forKey: "cleanupDays")
    }

    /// Bytes per second actually applied to downloads; 0 means unlimited.
    var effectiveSpeedLimit: Int64 { speedLimitEnabled ? Int64(speedLimitKB) * 1000 : 0 }

    func folder(for category: FileCategory) -> URL {
        categorySubfolders ? downloadFolder.appending(path: category.title, directoryHint: .isDirectory) : downloadFolder
    }
}
