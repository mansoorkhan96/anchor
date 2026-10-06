import Foundation
import Observation

enum AppEnvironment {
    /// The test bundle is hosted in the app; cleanup must not scan, adopt stamps in, or archive the user's real library then.
    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
    }
}

/// Cleanup suggestions, Drift leftovers, and the installer archive. Reads and mutations happen on the main actor;
/// all disk and process work runs in detached tasks on value snapshots.
@MainActor @Observable
final class CleanupStore {
    static let shared = CleanupStore()
    static let scanInterval: Duration = .seconds(15 * 60)
    static let archiveDelay: Duration = .seconds(30)
    static let archiveInterval: Duration = .seconds(60 * 60)
    static let inspectionsPerPass = 5

    private(set) var candidates: [UUID: CleanupCandidate] = [:]
    private(set) var totalBytes: Int64 = 0
    private(set) var leftovers: [Leftover] = []
    private(set) var leftoverBytes: Int64 = 0
    private(set) var missing: [UUID] = []

    /// What the banner, badge and menu bar report.
    var attentionBytes: Int64 { totalBytes + leftoverBytes }

    private enum Pass { case scan, archive }

    @ObservationIgnored private var started = false
    /// The scan or archive pass running now; passes never overlap.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Passes asked for while one was running; each runs once afterwards.
    @ObservationIgnored private var requested: Set<Pass> = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    private var store: DownloadStore { .shared }
    private var settings: AppSettings { .shared }

    private init() {}

    // MARK: Lifecycle

