import Foundation

/// A row in the downloads list: one download, or the videos of one playlist folded into a single row.
enum ListEntry: Identifiable, Sendable {
    case item(DownloadItem)
    case group(PlaylistGroup)

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .group(let group): group.id
        }
    }

    /// Folds downloads that share a playlist into one entry, at the place of its first video in `items` (which is
    /// already filtered and sorted). A playlist with only one video showing stays a plain row.
    static func build(_ items: [DownloadItem]) -> [ListEntry] {
        var members: [UUID: [DownloadItem]] = [:]
        for item in items { if let group = item.groupID { members[group, default: []].append(item) } }
        var placed: Set<UUID> = []
        var entries: [ListEntry] = []
        for item in items {
            guard let group = item.groupID, let videos = members[group], videos.count > 1 else {
                entries.append(.item(item))
                continue
            }
            guard placed.insert(group).inserted else { continue }
            // In playlist order: the first video was added with the latest time.
            let ordered = videos.sorted { $0.createdAt > $1.createdAt }
            entries.append(.group(PlaylistGroup(id: group, title: item.groupTitle ?? "Playlist", items: ordered)))
        }
        return entries
    }
}

/// A playlist's videos as one row: what they are doing together.
struct PlaylistGroup: Identifiable, Sendable {
    let id: UUID
    let title: String
    let items: [DownloadItem]

    var ids: [UUID] { items.map(\.id) }
    var done: Int { items.count { $0.state.isFinished } }
    var allDone: Bool { done == items.count }
    var downloading: Int { items.count { $0.state.isActive } }
    var anyRunning: Bool { items.contains { $0.state.isActive || $0.state == .queued } }
    var failed: Int { items.count { $0.state.isFailed } }
    var speed: Double { items.reduce(0) { $0 + ($1.state == .downloading ? $1.speed : 0) } }

    /// Finished videos count fully; the rest by their own progress.
    var fraction: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.state.isFinished ? 1 : min(1, max(0, $1.progress))) } / Double(items.count)
    }

    /// What the playlist is doing, for its chip: nil once every video is done.
    var stage: String? {
        if allDone { return nil }
        if downloading > 0 { return "Downloading" }
        if items.contains(where: { $0.state == .queued }) { return "Queued" }
        if failed > 0, items.allSatisfy({ $0.state.isFinished || $0.state.isFailed }) { return "Failed" }
        return "Paused"
    }

    /// "3 of 12 done · 4.2 MB/s", "12 videos" once all are done, plus how many failed.
    var detail: String {
        if allDone { return "\(items.count) videos" }
        var parts = ["\(done) of \(items.count) done"]
        if failed > 0 { parts.append("\(failed) failed") }
        if downloading > 0 { parts.append(Format.speed(speed)) }
        return parts.joined(separator: " · ")
    }

    /// The size so far, or "1.2 of 3.4 GB" while sizes are known and something is unfinished.
    var sizeText: String {
        let received = items.reduce(Int64(0)) { $0 + ($1.state.isFinished ? ($1.totalBytes ?? $1.receivedBytes) : $1.receivedBytes) }
        let totals = items.compactMap(\.totalBytes)
        guard !allDone, totals.count == items.count else { return Format.bytes(received) }
        return Format.progress(received, of: totals.reduce(0, +))
    }

    /// The folder the videos were saved into.
    var folder: URL? { items.first?.directory }
}
