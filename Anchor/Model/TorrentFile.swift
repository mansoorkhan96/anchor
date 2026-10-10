import Foundation

enum Priority: Int, Codable, CaseIterable, Identifiable, Sendable {
    case low = 0, normal = 1, high = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    var symbol: String {
        switch self {
        case .low: "arrow.down"
        case .normal: "equal"
        case .high: "arrow.up"
        }
    }
}

/// One file inside a torrent. `index` is aria2's 1-based file index.
struct TorrentFile: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var path: String
    var length: Int64
    var completed: Int64 = 0
    /// Skipped files are never downloaded.
    var included = true
    var priority: Priority = .normal

    var id: Int { index }
    var name: String { (path as NSString).lastPathComponent }
    var isDone: Bool { length > 0 && completed >= length }
    var progress: Double { length > 0 ? min(1, Double(completed) / Double(length)) : 0 }
}

enum TorrentSelection {
    /// The files aria2 should download right now.
    ///
    /// aria2 has no per-file priority, so Anchor downloads in phases: included files of the highest priority that
    /// still have bytes to fetch, plus everything above that priority and anything already finished. When a phase
    /// completes, the next priority level is added.
    static func phase(_ files: [TorrentFile]) -> [Int] {
        let included = files.filter(\.included)
        guard let top = included.filter({ !$0.isDone }).map(\.priority.rawValue).max() else {
            return included.map(\.index)
        }
        return included.filter { $0.priority.rawValue >= top || $0.isDone }.map(\.index).sorted()
    }

    /// True when some included files are still waiting for a later phase.
    static func hasLaterPhase(_ files: [TorrentFile], selected: [Int]) -> Bool {
        files.contains { $0.included && !$0.isDone && !selected.contains($0.index) }
    }
}
