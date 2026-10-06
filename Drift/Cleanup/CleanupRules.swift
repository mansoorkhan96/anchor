import Foundation

/// Why a file shows up in Cleanup, shown under its row.
struct CleanupReason: Hashable, Sendable {
    /// Whole days since the last recorded activity.
    var days: Int
    var text: String
}

/// What the archive pass read from disk just before deciding about one installer.
struct ArchiveFacts: Sendable {
    /// The file's current stamp, nil if there is no regular file at the destination.
    var current: FileStamp?
    /// Volume UUID of the archive folder.
    var archiveVolume: String?
    /// Versions of installed copies of the installer's app, in /Applications or ~/Applications.
    var installedVersions: [String]
    /// The image is attached right now.
    var mounted: Bool
    /// Another item points at the same path.
    var sharedPath: Bool
}

/// Pure cleanup decisions. Nothing here touches the disk; callers pass in what they read.
enum CleanupRules {
    static let day: TimeInterval = 86_400

    /// Why `item` is a cleanup candidate, or nil if it is not one.
    /// `current` is the stamp read now at the destination (nil if it is missing or not a regular file),
    /// `lastUsed` is Spotlight's last-used date if known, `days` the setting for the item's category.
    static func reason(for item: DownloadItem, now: Date, days: Int, current: FileStamp?,
                       lastUsed: Date?, sharedPath: Bool) -> CleanupReason? {
        guard item.state == .completed,
              // Torrents qualify only when their payload is a single regular file (a stamp exists).
              item.kind == .http || item.kind == .torrent,
              item.seeding != true, item.keep != true, item.pendingMove == nil,
              let current, let stamp = item.stamp, current == stamp,
              !sharedPath, days > 0 else { return nil }
        let dates = [lastUsed, current.modified, item.openedAt, item.archivedAt, item.completedAt ?? item.createdAt]
        let lastActivity = dates.compactMap { $0 }.max() ?? item.createdAt
        let elapsed = now.timeIntervalSince(lastActivity)
        guard elapsed >= Double(days) * day else { return nil }
        let idle = Int(elapsed / day)
        return CleanupReason(days: idle, text: "No recorded use in \(idle) day\(idle == 1 ? "" : "s")")
    }

    /// The archive conditions that need no disk access.
    static func archiveCandidate(_ item: DownloadItem, now: Date, enabled: Bool) -> Bool {
        guard enabled, item.kind == .http, item.category == .apps,
              (item.fileName as NSString).pathExtension.lowercased() == "dmg",
              item.state == .completed, item.keep != true, item.archivedAt == nil, item.pendingMove == nil,
              item.stamp != nil, item.stampIsBaseline != true,
              let completed = item.completedAt, now.timeIntervalSince(completed) >= day else { return false }
        return true
    }

    /// Whether the archive pass may move this installer, given what it just read from disk.
    static func shouldArchive(_ item: DownloadItem, now: Date, enabled: Bool, facts: ArchiveFacts) -> Bool {
        guard archiveCandidate(item, now: now, enabled: enabled),
              let current = facts.current, current == item.stamp,
              let installer = item.installer, !installer.failed, installer.stamp == current,
              installer.bundleID != nil, let version = installer.version,
              !facts.sharedPath, !facts.mounted,
              let archiveVolume = facts.archiveVolume, archiveVolume == current.volume else { return false }
        return isInstalled(version: version, installed: facts.installedVersions)
    }

    /// True if any installed copy has the same or a newer version.
    static func isInstalled(version: String, installed: [String]) -> Bool {
        installed.contains { $0.compare(version, options: .numeric) != .orderedAscending }
    }

    /// Drops ids whose item is mid-move (locked), and ids not in the list.
    static func unlocked(_ ids: Set<UUID>, in items: [DownloadItem]) -> Set<UUID> {
        Set(items.filter { ids.contains($0.id) && $0.pendingMove == nil }.map(\.id))
    }

    /// A finished download whose folder is still there but whose file is gone. A missing folder (say an
    /// unmounted drive) is not flagged.
    static func isMissing(_ item: DownloadItem, directoryExists: Bool, fileExists: Bool) -> Bool {
        item.state == .completed && item.pendingMove == nil && directoryExists && !fileExists
    }

    /// Destination paths that more than one item points at; they are never suggested or archived.
    static func sharedPaths(_ items: [DownloadItem]) -> Set<String> {
        var seen: Set<String> = [], shared: Set<String> = []
        for item in items {
            let path = item.destination.standardizedFileURL.path
            if !seen.insert(path).inserted { shared.insert(path) }
        }
        return shared
    }

    enum Reconciliation: Equatable, Sendable { case completed, notMoved, unknown }

    /// After a crash: did the recorded move happen? The file at `to` wins; the entry is never pointed at
    /// a file whose stamp does not match.
    static func reconcile(_ move: PendingMove, stampAt: (String) -> FileStamp?) -> Reconciliation {
        if stampAt(move.to) == move.stamp { return .completed }
        if stampAt(move.from) == move.stamp { return .notMoved }
        return .unknown
    }

    /// Points the item at the moved file and records (archive) or clears (restore) where it came from.
    static func applyMove(_ move: PendingMove, to item: inout DownloadItem, now: Date) {
        let from = URL(filePath: move.from), to = URL(filePath: move.to)
        item.directory = to.deletingLastPathComponent()
        item.fileName = to.lastPathComponent
        switch move.kind {
        case .archive:
            item.archivedAt = now
            item.archivedFrom = from.deletingLastPathComponent().path
            item.archivedName = from.lastPathComponent
        case .restore:
            item.archivedAt = nil
            item.archivedFrom = nil
            item.archivedName = nil
            // So the next pass does not archive it again.
            item.keep = true
        }
        item.pendingMove = nil
    }

    /// A move planned off the main actor may only be locked in if nothing about the item changed since.
    static func canLock(_ planned: DownloadItem, revision: Int, current: DownloadItem?, currentRevision: Int) -> Bool {
        guard let current, revision == currentRevision else { return false }
        return current.directory == planned.directory && current.fileName == planned.fileName
            && current.state == planned.state && current.keep == planned.keep
            && current.archivedAt == planned.archivedAt && current.pendingMove == nil && planned.pendingMove == nil
    }

    static let bannerStep: Int64 = 500_000_000

    /// The main window banner shows from 500 MB, and again after a dismissal once the total grew by 500 MB.
    static func showsBanner(total: Int64, dismissed: Int64) -> Bool {
        total >= bannerStep && total > dismissed + bannerStep
    }
}
