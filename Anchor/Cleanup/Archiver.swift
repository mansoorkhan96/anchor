import Foundation

enum ArchiveError: Error, Equatable, Sendable {
    /// The file at the source is not the one that was planned for.
    case changed
    /// Something already exists at the target.
    case targetExists
    case failed(String)
}

/// The outcome of planning one archive or restore off the main actor.
struct ArchivePlan: Sendable {
    var id: UUID
    /// The item as it was when planning started; locking requires it to be unchanged.
    var item: DownloadItem
    var revision: Int
    /// The move to lock in and perform, nil if nothing should move.
    var move: PendingMove?
    /// A fresh inspection result to cache, if one ran.
    var inspection: InstallerInfo?
    /// Why a restore can't happen, for the alert.
    var failure: String?
}

/// Archive and restore moves. Every function takes values and runs off the main actor.
enum Archiver {
    /// `~/Downloads/Drift Archive`.
    static var root: URL { URL.downloadsDirectory.appending(path: "Drift Archive", directoryHint: .isDirectory) }

    /// e.g. "2026-10 October".
    static func monthFolderName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM MMMM"
        return formatter.string(from: date)
    }

    static func target(for name: String, in folder: URL) -> URL {
        folder.appending(path: FileNaming.unique(name, in: folder))
    }

    /// The original folder and name, with a suffix only if the name is taken. The default download folder
    /// stands in when the original folder is gone.
    static func restoreTarget(_ item: DownloadItem, fallback: URL) -> URL {
        var isFolder: ObjCBool = false
        let folder = item.archivedFrom.flatMap { path in
            FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
                ? URL(filePath: path, directoryHint: .isDirectory) : nil
        } ?? fallback
        return target(for: item.archivedName ?? item.fileName, in: folder)
    }

    /// Moves the file only if it is still the planned one and the target is free.
    static func move(_ move: PendingMove) -> Result<Void, ArchiveError> {
        let fm = FileManager.default
        guard FileStamp.read(URL(filePath: move.from)) == move.stamp else { return .failure(.changed) }
        // attributesOfItem also sees a dangling symlink, which fileExists would miss.
        guard (try? fm.attributesOfItem(atPath: move.to)) == nil else { return .failure(.targetExists) }
        do {
            try fm.moveItem(atPath: move.from, toPath: move.to)
            if move.kind == .restore { pruneEmptyFolders(from: URL(filePath: move.from).deletingLastPathComponent()) }
            return .success(())
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Removes `folder`, then its parents up to and including `root`, while each is empty, so restoring or
    /// trashing the last archived file doesn't leave empty month folders behind. A Finder `.DS_Store` doesn't
    /// count as content. Folders outside `root` are never touched.
    static func pruneEmptyFolders(from folder: URL, root: URL = root) {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var dir = folder.standardizedFileURL
        while dir.path == rootPath || dir.path.hasPrefix(rootPath + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            if !contents.isEmpty { try? fm.removeItem(at: dir.appending(path: ".DS_Store")) }
            guard (try? fm.removeItem(at: dir)) != nil, dir.path != rootPath else { return }
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Step 1 of the archive transaction: inspect if needed, decide with fresh facts, and pick the target.
    static func planArchive(_ item: DownloadItem, revision: Int, enabled: Bool, sharedPath: Bool,
                            inspect: Bool, now: Date) async -> ArchivePlan {
        var plan = ArchivePlan(id: item.id, item: item, revision: revision)
        let source = item.destination
        guard let current = FileStamp.read(source), current == item.stamp else { return plan }
        var decided = item
        if inspect, let inspection = await InstallerInspector.inspect(source, expected: current) {
            plan.inspection = inspection
            decided.installer = inspection
        }
        guard let bundleID = decided.installer?.bundleID, decided.installer?.failed == false,
              CleanupRules.archiveCandidate(decided, now: now, enabled: enabled) else { return plan }

        let installed = InstallerInspector.installedVersions(bundleID: bundleID)
        let mounted = await InstallerInspector.isMounted(source) ?? true
        // Decide against the Downloads volume first, so no folder is created for an item that can't move.
        var facts = ArchiveFacts(current: FileStamp.read(source), archiveVolume: FileStamp.volumeUUID(of: URL.downloadsDirectory),
                                 installedVersions: installed, mounted: mounted, sharedPath: sharedPath)
        guard CleanupRules.shouldArchive(decided, now: now, enabled: enabled, facts: facts) else { return plan }

        let folder = root.appending(path: monthFolderName(now), directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return plan }
        facts.archiveVolume = FileStamp.volumeUUID(of: folder)
        facts.current = FileStamp.read(source)
        guard CleanupRules.shouldArchive(decided, now: now, enabled: enabled, facts: facts) else { return plan }
        plan.move = PendingMove(kind: .archive, from: source.path, to: target(for: item.fileName, in: folder).path, stamp: current)
        return plan
    }

    /// Step 1 of a restore: the archived file must still be there and unchanged, and the target on the same volume.
    static func planRestore(_ item: DownloadItem, revision: Int, fallback: URL) -> ArchivePlan {
        var plan = ArchivePlan(id: item.id, item: item, revision: revision)
        guard item.archivedAt != nil, item.pendingMove == nil else { return plan }
        guard let current = FileStamp.read(item.destination) else {
            plan.failure = "\(item.fileName) is no longer in the archive folder."
            return plan
        }
        guard current == item.stamp else {
            plan.failure = "\(item.fileName) changed since it was archived, so Anchor left it where it is."
            return plan
        }
        let target = restoreTarget(item, fallback: fallback)
        guard let volume = FileStamp.volumeUUID(of: target.deletingLastPathComponent()), volume == current.volume else {
            plan.failure = "\(item.fileName) can't be restored because its folder is on a different disk."
            return plan
        }
        plan.move = PendingMove(kind: .restore, from: item.destination.path, to: target.path, stamp: current)
        return plan
    }

    /// Crash recovery: where did each recorded move end up?
    static func reconcile(_ items: [DownloadItem]) -> [UUID: CleanupRules.Reconciliation] {
        var result: [UUID: CleanupRules.Reconciliation] = [:]
        for item in items {
            guard let move = item.pendingMove else { continue }
            result[item.id] = CleanupRules.reconcile(move) { FileStamp.read(URL(filePath: $0)) }
        }
        return result
    }
}
