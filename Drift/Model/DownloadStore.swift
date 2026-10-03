import AppKit
import Observation
import UserNotifications

/// A pending "add download" the UI should confirm (from the clipboard, browser, menu, or a dropped file).
struct AddRequest: Identifiable, Equatable {
    let id = UUID()
    var url: String = ""
    var headers: [String: String] = [:]
    var suggestedName: String?
    var torrentFile: URL?
    var fromBrowser = false
}

enum SidebarFilter: Hashable {
    case all, downloading, queued, completed, failed
    case category(FileCategory)
    case torrents

    var title: String {
        switch self {
        case .all: "All"
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .completed: "Completed"
        case .failed: "Failed"
        case .category(let c): c.title
        case .torrents: "Torrents"
        }
    }

    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: true
        case .downloading: item.state.isActive
        case .queued: item.state == .queued || item.state == .paused
        case .completed: item.state == .completed
        case .failed: item.state.isFailed
        case .category(let c): item.kind == .http && item.category == c
        case .torrents: item.kind == .torrent
        }
    }
}

@MainActor @Observable
final class DownloadStore {
    static let shared = DownloadStore()
    static let tick: TimeInterval = 0.5
    static let historyLength = 120

    private(set) var items: [DownloadItem] = []
    private(set) var speedHistory: [Double] = Array(repeating: 0, count: historyLength)
    private(set) var totalSpeed: Double = 0
    var addRequest: AddRequest?
    var clipboardSuggestion: URL?
    var alert: String?

    let settings = AppSettings.shared
    private var engines: [UUID: HTTPDownload] = [:]
    private var liveGIDs: Set<String> = []
    private var pollingTorrents = false
    private var timer: Timer?
    private var dirty = false
    private var ticksSinceSave = 0

    private init() {
        load()
        applySpeedLimit()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { _ in
            MainActor.assumeIsolated { DownloadStore.shared.update() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        schedule()
    }

    // MARK: Queries

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    func items(for filter: SidebarFilter, search: String = "") -> [DownloadItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = items.filter {
            filter.matches($0) && (query.isEmpty || $0.fileName.localizedCaseInsensitiveContains(query)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(query))
        }
        return filtered.sorted(by: settings.sortOrder)
    }

    func count(_ filter: SidebarFilter) -> Int { items.count { filter.matches($0) } }

    /// The menu bar's recent list: newest first, optionally with unfinished downloads ahead of finished ones.
    func recentItems(order: MenuBarOrder, limit: Int) -> [DownloadItem] {
        Self.recent(items, order: order, limit: limit)
    }

    nonisolated static func recent(_ items: [DownloadItem], order: MenuBarOrder, limit: Int) -> [DownloadItem] {
        let newest = items.sorted { $0.createdAt > $1.createdAt }
        let ordered = order == .newest ? newest
            : newest.filter { !$0.state.isFinished } + newest.filter(\.state.isFinished)
        return Array(ordered.prefix(max(1, limit)))
    }

    var activeCount: Int { items.count { $0.state.isActive } }
    var queuedCount: Int { items.count { $0.state == .queued } }

    var remainingBytes: Int64 {
        items.filter(\.state.isActive).reduce(0) { $0 + max(0, ($1.totalBytes ?? $1.receivedBytes) - $1.receivedBytes) }
    }

    // MARK: Adding

    /// Adds an http(s) URL, magnet link, or remote .torrent. Returns false if the input isn't usable.
    @discardableResult
    func add(_ text: String, fileName: String? = nil, directory: URL? = nil, headers: [String: String] = [:],
             probe: ProbeResult? = nil, startNow: Bool = true, openWhenDone: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }

        if scheme == "magnet" {
            addTorrent(source: url, file: nil, directory: directory, startNow: startNow)
            return true
        }
        if scheme == "file", url.pathExtension.lowercased() == "torrent" {
            addTorrentFile(url, directory: directory, startNow: startNow)
            return true
        }
        guard scheme == "http" || scheme == "https" else { return false }

        if url.pathExtension.lowercased() == "torrent" || probe?.mimeType == "application/x-bittorrent" {
            Task {
                do {
                    var request = URLRequest(url: url)
                    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let local = AppPaths.torrents.appending(path: "\(UUID().uuidString).torrent")
                    try data.write(to: local)
                    addTorrent(source: url, file: local, directory: directory, startNow: startNow)
                } catch {
                    alert = "Couldn't fetch the torrent file: \(error.localizedDescription)"
                }
            }
            return true
        }

        let name = FileNaming.sanitize(fileName ?? probe?.fileName ?? FileNaming.fileName(from: url))
        let category = FileCategory.detect(fileName: name)
        let folder = directory ?? settings.folder(for: category)

        let enqueue = { (overwrite: Bool) in
            // Overwriting is only safe when no other unfinished download is using the same name.
            let canOverwrite = overwrite && self.uniqueName(name, in: folder, ignoringFinished: true) == name
            var item = DownloadItem(url: url, fileName: canOverwrite ? name : self.uniqueName(name, in: folder),
                                    directory: folder, category: category)
            item.headers = headers
            item.openWhenDone = openWhenDone
            item.nameFromServer = fileName == nil && probe == nil
            item.overwrite = canOverwrite ? true : nil
            if let probe { item.totalBytes = probe.totalBytes }
            self.items.insert(item, at: 0)
            self.markDirty()
            if startNow { self.start(item.id) } else { self.schedule() }
        }

        let existing = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: existing.path) else {
            enqueue(false)
            return true
        }
        switch settings.existingFileAction {
        case .rename: enqueue(false)
        case .overwrite: enqueue(true)
        case .ask: askAboutExisting(existing, renamedTo: uniqueName(name, in: folder), then: enqueue)
        }
        return true
    }