    /// Called once after the library has loaded: finishes interrupted moves, then starts scanning and archiving.
    func start() {
        guard !started, !AppEnvironment.isRunningTests else { return }
        started = true
        Task {
            await recoverPendingMoves()
            store.cleanupObserver = { CleanupStore.shared.revisionChanged() }
            request(.scan)
            loops.append(Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.scanInterval)
                    request(.scan)
                }
            })
            loops.append(Task {
                try? await Task.sleep(for: Self.archiveDelay)
                while !Task.isCancelled {
                    request(.archive)
                    try? await Task.sleep(for: Self.archiveInterval)
                }
            })
        }
    }

    func rescan() {
        guard started else { return }
        request(.scan)
    }

    private func revisionChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            request(.scan)
        }
    }

    private func request(_ pass: Pass) {
        requested.insert(pass)
        pump()
    }

    private func pump() {
        guard inFlight == nil, let next = requested.first else { return }
        requested.remove(next)
        inFlight = Task {
            switch next {
            case .scan: await scan()
            case .archive: await archivePass()
            }
            inFlight = nil
            pump()
        }
    }

    // MARK: Queries

    /// The Cleanup list: current items that the last scan suggested, largest first.
    func cleanupItems(search: String = "") -> [DownloadItem] {
        candidates.keys.compactMap { store.item($0) }
            .filter { $0.keep != true && $0.pendingMove == nil && DownloadStore.matches($0, search: search) }
            .sorted { (candidates[$0.id]?.bytes ?? 0) > (candidates[$1.id]?.bytes ?? 0) }
    }

    var isOff: Bool { !settings.cleanupDays.values.contains { $0 > 0 } }

    // MARK: Scanning

    private func scan() async {
        let downloads = settings.downloadFolder
        let folders = [downloads] + FileCategory.allCases.map { downloads.appending(path: $0.title, directoryHint: .isDirectory) }
            + store.items.map(\.directory)
        let snapshot = CleanupSnapshot(items: store.items, days: settings.cleanupDays, revision: store.cleanupRevision,
                                       now: Date(), folders: folders)
        let result = await Task.detached(priority: .utility) { CleanupScanner.scan(snapshot) }.value
        guard result.isCurrent(revision: store.cleanupRevision) else {
            // Something changed while scanning; this result may be wrong, so scan again.
            requested.insert(.scan)
            return
        }
        for (id, stamp) in result.baselines where store.item(id)?.stamp == nil {
            store.cleanupMutate(id, bump: false) {
                $0.stamp = stamp
                $0.stampIsBaseline = true
            }
        }
        candidates = result.candidates
        totalBytes = result.candidates.values.reduce(0) { $0 + $1.bytes }
        leftovers = result.leftovers
        leftoverBytes = result.leftovers.reduce(0) { $0 + $1.bytes }
        missing = result.missing
    }

    // MARK: Trash

    /// Moves Cleanup suggestions to the Trash, re-checking each file right before.
    func trash(_ ids: Set<UUID>) async {
        let shared = CleanupRules.sharedPaths(store.items)
        var entries: [TrashEntry] = []
        for id in ids {
            guard let item = store.item(id), item.pendingMove == nil, let candidate = candidates[id] else { continue }
            let rule = TrashEntry.Rule(item: item, days: settings.cleanupDays(for: item.category), sharedPath: shared.contains(candidate.path))
            entries.append(TrashEntry(id: id, name: item.fileName, path: candidate.path, stamp: candidate.stamp, rule: rule))
        }
        await runTrash(entries)
    }

    /// Moves archived files to the Trash if they are still the files Drift archived.
    func trashArchived(_ ids: Set<UUID>) async {
        let entries = ids.compactMap { id -> TrashEntry? in
            guard let item = store.item(id), item.archivedAt != nil, item.pendingMove == nil, let stamp = item.stamp else { return nil }
            return TrashEntry(id: id, name: item.fileName, path: item.destination.standardizedFileURL.path, stamp: stamp, rule: nil)
        }
        await runTrash(entries)
    }

    /// Moves leftover partial files to the Trash unless a download claimed them since the scan.
    func trashLeftovers(_ paths: Set<String>) async {
        let owned = Set(store.items.map { $0.partialFile.standardizedFileURL.path })
        let entries = leftovers.filter { paths.contains($0.path) && !owned.contains($0.path) }.map {
            TrashEntry(id: nil, name: URL(filePath: $0.path).lastPathComponent, path: $0.path, stamp: $0.stamp, rule: nil)
        }
        await runTrash(entries)
    }

    private func runTrash(_ entries: [TrashEntry]) async {
        guard !entries.isEmpty else { return }
        let now = Date()
        let outcome = await Task.detached(priority: .userInitiated) { CleanupTrasher.trash(entries, now: now) }.value
        let trashedPaths = Set(outcome.trashedPaths)
        candidates = candidates.filter { !outcome.trashedIDs.contains($0.key) }
        totalBytes = candidates.values.reduce(0) { $0 + $1.bytes }
        leftovers.removeAll { trashedPaths.contains($0.path) }
        leftoverBytes = leftovers.reduce(0) { $0 + $1.bytes }
        store.removeEntries(Set(outcome.trashedIDs))
        if let message = outcome.message { store.alert = message }
        rescan()
    }

    // MARK: Missing files

    /// Removes entries whose files are gone, re-checking each first. Never touches files.
    func removeMissing() async {
        let items = missing.compactMap { store.item($0) }
        let confirmed = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            return items.filter { item in
                var isFolder: ObjCBool = false
                let folder = fm.fileExists(atPath: item.directory.path, isDirectory: &isFolder) && isFolder.boolValue
                return CleanupRules.isMissing(item, directoryExists: folder, fileExists: fm.fileExists(atPath: item.destination.path))
            }
        }.value
        let unchanged = confirmed.filter { checked in
            guard let current = store.item(checked.id) else { return false }
            return current.destination == checked.destination && current.state == checked.state && current.pendingMove == nil
        }
        store.removeEntries(Set(unchanged.map(\.id)))
        missing.removeAll { id in unchanged.contains { $0.id == id } }
        rescan()
    }

    // MARK: Archive

    private func archivePass() async {
        var inspections = 0
        let ids = store.items.filter { CleanupRules.archiveCandidate($0, now: Date(), enabled: settings.archiveInstallers) }.map(\.id)
        for id in ids {
            let now = Date()
            guard let item = store.item(id), CleanupRules.archiveCandidate(item, now: now, enabled: settings.archiveInstallers) else { continue }
            let inspect = item.installer == nil || item.installer?.stamp != item.stamp
            if inspect {
                guard inspections < Self.inspectionsPerPass else { continue }
                inspections += 1
            }
            let revision = store.cleanupRevision
            let shared = CleanupRules.sharedPaths(store.items).contains(item.destination.standardizedFileURL.path)
            let plan = await Task.detached(priority: .utility) {
                await Archiver.planArchive(item, revision: revision, enabled: true, sharedPath: shared, inspect: inspect, now: now)
            }.value
            if let inspection = plan.inspection, store.item(id)?.stamp == inspection.stamp {
                store.cleanupMutate(id, bump: false) { $0.installer = inspection }
            }
            if let move = plan.move, let error = await perform(move, planned: plan) {
                InstallerInspector.log.error("Archiving \(item.fileName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Steps 2 to 4 of an archive or restore: lock and save, move off the main actor, then commit and save.
    /// Returns nil on success.
    private func perform(_ move: PendingMove, planned plan: ArchivePlan) async -> ArchiveError? {
        let id = plan.id
        guard CleanupRules.canLock(plan.item, revision: plan.revision, current: store.item(id), currentRevision: store.cleanupRevision) else {
            return .failed("The download changed while Drift was preparing the move.")
        }
        store.cleanupMutate(id) { $0.pendingMove = move }
        do {
            try await store.saveNow()
        } catch {
            store.cleanupMutate(id) { $0.pendingMove = nil }
            return .failed("Couldn't save the download list.")
        }
        let result = await Task.detached(priority: .utility) { Archiver.move(move) }.value
        switch result {
        case .success:
            store.cleanupMutate(id) { CleanupRules.applyMove(move, to: &$0, now: Date()) }
        case .failure:
            store.cleanupMutate(id) { $0.pendingMove = nil }
        }
        // A failure here leaves the store dirty and the regular save retries; recovery covers a crash before it lands.
        try? await store.saveNow()
        if case .failure(let error) = result { return error }
        return nil
    }

    /// Moves archived installers back to where they came from and marks them Keep.
    func restore(_ ids: Set<UUID>) async {
        var failures: [String] = []
        for id in ids {
            guard let item = store.item(id), item.archivedAt != nil, item.pendingMove == nil else { continue }
            let revision = store.cleanupRevision
            let fallback = settings.downloadFolder
            let plan = await Task.detached(priority: .userInitiated) {
                Archiver.planRestore(item, revision: revision, fallback: fallback)
            }.value
            if let failure = plan.failure {
                failures.append(failure)
            } else if let move = plan.move, let error = await perform(move, planned: plan) {
                switch error {
                case .changed: failures.append("\(item.fileName) changed, so Drift left it in the archive.")
                case .targetExists: failures.append("Something named \(URL(filePath: move.to).lastPathComponent) appeared in the way. Try again.")
                case .failed(let reason): failures.append("\(item.fileName): \(reason)")
                }
            }
        }
        if !failures.isEmpty { store.alert = "Couldn't restore everything:\n\n" + failures.joined(separator: "\n") }
    }

    // MARK: Recovery

    /// Finishes or rolls back moves interrupted by a crash. Items whose file is in neither place stay locked
    /// and are checked again at the next launch.
    private func recoverPendingMoves() async {
        let pending = store.items.filter { $0.pendingMove != nil }
        guard !pending.isEmpty else { return }
        let outcomes = await Task.detached(priority: .userInitiated) { Archiver.reconcile(pending) }.value
        for item in pending {
            guard let move = item.pendingMove, store.item(item.id)?.pendingMove == move, let outcome = outcomes[item.id] else { continue }
            switch outcome {
            case .completed: store.cleanupMutate(item.id) { CleanupRules.applyMove(move, to: &$0, now: Date()) }
            case .notMoved: store.cleanupMutate(item.id) { $0.pendingMove = nil }
            case .unknown: break
            }
        }
        try? await store.saveNow()
    }
}
