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
    var existingFileAction: ExistingFileAction { didSet { defaults.set(existingFileAction.rawValue, forKey: "existingFileAction") } }

    private init() {
        defaults.register(defaults: [
            "maxConcurrent": 3, "connections": 16, "speedLimitKB": 0, "categorySubfolders": false,
            "clipboardMonitoring": true, "browserIntegration": true, "confirmBrowserDownloads": true,
            "notifications": true, "sortOrder": SortOrder.newest.rawValue,
            "menuBarOrder": MenuBarOrder.unfinishedFirst.rawValue, "menuBarCount": 5,
            "showMenuBarIcon": true, "showSpeedStrip": true, "existingFileAction": ExistingFileAction.ask.rawValue,
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
        existingFileAction = ExistingFileAction(rawValue: defaults.string(forKey: "existingFileAction") ?? "") ?? .ask
    }

    /// Bytes per second actually applied to downloads; 0 means unlimited.
    var effectiveSpeedLimit: Int64 { speedLimitEnabled ? Int64(speedLimitKB) * 1000 : 0 }

    func folder(for category: FileCategory) -> URL {
        categorySubfolders ? downloadFolder.appending(path: category.title, directoryHint: .isDirectory) : downloadFolder
    }
}
