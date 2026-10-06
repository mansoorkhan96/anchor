import Foundation
import CoreServices

/// Everything a scan needs, copied on the main actor so the scan itself can run anywhere.
/// `DownloadItem` is a `Sendable` value type, so the items are plain copies.
struct CleanupSnapshot: Sendable {
    var items: [DownloadItem]
    var days: [FileCategory: Int]
    var revision: Int
    var now: Date
    /// Folders whose top level is checked for leftover partial files.
    var folders: [URL]
}

struct CleanupCandidate: Hashable, Sendable {
    var reason: CleanupReason
    /// Allocated size on disk.
    var bytes: Int64
    /// The stamp read during the scan; trashing requires it to still match.
    var stamp: FileStamp
    /// Standardized destination path at scan time.
    var path: String
}

/// An orphaned `.drift-part` file.
struct Leftover: Hashable, Sendable, Identifiable {
    var path: String
    var bytes: Int64
    var stamp: FileStamp
    var id: String { path }
}

struct CleanupScanResult: Sendable {
    var revision: Int
    var candidates: [UUID: CleanupCandidate]
    var leftovers: [Leftover]
    var missing: [UUID]
    /// Stamps adopted for finished items that never had one (completed before this feature).
    var baselines: [UUID: FileStamp]

    /// A result is only committed if nothing that affects eligibility changed while it ran.
    func isCurrent(revision current: Int) -> Bool { revision == current }
}

enum CleanupScanner {
    /// File system work for one scan. Runs off the main actor; takes and returns only values.
    static func scan(_ snapshot: CleanupSnapshot, lastUsed: (URL) -> Date? = Spotlight.lastUsed) -> CleanupScanResult {
        let fm = FileManager.default
        let shared = CleanupRules.sharedPaths(snapshot.items)
        var candidates: [UUID: CleanupCandidate] = [:]
        var missing: [UUID] = []
        var baselines: [UUID: FileStamp] = [:]

        for item in snapshot.items where item.state == .completed && item.pendingMove == nil {
            let destination = item.destination
            let path = destination.standardizedFileURL.path
            let current = FileStamp.read(destination)
            var effective = item
            if item.stamp == nil, let current {
                effective.stamp = current
                effective.stampIsBaseline = true
                baselines[item.id] = current
            }
            if let current {
                let days = snapshot.days[item.category] ?? 0
                let isShared = shared.contains(path)
                // Spotlight can only block a suggestion, so it is asked only when everything else allows one.
                if CleanupRules.reason(for: effective, now: snapshot.now, days: days, current: current,
                                       lastUsed: nil, sharedPath: isShared) != nil,
                   let reason = CleanupRules.reason(for: effective, now: snapshot.now, days: days, current: current,
                                                    lastUsed: lastUsed(destination), sharedPath: isShared) {
                    candidates[item.id] = CleanupCandidate(reason: reason, bytes: DiskSize.allocated(destination, fallback: current.size),
                                                           stamp: current, path: path)
                }
            } else {
                var isFolder: ObjCBool = false
                let directoryExists = fm.fileExists(atPath: item.directory.path, isDirectory: &isFolder) && isFolder.boolValue
                if CleanupRules.isMissing(item, directoryExists: directoryExists, fileExists: fm.fileExists(atPath: destination.path)) {
                    missing.append(item.id)
                }
            }
        }

        let owned = Set(snapshot.items.map { $0.partialFile.standardizedFileURL.path })
        let leftovers = Leftovers.find(in: snapshot.folders, owned: owned, now: snapshot.now)
        return CleanupScanResult(revision: snapshot.revision, candidates: candidates, leftovers: leftovers,
                                 missing: missing, baselines: baselines)
    }
}

enum Leftovers {
    static let minimumAge: TimeInterval = 3600

    /// `.drift-part` files at the top level of `folders` that no item owns (whatever its state) and that
    /// have not been written to for an hour.
    static func find(in folders: [URL], owned: Set<String>, now: Date) -> [Leftover] {
        var seenFolders: Set<String> = []
        var found: [Leftover] = []
        for folder in folders where seenFolders.insert(folder.standardizedFileURL.path).inserted {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.lastPathComponent.hasSuffix(".drift-part") {
                let path = url.standardizedFileURL.path
                guard !owned.contains(path), let stamp = FileStamp.read(url),
                      now.timeIntervalSince(stamp.modified) > minimumAge else { continue }
                found.append(Leftover(path: path, bytes: DiskSize.allocated(url, fallback: stamp.size), stamp: stamp))
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}

enum Spotlight {
    /// `kMDItemLastUsedDate`: only records opens through LaunchServices, so it is one signal, never proof of disuse.
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

enum DiskSize {
    /// Space the file takes on disk, read fresh.
    static func allocated(_ url: URL, fallback: Int64) -> Int64 {
        let values = try? URL(filePath: url.path).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return values?.totalFileAllocatedSize.map(Int64.init) ?? fallback
    }
}
