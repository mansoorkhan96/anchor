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
    /// The download whose details slide-over is open in the main window.
    var focusedID: UUID?
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
        applySeeding()
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
            if startNow { self.startOrQueue(item.id) } else { self.schedule() }
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
        if startNow { startOrQueue(item.id) } else { schedule() }
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
            let selection = item.files.map(TorrentSelection.phase)
            if let existing = item.torrentGID, liveGIDs.contains(existing) {
                if let selection { await Aria2.shared.select(existing, files: selection) }
                await Aria2.shared.resume(existing)
                gid = existing
            } else if let file = item.torrentFile {
                gid = try await Aria2.shared.addTorrent(file, directory: item.directory, select: selection,
                                                        checkIntegrity: item.files?.contains { $0.completed > 0 } == true)
            } else {
                gid = try await Aria2.shared.addMagnet(item.url.absoluteString, directory: item.directory)
            }
            liveGIDs.insert(gid)
            await Aria2.shared.setSpeedLimit(settings.effectiveSpeedLimit)
            if let kb = item.speedLimitKB {
                await Aria2.shared.setDownloadLimit(gid, bytesPerSecond: Int64(kb) * 1000)
            }
            mutate(item.id) {
                $0.torrentGID = gid
                $0.state = .downloading
                if let selection { $0.appliedSelection = selection }
            }
        } catch {
            mutate(item.id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// Adds a torrent that was prepared (and reviewed) in the New Download window.
    func addPreparedTorrent(_ prepared: PreparedTorrent, source: URL, torrentFile: URL?, priority: Priority, startNow: Bool) {
        var item = DownloadItem(url: source, fileName: FileNaming.sanitize(prepared.name), directory: prepared.directory,
                                category: FileCategory.detect(fileName: prepared.name), kind: .torrent)
        item.torrentGID = prepared.gid
        item.torrentFile = torrentFile
        item.files = prepared.files
        item.priority = priority == .normal ? nil : priority
        let included = prepared.files.filter(\.included)
        item.totalBytes = included.reduce(0) { $0 + $1.length }
        liveGIDs.insert(prepared.gid)
        items.insert(item, at: 0)
        markDirty()
        if torrentFile == nil { adoptSavedMetadata(for: item.id) }
        if startNow {
            startOrQueue(item.id)
        } else {
            mutate(item.id) { $0.state = .queued; $0.queuedAt = Date() }
            schedule()
        }
    }

    // MARK: Torrent files and priority

    /// Skip or include one file of a torrent.
    func setFile(_ index: Int, of id: UUID, included: Bool) {
        guard let files = item(id)?.files else { return }
        // Keep at least one file, or aria2 would download everything.
        if !included, files.filter(\.included).count <= 1 { return }
        updateFiles(id) { files in
            if let i = files.firstIndex(where: { $0.index == index }) { files[i].included = included }
        }
    }

    func setAllFiles(of id: UUID, included: Bool) {
        updateFiles(id) { files in
            for i in files.indices { files[i].included = included }
            if !included, !files.isEmpty { files[0].included = true }
        }
    }

    func setFilePriority(_ index: Int, of id: UUID, to priority: Priority) {
        updateFiles(id) { files in
            if let i = files.firstIndex(where: { $0.index == index }) { files[i].priority = priority }
        }
    }

    /// Caps (or uncaps, with nil) the speed of individual downloads, live.
    func setSpeedLimit(_ ids: Set<UUID>, kb: Int?) {
        for id in ids {
            mutate(id) { $0.speedLimitKB = kb }
            let bytes = Int64(kb ?? 0) * 1000
            engines[id]?.setSpeedLimit(bytes)
            if let item = item(id), item.kind == .torrent, let gid = item.torrentGID, liveGIDs.contains(gid) {
                Task { await Aria2.shared.setDownloadLimit(gid, bytesPerSecond: bytes) }
            }
        }
    }

    func setPriority(_ ids: Set<UUID>, to priority: Priority) {
        for id in ids { mutate(id) { $0.priority = priority == .normal ? nil : priority } }
        schedule()
    }

    private func updateFiles(_ id: UUID, _ change: (inout [TorrentFile]) -> Void) {
        guard var files = item(id)?.files else { return }
        change(&files)
        let included = files.filter(\.included)
        mutate(id) {
            $0.files = files
            $0.totalBytes = included.reduce(0) { $0 + $1.length }
            $0.receivedBytes = included.reduce(0) { $0 + min($1.completed, $1.length) }
        }
        applySelection(id)
    }

    /// Sends the current phase's file selection to aria2 if it changed.
    private func applySelection(_ id: UUID) {
        guard let item = item(id), let files = item.files, let gid = item.torrentGID, liveGIDs.contains(gid) else { return }
        let selection = TorrentSelection.phase(files)
        guard selection != item.appliedSelection else { return }
        mutate(id) { $0.appliedSelection = selection }
        Task { await Aria2.shared.select(gid, files: selection) }
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
        startOrQueue(id)
    }

    /// Starts now if there's a free slot under "Simultaneous downloads", otherwise joins the back of the queue.
    private func startOrQueue(_ id: UUID) {
        if activeCount < settings.maxConcurrent {
            start(id)
        } else {
            mutate(id) {
                $0.state = .queued
                $0.queuedAt = Date()
            }
        }
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
            let trash = {
                let fm = FileManager.default
                let candidates = [item.destination, item.partialFile,
                                  item.directory.appending(path: item.fileName + ".aria2")]
                for url in candidates where fm.fileExists(atPath: url.path) {
                    try? fm.trashItem(at: url, resultingItemURL: nil)
                }
            }
            if item.kind == .torrent, let gid = item.torrentGID {
                liveGIDs.remove(gid)
                // Stop aria2 first: it rewrites its .aria2 progress file while shutting a torrent down.
                Task {
                    await Aria2.shared.remove(gid)
                    if deleteFiles { trash() }
                }
            } else if deleteFiles {
                trash()
            }
            if !deleteFiles, !item.state.isFinished, item.kind == .http {
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
        startOrQueue(id)
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

    /// Sends the seeding settings to aria2 for new and running torrents.
    func applySeeding() {
        let live = items.filter { $0.kind == .torrent && ($0.state.isActive || $0.seeding == true) }.compactMap(\.torrentGID)
        let (enabled, ratio, upload) = (settings.seedTorrents, settings.seedRatio, Int64(settings.uploadLimitKB) * 1000)
        Task { await Aria2.shared.configureSeeding(enabled: enabled, ratio: ratio, uploadLimit: upload, live: live) }
        if !enabled {
            for item in items where item.seeding == true { stopSeeding(item.id) }
        }
    }

    func stopSeeding(_ id: UUID) {
        guard let item = item(id), item.seeding == true else { return }
        if let gid = item.torrentGID {
            liveGIDs.remove(gid)
            Task { await Aria2.shared.remove(gid) }
        }
        mutate(id) {
            $0.seeding = nil
            $0.uploadSpeed = 0
        }
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
        runWhenDoneIfFinished()
    }

    /// After the last download completes, runs the chosen "when done" action (with a chance to cancel).
    private func runWhenDoneIfFinished() {
        let action = settings.whenDone
        guard action != .nothing, activeCount + queuedCount == 0 else { return }
        settings.whenDone = .nothing
        FloatingPanels.present { close in
            WhenDoneView(action: action) { confirmed in
                close()
                if confirmed { Power.perform(action) }
            }
        }
    }

    // MARK: Links

    /// Points a download at a fresh link (e.g. after the old one expired) and keeps the bytes already downloaded.
    /// If the server reports a different file size, the next start begins again from zero.
    func updateLink(_ id: UUID, to url: URL) {
        guard let item = item(id), item.kind == .http, !item.state.isFinished else { return }
        let resumeAfter = item.state.isActive || item.state == .queued || item.state.isFailed
        if engines[id] != nil { pause(id) }
        mutate(id) {
            $0.url = url
            $0.validator = nil
            if $0.state.isFailed { $0.state = .paused }
        }
        if resumeAfter { resume(id) }
    }

    /// Starts queued downloads while there are free slots.
    func schedule() {
        var active = activeCount
        let waiting = items.filter { $0.state == .queued }
            .sorted {
                let (p0, p1) = (($0.priority ?? .normal).rawValue, ($1.priority ?? .normal).rawValue)
                if p0 != p1 { return p0 > p1 }
                return ($0.queuedAt ?? $0.createdAt) < ($1.queuedAt ?? $1.createdAt)
            }
        for item in waiting where active < settings.maxConcurrent {
            start(item.id)
            active += 1
        }
    }

    // MARK: Ticking

    private func update() {
        Power.keepAwake(settings.keepAwake && activeCount > 0)
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
        let running = items.filter { $0.kind == .torrent && ($0.state.isActive || $0.seeding == true) }.compactMap { item in
            item.torrentGID.map { (item.id, $0, item.directory) }
        }
        guard !running.isEmpty, !pollingTorrents else { return }
        pollingTorrents = true
        Task {
            defer { pollingTorrents = false }
            for (id, gid, directory) in running {
                guard let status = try? await Aria2.shared.status(gid) else { continue }
                if status.followedBy == nil, status.totalBytes > 0,
                   let files = try? await Aria2.shared.files(gid, directory: directory) {
                    mergeFiles(files, into: id)
                }
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
        let hasFiles = item(id)?.files != nil
        mutate(id, dirty: false) {
            if let name = status.name { $0.fileName = name; $0.category = FileCategory.detect(fileName: name) }
            if !hasFiles {
                if status.totalBytes > 0 { $0.totalBytes = status.totalBytes }
                $0.receivedBytes = status.completedBytes
            }
            $0.speed = status.speed
            $0.connections = status.connections
            $0.peers = status.connections
            $0.seeders = status.seeders
            $0.uploadSpeed = status.uploadSpeed
            $0.uploadedBytes = status.uploadedBytes
        }
        // Seeding: aria2 keeps the torrent "active" after the download finishes, until the ratio is reached.
        if item(id)?.state == .completed {
            if status.state != "active" {
                mutate(id) {
                    $0.seeding = nil
                    $0.uploadSpeed = 0
                }
                liveGIDs.remove(gid)
            }
            return
        }
        let downloaded = status.state == "active" && status.totalBytes > 0 && status.completedBytes >= status.totalBytes
        switch downloaded ? "complete" : status.state {
        case "complete":
            if downloaded, status.state == "active" {
                // Finished but still seeding: hand over the file now, keep uploading in the background.
                if let item = item(id), let files = item.files,
                   TorrentSelection.hasLaterPhase(files, selected: item.appliedSelection ?? TorrentSelection.phase(files)) {
                    applySelection(id)
                    break
                }
                mutate(id) { $0.seeding = true }
                complete(id)
                break
            }
            if let item = item(id), let files = item.files,
               TorrentSelection.hasLaterPhase(files, selected: item.appliedSelection ?? TorrentSelection.phase(files)) {
                startNextPhase(id, finishedGID: gid)
            } else {
                complete(id)
            }
        case "error", "removed": mutate(id) { $0.state = .failed(status.errorMessage ?? "Torrent stopped") }
        default: break
        }
        dirty = true
    }

    /// Merges aria2's per-file progress with the user's include and priority choices.
    private func mergeFiles(_ fresh: [TorrentFile], into id: UUID) {
        guard let item = item(id) else { return }
        let current = Dictionary(uniqueKeysWithValues: (item.files ?? []).map { ($0.index, $0) })
        let merged = fresh.map { file in
            var file = file
            if let known = current[file.index] {
                file.included = known.included
                file.priority = known.priority
            }
            return file
        }
        let included = merged.filter(\.included)
        mutate(id, dirty: false) {
            $0.files = merged
            $0.totalBytes = included.reduce(0) { $0 + $1.length }
            $0.receivedBytes = included.reduce(0) { $0 + min($1.completed, $1.length) }
        }
        applySelection(id)
    }

    /// aria2 finished the current priority phase: re-add the torrent with the next files, keeping what's done.
    private func startNextPhase(_ id: UUID, finishedGID: String) {
        guard let item = item(id), let files = item.files, let torrentFile = item.torrentFile else {
            complete(id)
            return
        }
        let selection = TorrentSelection.phase(files)
        mutate(id) { $0.appliedSelection = selection }
        Task {
            await Aria2.shared.remove(finishedGID)
            liveGIDs.remove(finishedGID)
            do {
                let gid = try await Aria2.shared.addTorrent(torrentFile, directory: item.directory,
                                                            select: selection, checkIntegrity: true)
                liveGIDs.insert(gid)
                mutate(id) { $0.torrentGID = gid }
            } catch {
                mutate(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
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

    /// Reads the saved list one item at a time, so a single unreadable entry can't wipe the rest. If the file
    /// can't be read at all it is kept aside (never overwritten) and a backup of every good load is kept too.
    private func load() {
        let url = AppPaths.library
        guard let data = try? Data(contentsOf: url) else { return }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            preserveUnreadable(url)
            return
        }
        let decoder = JSONDecoder()
        var loaded: [DownloadItem] = []
        var skipped = 0
        for entry in raw {
            guard let itemData = try? JSONSerialization.data(withJSONObject: entry),
                  var item = try? decoder.decode(DownloadItem.self, from: itemData) else {
                skipped += 1
                continue
            }
            if item.state.isActive { item.state = .queued }
            item.seeding = nil
            loaded.append(item)
        }
        if skipped > 0 { preserveUnreadable(url) }
        items = loaded
        try? FileManager.default.removeItem(at: AppPaths.libraryBackup)
        try? FileManager.default.copyItem(at: url, to: AppPaths.libraryBackup)
    }

    private func preserveUnreadable(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().appending(path: "downloads-unreadable-\(stamp).json"))
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
