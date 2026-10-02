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

/// User preferences, persisted to UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: "downloadFolder") } }
    var maxConcurrent: Int { didSet { defaults.set(maxConcurrent, forKey: "maxConcurrent") } }
    var connections: Int { didSet { defaults.set(connections, forKey: "connections") } }
    /// KB/s, 0 = unlimited.
    var speedLimitKB: Int { didSet { defaults.set(speedLimitKB, forKey: "speedLimitKB") } }
    var categorySubfolders: Bool { didSet { defaults.set(categorySubfolders, forKey: "categorySubfolders") } }
    var clipboardMonitoring: Bool { didSet { defaults.set(clipboardMonitoring, forKey: "clipboardMonitoring") } }
    var browserIntegration: Bool { didSet { defaults.set(browserIntegration, forKey: "browserIntegration") } }
    var confirmBrowserDownloads: Bool { didSet { defaults.set(confirmBrowserDownloads, forKey: "confirmBrowserDownloads") } }
    var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") } }

    private init() {
        defaults.register(defaults: [
            "maxConcurrent": 3, "connections": 16, "speedLimitKB": 0, "categorySubfolders": false,
            "clipboardMonitoring": true, "browserIntegration": true, "confirmBrowserDownloads": true,
            "notifications": true, "sortOrder": SortOrder.newest.rawValue,
        ])
        downloadFolder = defaults.string(forKey: "downloadFolder").map { URL(filePath: $0) } ?? URL.downloadsDirectory
        maxConcurrent = defaults.integer(forKey: "maxConcurrent")
        connections = defaults.integer(forKey: "connections")
        speedLimitKB = defaults.integer(forKey: "speedLimitKB")
        categorySubfolders = defaults.bool(forKey: "categorySubfolders")
        clipboardMonitoring = defaults.bool(forKey: "clipboardMonitoring")
        browserIntegration = defaults.bool(forKey: "browserIntegration")
        confirmBrowserDownloads = defaults.bool(forKey: "confirmBrowserDownloads")
        notifications = defaults.bool(forKey: "notifications")
        sortOrder = SortOrder(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .newest
    }

    func folder(for category: FileCategory) -> URL {
        categorySubfolders ? downloadFolder.appending(path: category.title, directoryHint: .isDirectory) : downloadFolder
    }
}