    /// FDM-style prompt in a floating panel, so it shows even while the browser is in front.
    private func askAboutExisting(_ file: URL, renamedTo: String, then enqueue: @escaping (Bool) -> Void) {
        var decided = false
        FloatingPanels.present(onEscape: nil) { close in
            FileConflictView(existing: file, renamedTo: renamedTo) { [weak self] choice, remember in
                guard !decided else { return }
                decided = true
                close()
                if remember, choice != .abort {
                    self?.settings.existingFileAction = choice == .rename ? .rename : .overwrite
                }
                switch choice {
                case .rename: enqueue(false)
                case .overwrite: enqueue(true)
                case .abort: break
                }
            }
        }
    }

    func addTorrentFile(_ file: URL, directory: URL? = nil, startNow: Bool = true) {
        let local = AppPaths.torrents.appending(path: "\(UUID().uuidString).torrent")
        do {
            try FileManager.default.copyItem(at: file, to: local)
            addTorrent(source: file, file: local, directory: directory, startNow: startNow)
        } catch {
            alert = "Couldn't open \(file.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func addTorrent(source: URL, file: URL?, directory: URL?, startNow: Bool) {
        let name: String
        if source.scheme == "magnet" {
            name = FileNaming.magnetName(source) ?? "Magnet link"
        } else {
            name = (source.lastPathComponent as NSString).deletingPathExtension
        }
        let folder = directory ?? settings.downloadFolder
        var item = DownloadItem(url: source, fileName: FileNaming.sanitize(name), directory: folder,
                                category: FileCategory.detect(fileName: name), kind: .torrent)
        item.torrentFile = file
        items.insert(item, at: 0)
        markDirty()
        if startNow { start(item.id) } else { schedule() }
    }

    private func uniqueName(_ name: String, in folder: URL, ignoringFinished: Bool = false) -> String {
        let taken = Set(items.filter { $0.directory == folder && !$0.state.isFinished }.map(\.fileName))
        guard ignoringFinished else { return FileNaming.unique(name, in: folder, taken: taken) }
        // Only check names claimed by other unfinished downloads and their partial files, not finished files on disk.
        let partial = folder.appending(path: name + ".drift-part")
        return taken.contains(name) || FileManager.default.fileExists(atPath: partial.path) ? FileNaming.unique(name, in: folder, taken: taken) : name
    }

    // MARK: Control

    func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].state.isActive else { return }
        items[index].state = .connecting
        let item = items[index]
        try? FileManager.default.createDirectory(at: item.directory, withIntermediateDirectories: true)

        switch item.kind {
        case .http:
            let engine = HTTPDownload(item: item, maxConnections: settings.connections) { event in
                Task { @MainActor in DownloadStore.shared.handle(id, event) }
            }
            engines[id] = engine
            engine.start()
        case .torrent:
            Task { await startTorrent(item) }
        }
        markDirty()
    }

    private func startTorrent(_ item: DownloadItem) async {
        do {
            let gid: String
            if let existing = item.torrentGID, liveGIDs.contains(existing) {
                await Aria2.shared.resume(existing)
                gid = existing
            } else if let file = item.torrentFile {
                gid = try await Aria2.shared.addTorrent(file, directory: item.directory)
            } else {
                gid = try await Aria2.shared.addMagnet(item.url.absoluteString, directory: item.directory)
            }
            liveGIDs.insert(gid)
            await Aria2.shared.setSpeedLimit(settings.effectiveSpeedLimit)
            mutate(item.id) {
                $0.torrentGID = gid
                $0.state = .downloading
            }
        } catch {
            mutate(item.id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func pause(_ id: UUID) {
        guard let item = item(id) else { return }
        if let engine = engines.removeValue(forKey: id) {
            engine.pause()
            apply(engine.snapshot(), to: id)
        }
        if item.kind == .torrent, let gid = item.torrentGID {
            Task { await Aria2.shared.pause(gid) }
        }
        if item.state.isActive || item.state == .queued {
            mutate(id) {
                $0.state = .paused
                $0.speed = 0
                $0.connections = 0
            }
        }
        schedule()
    }

    func resume(_ id: UUID) {
        guard let item = item(id), !item.state.isActive, !item.state.isFinished else { return }
        start(id)
    }

    func toggle(_ id: UUID) {
        guard let item = item(id) else { return }
        item.state.isActive || item.state == .queued ? pause(id) : resume(id)
    }

    func pauseAll() {
        items.filter { $0.state.isActive || $0.state == .queued }.forEach { pause($0.id) }
    }

    /// Puts paused or failed downloads at the back of the waiting line; they start when a slot frees up.
    func queue(_ ids: Set<UUID>) {
        let now = Date()
        for item in items where ids.contains(item.id) && (item.state == .paused || item.state.isFailed) {
            mutate(item.id) {
                $0.state = .queued
                $0.queuedAt = now
            }
        }
        schedule()
    }

    func resumeAll() {
        for item in items where item.state == .paused || item.state.isFailed {
            mutate(item.id) { $0.state = .queued }
        }
        schedule()
    }

    func remove(_ ids: Set<UUID>, deleteFiles: Bool) {
        for id in ids {
            guard let item = item(id) else { continue }
            engines.removeValue(forKey: id)?.pause()
            if item.kind == .torrent, let gid = item.torrentGID {
                Task { await Aria2.shared.remove(gid) }
            }
            if deleteFiles {
                let fm = FileManager.default
                let candidates = [item.destination, item.partialFile,
                                  item.directory.appending(path: item.fileName + ".aria2")]
                for url in candidates where fm.fileExists(atPath: url.path) {
                    try? fm.trashItem(at: url, resultingItemURL: nil)
                }
            } else if !item.state.isFinished, item.kind == .http {
                try? FileManager.default.removeItem(at: item.partialFile)
            }
            if let file = item.torrentFile { try? FileManager.default.removeItem(at: file) }
        }
        items.removeAll { ids.contains($0.id) }
        markDirty()
        schedule()
    }

    /// Moves downloads (finished files or in-progress partials) to another folder.
    func move(_ ids: Set<UUID>, to folder: URL) {
        let fm = FileManager.default
        var skipped: [String] = []
        for id in ids {
            guard let item = item(id), item.directory.standardizedFileURL != folder.standardizedFileURL else { continue }
            if item.kind == .torrent, !item.state.isFinished {
                skipped.append(item.fileName)
                continue
            }
            let wasActive = item.state.isActive
            if wasActive { pause(id) }

            let name = FileNaming.unique(item.fileName, in: folder)
            do {
                if item.state.isFinished {
                    if fm.fileExists(atPath: item.destination.path) {
                        try fm.moveItem(at: item.destination, to: folder.appending(path: name))
                    }
                } else if fm.fileExists(atPath: item.partialFile.path) {
                    try fm.moveItem(at: item.partialFile, to: folder.appending(path: name + ".drift-part"))
                }
                mutate(id) {
                    $0.directory = folder
                    $0.fileName = name
                }
                if wasActive { resume(id) }
            } catch {
                skipped.append(item.fileName)
            }
        }
        if !skipped.isEmpty {
            alert = "Couldn't move: \(skipped.joined(separator: ", ")). Torrents can be moved once they finish."
        }
    }

    func retry(_ id: UUID) {
        guard let item = item(id), item.state.isFailed else { return }
        start(id)
    }

    func reveal(_ id: UUID) {
        guard let item = item(id) else { return }
        let url = item.state.isFinished ? item.destination : item.partialFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(item.directory)
        }
    }

    func open(_ id: UUID) {
        guard let item = item(id), item.state.isFinished else { return }
        NSWorkspace.shared.open(item.destination)
    }

    func applySpeedLimit() {
        let bytes = settings.effectiveSpeedLimit
        RateLimiter.shared.limit = bytes
        Task { await Aria2.shared.setSpeedLimit(bytes) }
    }

    // MARK: Engine events

    private func handle(_ id: UUID, _ event: DownloadEvent) {
        guard item(id) != nil else { return }
        switch event {
        case .started:
            if let engine = engines[id] { apply(engine.snapshot(), to: id) }
            mutate(id) { if $0.state == .connecting { $0.state = .downloading } }
        case .renamed(let name):
            mutate(id) {
                $0.fileName = name
                $0.category = FileCategory.detect(fileName: name)
                $0.nameFromServer = false
            }
        case .completed(let name):
            if let engine = engines.removeValue(forKey: id) { apply(engine.snapshot(), to: id) }
            mutate(id) {
                $0.fileName = name
                $0.receivedBytes = $0.totalBytes ?? $0.receivedBytes
            }
            complete(id)
        case .failed(let message):
            if let engine = engines.removeValue(forKey: id) { apply(engine.snapshot(), to: id) }
            mutate(id) {
                $0.state = .failed(message)
                $0.speed = 0
                $0.connections = 0
            }
            notify(title: "Download failed", body: "\(item(id)?.fileName ?? ""): \(message)")
            schedule()
        }
    }

    private func complete(_ id: UUID) {
        mutate(id) {
            $0.state = .completed
            $0.completedAt = Date()
            $0.speed = 0
            $0.connections = 0
        }
        guard let item = item(id) else { return }
        notify(title: "Download complete", body: item.fileName)
        if item.openWhenDone { NSWorkspace.shared.open(item.destination) }
        schedule()
    }

    private func schedule() {
        var active = activeCount
        let waiting = items.filter { $0.state == .queued }
            .sorted { ($0.queuedAt ?? $0.createdAt) < ($1.queuedAt ?? $1.createdAt) }
        for item in waiting where active < settings.maxConcurrent {
            start(item.id)
            active += 1
        }
    }

    // MARK: Ticking

    private func update() {
        var total: Double = 0
        for (id, engine) in engines {
            let snap = engine.snapshot()
            apply(snap, to: id)
            let instant = Double(snap.delta) / Self.tick
            mutate(id, dirty: false) {
                $0.speed = $0.speed == 0 ? instant : $0.speed * 0.6 + instant * 0.4
                total += $0.speed
            }
        }
        total += items.filter { $0.kind == .torrent && $0.state.isActive }.reduce(0) { $0 + $1.speed }
        totalSpeed = total
        speedHistory.append(total)
        if speedHistory.count > Self.historyLength { speedHistory.removeFirst(speedHistory.count - Self.historyLength) }

        pollTorrents()

        ticksSinceSave += 1
        if dirty, ticksSinceSave >= 4 { save() }
    }

    private func apply(_ snap: DownloadSnapshot, to id: UUID) {
        mutate(id, dirty: snap.delta > 0) {
            $0.segments = snap.segments
            $0.receivedBytes = snap.received
            $0.totalBytes = snap.totalBytes
            $0.supportsRanges = snap.supportsRanges
            $0.validator = snap.validator
            $0.connections = snap.connections
        }
    }

    private func pollTorrents() {
        let running = items.filter { $0.kind == .torrent && $0.state.isActive }.compactMap { item in
            item.torrentGID.map { (item.id, $0) }
        }
        guard !running.isEmpty, !pollingTorrents else { return }
        pollingTorrents = true
        Task {
            defer { pollingTorrents = false }
            for (id, gid) in running {
                guard let status = try? await Aria2.shared.status(gid) else { continue }
                applyTorrent(status, gid: gid, to: id)
            }
        }
    }

    private func applyTorrent(_ status: TorrentStatus, gid: String, to id: UUID) {
        if let next = status.followedBy {
            liveGIDs.insert(next)
            mutate(id) { $0.torrentGID = next }
            adoptSavedMetadata(for: id)
            return
        }
        mutate(id, dirty: false) {
            if let name = status.name { $0.fileName = name; $0.category = FileCategory.detect(fileName: name) }
            if status.totalBytes > 0 { $0.totalBytes = status.totalBytes }
            $0.receivedBytes = status.completedBytes
            $0.speed = status.speed
            $0.connections = status.connections
            $0.peers = status.connections
            $0.seeders = status.seeders
        }
        switch status.state {
        case "complete": complete(id)
        case "error", "removed": mutate(id) { $0.state = .failed(status.errorMessage ?? "Torrent stopped") }
        default: break
        }
        dirty = true
    }

    /// aria2 writes `<infohash>.torrent` next to the download once a magnet's metadata arrives. Move it into
    /// Application Support so the download folder stays clean and a restart can resume without re-fetching it.
    private func adoptSavedMetadata(for id: UUID) {
        guard let item = item(id), item.torrentFile == nil,
              let hash = URLComponents(url: item.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "xt" })?.value?.split(separator: ":").last?.lowercased() else { return }
        let saved = item.directory.appending(path: "\(hash).torrent")
        Task {
            for _ in 0..<10 where !FileManager.default.fileExists(atPath: saved.path) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            let target = AppPaths.torrents.appending(path: "\(UUID().uuidString).torrent")
            guard (try? FileManager.default.moveItem(at: saved, to: target)) != nil else { return }
            mutate(id) { $0.torrentFile = target }
        }
    }

    // MARK: Persistence

    private func mutate(_ id: UUID, dirty markDirty: Bool = true, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        if markDirty { dirty = true }
    }

    private func markDirty() { dirty = true }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.library),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = saved.map { item in
            var item = item
            if item.state.isActive { item.state = .queued }
            return item
        }
    }

    func save() {
        ticksSinceSave = 0
        dirty = false
        let snapshot = items
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: AppPaths.library, options: .atomic)
        }
    }

    /// Called on quit: stop engines so partial progress is captured, then save synchronously.
    func shutdown() {
        for (id, engine) in engines {
            engine.pause()
            apply(engine.snapshot(), to: id)
            mutate(id) { $0.state = .queued }
        }
        engines.removeAll()
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: AppPaths.library, options: .atomic)
        }
        Task { await Aria2.shared.shutdown() }
    }

    private func notify(title: String, body: String) {
        guard settings.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Array where Element == DownloadItem {
    func sorted(by order: SortOrder) -> [DownloadItem] {
        switch order {
        case .newest: sorted { $0.createdAt > $1.createdAt }
        case .oldest: sorted { $0.createdAt < $1.createdAt }
        case .largest: sorted { ($0.totalBytes ?? -1) > ($1.totalBytes ?? -1) }
        case .smallest: sorted { ($0.totalBytes ?? .max) < ($1.totalBytes ?? .max) }
        case .name: sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }
    }
}
