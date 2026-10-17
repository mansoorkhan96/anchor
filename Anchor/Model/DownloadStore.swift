import AppKit
import Observation
import UserNotifications

/// A pending "add download" the UI should confirm (from the clipboard, browser, menu, or a dropped file).
struct AddRequest: Identifiable, Equatable {
    let id = UUID()
    var url: String = ""
    var headers: [String: String] = [:]
    /// The site's cookies from the browser extension, for video links.
    var cookieJar: [BrowserCookie] = []
    var suggestedName: String?
    var torrentFile: URL?
    var fromBrowser = false
}

enum SidebarFilter: Hashable {
    case all, downloading, queued, completed, failed
    case category(FileCategory)
    case torrents
    /// Tidy lists; their items come from dedicated queries, not `matches(_:)`.
    case cleanup, archive

    var isTidy: Bool { self == .cleanup || self == .archive }

    var title: String {
        switch self {
        case .all: "All"
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .completed: "Completed"
        case .failed: "Failed"
        case .category(let c): c.title
        case .torrents: "Torrents"
        case .cleanup: "Cleanup"
        case .archive: "Archive"
        }
    }

    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: true
        case .downloading: item.state.isActive
        case .queued: item.state == .queued || item.state == .paused
        case .completed: item.state == .completed
        case .failed: item.state.isFailed
        case .category(let c): item.kind != .torrent && item.category == c
        case .torrents: item.kind == .torrent
        case .cleanup, .archive: false
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
    /// Media downloads that already had their one automatic retry this run.
    private var autoRetried: Set<UUID> = []
    static let mediaRetryDelay: Double = 30
    /// Notification permission is asked for at the first notification, once per run.
    private var askedForNotifications = false
    private(set) var totalSpeed: Double = 0
    var addRequest: AddRequest?
    var clipboardSuggestion: URL?
    /// The download whose details slide-over is open in the main window.
    var focusedID: UUID?
    var alert: String?
    /// A sidebar list the main window should switch to (e.g. Cleanup, from the menu bar).
    var pendingFilter: SidebarFilter?
    /// Bumped by every change that can affect cleanup eligibility (not by progress ticks).
    private(set) var cleanupRevision = 0
    /// Called after each bump; set by `CleanupStore` to schedule a rescan.
    var cleanupObserver: (@MainActor () -> Void)?

    let settings = AppSettings.shared
    private var engines: [UUID: HTTPDownload] = [:]
    private var liveGIDs: Set<String> = []
    /// Torrents added before the New Download window finished loading their files; they start once it has.
    private var preparing: [UUID: Task<PreparedTorrent, Error>] = [:]
    private var pollingTorrents = false
    private var timer: Timer?
    private var tracker = SaveTracker()
    private let writer = LibraryWriter(url: AppPaths.library)
    private var ticksSinceSave = 0

    private init() {
        load()
        applySpeedLimit()
        applySeeding()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { _ in
            MainActor.assumeIsolated { DownloadStore.shared.update() }
        }
        // Downloads that were running at quit start one runloop turn later, after the window is up.
        Task { @MainActor in DownloadStore.shared.schedule() }
    }

    // MARK: Queries

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    func items(for filter: SidebarFilter, search: String = "") -> [DownloadItem] {
        let filtered = items.filter { filter.matches($0) && Self.matches($0, search: search) }
        return filtered.sorted(by: settings.sortOrder)
    }

    nonisolated static func matches(_ item: DownloadItem, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || item.fileName.localizedCaseInsensitiveContains(query)
            || item.url.absoluteString.localizedCaseInsensitiveContains(query)
    }

    /// The Archive list: archived items, newest first.
    func archivedItems(search: String = "") -> [DownloadItem] {
        items.filter { $0.archivedAt != nil && Self.matches($0, search: search) }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// Mid archive or restore: every action that touches the file or entry is unavailable.
    func isLocked(_ id: UUID) -> Bool { item(id)?.pendingMove != nil }

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
    /// Running downloads plus media processes still shutting down: those keep their slot until they exit.
    private var busySlots: Int { activeCount + MediaJobs.shared.stopping.count { item($0)?.state.isActive != true } }
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
            self.bumpCleanupRevision()
            self.markDirty()
            if startNow { self.startOrQueue(item.id, respectSchedule: true) } else { self.schedule() }
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

    /// Prompt in a floating panel, so it shows even while the browser is in front.
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
        bumpCleanupRevision()
        markDirty()
        if startNow { startOrQueue(item.id, respectSchedule: true) } else { schedule() }
    }

    /// Adds a video page reviewed in the New Download window; yt-dlp downloads it.
    func addMedia(_ url: URL, name: String, directory: URL?, quality: MediaQuality, info: MediaInfo?,
                  convertHeight: Int? = nil, playableOnly: Bool = false, subtitle: MediaSubtitle? = nil,
                  cookieJar: [BrowserCookie] = [], startNow: Bool, openWhenDone: Bool) {
        let item = makeMedia(url, name: name, directory: directory, quality: quality, info: info, convertHeight: convertHeight,
                             playableOnly: playableOnly, subtitle: subtitle, cookieJar: cookieJar, openWhenDone: openWhenDone)
        items.insert(item, at: 0)
        bumpCleanupRevision()
        markDirty()
        if startNow { startOrQueue(item.id, respectSchedule: true) } else { schedule() }
    }

    /// Adds the chosen videos of a playlist as one download each, in the playlist's order, into a folder named after
    /// it. `numbered` puts each video's place in the playlist in front of its name ("03 Title").
    func addPlaylist(_ videos: [(index: Int, video: PlaylistVideo)], folderName: String, extractor: String?,
                     quality: MediaQuality, directory: URL?, numbered: Bool, cookieJar: [BrowserCookie] = [], startNow: Bool) {
        guard !videos.isEmpty else { return }
        let base = directory ?? settings.folder(for: quality.category)
        let name = FileNaming.sanitize(folderName.trimmingCharacters(in: .whitespaces))
        let folder = name.isEmpty ? base : base.appending(path: name, directoryHint: .isDirectory)
        let digits = max(2, String(videos.map(\.index).max() ?? 0).count)
        let now = Date()
        let group = UUID()
        let groupTitle = name.isEmpty ? (folderName.isEmpty ? "Playlist" : folderName) : name
        var added: [DownloadItem] = []
        for (offset, entry) in videos.enumerated() {
            let title = numbered ? String(format: "%0\(digits)d ", entry.index) + entry.video.title : entry.video.title
            var item = makeMedia(entry.video.url, name: title, directory: folder, quality: quality,
                                 info: MediaInfo(title: entry.video.title, extractor: extractor, thumbnail: entry.video.thumbnail,
                                                 duration: entry.video.duration),
                                 playableOnly: true, cookieJar: cookieJar, openWhenDone: false, taken: added)
            // Named after the site's title once yt-dlp reports it, when the playlist didn't list one.
            item.nameFromServer = entry.video.titled ? nil : true
            item.groupID = group
            item.groupTitle = groupTitle
            // Listed and queued in the playlist's order: the first video is the newest in the list and leaves the
            // queue first.
            item.createdAt = now.addingTimeInterval(-Double(offset) / 1000)
            item.queuedAt = now.addingTimeInterval(Double(offset) / 1000)
            added.append(item)
        }
        items.insert(contentsOf: added, at: 0)
        bumpCleanupRevision()
        markDirty()
        if startNow {
            for item in added { startOrQueue(item.id, respectSchedule: true, keepQueuedAt: true) }
        } else {
            schedule()
        }
    }

    /// `taken`: items about to be added alongside this one, whose names count as used.
    private func makeMedia(_ url: URL, name: String, directory: URL?, quality: MediaQuality, info: MediaInfo?,
                           convertHeight: Int? = nil, playableOnly: Bool = false, subtitle: MediaSubtitle? = nil,
                           cookieJar: [BrowserCookie], openWhenDone: Bool, taken: [DownloadItem] = []) -> DownloadItem {
        let folder = directory ?? settings.folder(for: quality.category)
        let stem = MediaNaming.stem(FileNaming.sanitize(name.isEmpty ? (info?.title ?? "Video") : name))
        let alsoTaken = Set(taken.filter { $0.directory == folder }.map(\.fileName))
        var item = DownloadItem(url: url, fileName: uniqueName("\(stem).\(quality.expectedExtension)", in: folder, alsoTaken: alsoTaken),
                                directory: folder, category: quality.category, kind: .media)
        item.mediaQuality = quality
        item.mediaInfo = info
        item.mediaConvertHeight = quality.isAudio || playableOnly ? nil : convertHeight
        item.mediaPlayableOnly = playableOnly ? true : nil
        item.mediaSubtitle = quality.isAudio ? nil : subtitle
        item.cookieJar = cookieJar.isEmpty ? nil : cookieJar
        item.openWhenDone = openWhenDone
        return item
    }

    private func uniqueName(_ name: String, in folder: URL, ignoringFinished: Bool = false, alsoTaken: Set<String> = []) -> String {
        let taken = Set(items.filter { $0.directory == folder && !$0.state.isFinished }.map(\.fileName)).union(alsoTaken)
        guard ignoringFinished else { return FileNaming.unique(name, in: folder, taken: taken) }
        // Only check names claimed by other unfinished downloads and their partial files, not finished files on disk.
        let partial = folder.appending(path: name + DownloadItem.partialSuffix)
        return taken.contains(name) || FileManager.default.fileExists(atPath: partial.path) ? FileNaming.unique(name, in: folder, taken: taken) : name
    }

    // MARK: Control

    func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].state.isActive else { return }
        items[index].state = .connecting
        // Still loading its files: it starts as soon as they arrive.
        guard preparing[id] == nil else { return markDirty() }
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
        case .media:
            items[index].mediaPhase = nil
            items[index].mediaError = nil
            // At launch the tools are still being looked up: wait in the queue, ToolManager schedules again after.
            guard ToolManager.shared.refreshed else {
                items[index].state = .queued
                return markDirty()
            }
            guard let tools = ToolManager.shared.paths else {
                items[index].state = .failed("Video tools aren't installed. Open Video Tools to install them.")
                return markDirty()
            }
            let limit = MediaCommand.limit(global: settings.effectiveSpeedLimit, itemKB: item.speedLimitKB)
            let cookies = MediaCookies.choose(browser: settings.mediaCookieBrowser, jar: item.cookieJar)
            MediaJobs.shared.start(item, tools: tools, limit: limit, cookies: cookies) { id, event in
                DownloadStore.shared.handleMedia(id, event)
            }
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
                if let hash = FileNaming.magnetHash(item.url) {
                    await Aria2.shared.removeOrphans(infoHash: hash, keeping: liveGIDs)
                }
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
        bumpCleanupRevision()
        markDirty()
        if torrentFile == nil { adoptSavedMetadata(for: item.id) }
        if startNow {
            startOrQueue(item.id, respectSchedule: true)
        } else {
            mutate(item.id) { $0.state = .queued; $0.queuedAt = Date() }
            schedule()
        }
    }

    /// Adds a torrent whose files are still loading in the New Download window, so adding doesn't wait for them.
    /// It shows in the list right away and picks up the files, then starts, when they arrive.
    func addPreparingTorrent(_ task: Task<PreparedTorrent, Error>, source: URL, name: String, directory: URL,
                             priority: Priority, startNow: Bool) {
        var item = DownloadItem(url: source, fileName: FileNaming.sanitize(name), directory: directory,
                                category: FileCategory.detect(fileName: name), kind: .torrent)
        item.priority = priority == .normal ? nil : priority
        let id = item.id
        preparing[id] = task
        items.insert(item, at: 0)
        bumpCleanupRevision()
        markDirty()
        if startNow { startOrQueue(id, respectSchedule: true) } else { queue([id]) }

        Task {
            let result = await task.result
            preparing[id] = nil
            switch result {
            case .success(let prepared):
                guard let current = self.item(id) else {
                    // Removed from the list while loading.
                    await Aria2.shared.remove(prepared.gid)
                    if let file = prepared.torrentFile { try? FileManager.default.removeItem(at: file) }
                    return
                }
                liveGIDs.insert(prepared.gid)
                if prepared.directory != current.directory {
                    await Aria2.shared.setDirectory(prepared.gid, to: current.directory)
                }
                mutate(id) {
                    $0.torrentGID = prepared.gid
                    $0.torrentFile = prepared.torrentFile
                    $0.files = prepared.files
                    $0.fileName = FileNaming.sanitize(prepared.name)
                    $0.category = FileCategory.detect(fileName: prepared.name)
                    $0.totalBytes = prepared.files.filter(\.included).reduce(0) { $0 + $1.length }
                }
                if prepared.torrentFile == nil { adoptSavedMetadata(for: id) }
                if self.item(id)?.state == .connecting {
                    mutate(id) { $0.state = .paused }
                    start(id)
                }
            case .failure(let error):
                guard !(error is CancellationError), let current = self.item(id), current.state.isActive else { return }
                mutate(id) { $0.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
                schedule()
            }
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
        // Merging or converting: freeze it so Resume continues where it stopped (stopping would start it over).
        let frozen = item.kind == .media && item.mediaPhase != nil && MediaJobs.shared.suspend(id)
        if item.kind == .media, !frozen {
            MediaJobs.shared.stop(id) { DownloadStore.shared.schedule() }
        }
        if item.state.isActive || item.state == .queued {
            mutate(id) {
                $0.state = .paused
                $0.speed = 0
                $0.connections = 0
                if !frozen { $0.mediaPhase = nil }
            }
        }
        schedule()
    }

    func resume(_ id: UUID) {
        guard let item = item(id), !item.state.isActive, !item.state.isFinished else { return }
        if item.kind == .media, MediaJobs.shared.resumeSuspended(id) {
            mutate(id) { $0.state = .downloading }
            return
        }
        startOrQueue(id)
    }

    /// Starts now if there's a free slot under "Simultaneous downloads", otherwise joins the back of the queue.
    /// `respectSchedule`: a new download waits for the download window; resuming one by hand doesn't.
    /// `keepQueuedAt`: its place in the line was already set (playlists keep their order).
    private func startOrQueue(_ id: UUID, respectSchedule: Bool = false, keepQueuedAt: Bool = false) {
        if busySlots < settings.maxConcurrent, !respectSchedule || queueRuns {
            start(id)
        } else {
            mutate(id) {
                $0.state = .queued
                if !keepQueuedAt || $0.queuedAt == nil { $0.queuedAt = Date() }
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
        let ids = CleanupRules.unlocked(ids, in: items)
        for id in ids {
            guard let item = item(id) else { continue }
            engines.removeValue(forKey: id)?.pause()
            preparing.removeValue(forKey: id)?.cancel()
            let trash = {
                let fm = FileManager.default
                let candidates = [item.destination, item.partialFile,
                                  item.directory.appending(path: item.fileName + ".aria2")]
                for url in candidates where fm.fileExists(atPath: url.path) {
                    try? fm.trashItem(at: url, resultingItemURL: nil)
                }
            }
            // Unfinished media: stop yt-dlp, wait for it, then delete its working folder (both remove variants).
            let unfinishedMedia = item.kind == .media && !item.state.isFinished
            if item.kind == .media { MediaJobs.shared.discard(id) }
            if item.kind == .torrent, let gid = item.torrentGID {
                liveGIDs.remove(gid)
                // Stop aria2 first: it rewrites its .aria2 progress file while shutting a torrent down.
                Task {
                    await Aria2.shared.remove(gid)
                    if deleteFiles { trash() }
                }
            } else if deleteFiles, !unfinishedMedia {
                trash()
            }
            if !deleteFiles, !item.state.isFinished, item.kind == .http {
                try? FileManager.default.removeItem(at: item.partialFile)
            }
            if let file = item.torrentFile { try? FileManager.default.removeItem(at: file) }
        }
        items.removeAll { ids.contains($0.id) }
        markDirty()
        bumpCleanupRevision()
        schedule()
    }

    /// Removes finished downloads from the list without touching their files.
    func removeEntries(_ ids: Set<UUID>) {
        let finished = CleanupRules.unlocked(ids, in: items).filter { item($0)?.state.isFinished == true }
        guard !finished.isEmpty else { return }
        remove(finished, deleteFiles: false)
    }

    /// Keep: never suggested in Cleanup and never archived.
    func setKeep(_ ids: Set<UUID>, _ keep: Bool) {
        for id in CleanupRules.unlocked(ids, in: items) { mutate(id) { $0.keep = keep ? true : nil } }
        bumpCleanupRevision()
    }

    /// The downloads Move applies to: finished, not locked by a pending cleanup move, and not already in `folder`.
    nonisolated static func movable(_ ids: Set<UUID>, in items: [DownloadItem], to folder: URL) -> [UUID] {
        let unlocked = CleanupRules.unlocked(ids, in: items)
        return items.filter {
            unlocked.contains($0.id) && $0.state.isFinished
                // Compare paths: a folder from the Open panel ends in "/", a saved one doesn't.
                && $0.directory.standardizedFileURL.path != folder.standardizedFileURL.path
        }.map(\.id)
    }

    /// Moves finished downloads to another folder. Unfinished ones (downloading, converting, paused, queued,
    /// failed) are skipped and stay where they are.
    func move(_ ids: Set<UUID>, to folder: URL) {
        let fm = FileManager.default
        var failed: [String] = []
        defer { bumpCleanupRevision() }
        for id in Self.movable(ids, in: items, to: folder) {
            guard let item = item(id) else { continue }
            let name = FileNaming.unique(item.fileName, in: folder)
            do {
                if fm.fileExists(atPath: item.destination.path) {
                    try fm.moveItem(at: item.destination, to: folder.appending(path: name))
                }
                mutate(id) {
                    $0.directory = folder
                    $0.fileName = name
                }
            } catch {
                failed.append(item.fileName)
            }
        }
        if !failed.isEmpty {
            alert = "Couldn't move: \(failed.joined(separator: ", "))."
        }
    }

    /// What Start Over does for this download, or nil when it doesn't apply (torrents, running, being moved).
    nonisolated static func startOverKind(_ item: DownloadItem) -> StartOverKind? {
        guard item.kind != .torrent, item.pendingMove == nil else { return nil }
        switch item.state {
        case .completed: return .downloadAgain
        case .failed, .paused: return .startOver
        case .queued, .connecting, .downloading: return nil
        }
    }

    enum StartOverKind: Sendable {
        /// Unfinished: throw away what was downloaded and begin again from zero.
        case startOver
        /// Finished: a fresh copy as a new download, leaving the existing file alone.
        case downloadAgain
    }

    /// Start Over (unfinished) or Download Again (finished); see `StartOverKind`.
    func startOver(_ id: UUID) {
        guard let item = item(id), let kind = Self.startOverKind(item) else { return }
        switch kind {
        case .downloadAgain:
            if item.kind == .media {
                addMedia(item.url, name: MediaNaming.stem((item.fileName as NSString).deletingPathExtension),
                         directory: item.directory, quality: item.mediaQuality ?? .best, info: item.mediaInfo,
                         convertHeight: item.mediaConvertHeight, playableOnly: item.mediaPlayableOnly == true,
                         subtitle: item.mediaSubtitle, cookieJar: item.cookieJar ?? [], startNow: true, openWhenDone: false)
            } else {
                _ = add(item.url.absoluteString, fileName: item.fileName, directory: item.directory, headers: item.headers)
            }
        case .startOver:
            autoRetried.remove(id)
            mutate(id) {
                $0.state = .paused
                $0.receivedBytes = 0
                $0.segments = []
                $0.validator = nil
                $0.speed = 0
                $0.mediaPhase = nil
                $0.mediaError = nil
                $0.failedAt = nil
            }
            if item.kind == .media {
                // Stops anything still running (a frozen conversion), deletes the working folder, then starts.
                MediaJobs.shared.discard(id) { DownloadStore.shared.startOrQueue(id) }
            } else {
                try? FileManager.default.removeItem(at: item.partialFile)
                startOrQueue(id)
            }
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
        guard let item = item(id), item.state.isFinished, item.pendingMove == nil else { return }
        NSWorkspace.shared.open(item.destination)
        mutate(id) { $0.openedAt = Date() }
        bumpCleanupRevision()
    }

    func applySpeedLimit() {
        let bytes = settings.effectiveSpeedLimit
        RateLimiter.shared.limit = bytes
        Task { await Aria2.shared.setSpeedLimit(bytes) }
    }

    /// Sends the seeding settings to aria2 for new and running torrents.
    func applySeeding() {
        let live = items.filter { $0.kind == .torrent && ($0.state.isActive || $0.seeding == true) }.compactMap(\.torrentGID)
        let (enabled, ratio, upload) = (settings.seedTorrents, settings.seedRatio, settings.uploadLimitKB < 0 ? 1 : Int64(settings.uploadLimitKB) * 1000)
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
        bumpCleanupRevision()
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
            bumpCleanupRevision()
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

    // MARK: Media events

    private func handleMedia(_ id: UUID, _ event: MediaEvent) {
        guard let item = item(id), item.state.isActive else { return }
        switch event {
        case .progress(let received, let total, let speed):
            mutate(id, dirty: false) {
                if $0.state == .connecting { $0.state = .downloading }
                $0.receivedBytes = received
                if let total { $0.totalBytes = total }
                $0.speed = speed
                $0.mediaPhase = nil
            }
        case .phase(let phase):
            mutate(id, dirty: false) {
                $0.state = .downloading
                $0.mediaPhase = phase
                $0.speed = 0
            }
        case .title(let title):
            renameFromSite(id, title: title)
        case .finished(let path):
            mutate(id, dirty: false) {
                if $0.mediaPhase == nil { $0.mediaPhase = .processing }
                $0.speed = 0
            }
            let taken = Set(items.filter { $0.id != id && $0.directory == item.directory && !$0.state.isFinished }.map(\.fileName))
            let work = MediaJobs.workDirectory(for: id)
            let (stem, folder) = ((item.fileName as NSString).deletingPathExtension, item.directory)
            Task.detached(priority: .userInitiated) {
                let result = Result { try MediaFinisher.finish(printedPath: path, workDirectory: work, stem: stem, into: folder, taken: taken) }
                await MainActor.run { DownloadStore.shared.finishMedia(id, result) }
            }
        case .failed(let message):
            let kind = MediaErrors.kind(of: message)
            let plain = MediaErrors.friendly(message)
            // A bot check or dropped connection is often gone a little later: try once more by itself.
            let retrying = kind.retryable && !autoRetried.contains(id)
            if retrying { autoRetried.insert(id) }
            mutate(id) {
                $0.state = .failed(retrying ? plain + " Trying again in 30 seconds." : plain)
                $0.mediaError = plain == message ? nil : message
                $0.failedAt = Date()
                $0.speed = 0
                $0.mediaPhase = nil
            }
            if retrying {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.mediaRetryDelay))
                    guard let current = DownloadStore.shared.item(id), current.state.isFailed else { return }
                    DownloadStore.shared.retry(id)
                }
            } else {
                notify(title: "Download failed", body: "\(item.fileName): \(plain)")
            }
            schedule()
        }
    }

    /// A playlist entry the site listed without a title ("01 Video 1.mp4") takes the real one, keeping its number.
    private func renameFromSite(_ id: UUID, title: String) {
        guard let item = item(id), item.nameFromServer == true else { return }
        let name = item.fileName as NSString
        let stem = name.deletingPathExtension
        let placeholder = item.mediaInfo?.title ?? ""
        let prefix = !placeholder.isEmpty && stem.hasSuffix(placeholder) ? String(stem.dropLast(placeholder.count)) : ""
        let clean = MediaNaming.stem(FileNaming.sanitize(title))
        guard !clean.isEmpty else { return }
        let renamed = uniqueName("\(prefix)\(clean).\(name.pathExtension)", in: item.directory)
        mutate(id) {
            $0.fileName = renamed
            $0.mediaInfo?.title = title
            $0.nameFromServer = nil
        }
    }

    private func finishMedia(_ id: UUID, _ result: Result<String, Error>) {
        guard let item = item(id) else { return }
        switch result {
        case .success(let name):
            let size = (try? FileManager.default.attributesOfItem(atPath: item.directory.appending(path: name).path))?[.size] as? NSNumber
            mutate(id) {
                $0.fileName = name
                $0.mediaPhase = nil
                if let size = size?.int64Value {
                    $0.totalBytes = size
                    $0.receivedBytes = size
                }
            }
            complete(id)
        case .failure(let error):
            mutate(id) {
                $0.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                $0.mediaPhase = nil
            }
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
        bumpCleanupRevision()
        recordStamp(of: item)
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

    /// Starts queued downloads while there are free slots (and, with a schedule, inside the download window).
    func schedule() {
        guard queueRuns else { return }
        var active = busySlots
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

    // MARK: Download window

    /// "Start Now" on the schedule note lets the queue run until the window next opens. Not saved.
    private(set) var scheduleBypassUntil: Date?
    /// Whether the window was open at the last tick; nil until the first one (and while there is no schedule).
    private var windowWasOpen: Bool?

    /// Whether queued downloads may start now.
    var queueRuns: Bool { Self.queueRuns(at: Date(), enabled: settings.scheduleEnabled, window: settings.downloadWindow,
                                         bypassUntil: scheduleBypassUntil) }

    nonisolated static func queueRuns(at date: Date, enabled: Bool, window: DownloadWindow, bypassUntil: Date?,
                                      calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        if let bypassUntil, date < bypassUntil { return true }
        return window.contains(date, calendar: calendar)
    }

    /// When the queue next starts on its own; nil when it isn't waiting for the window.
    var queueStartsAt: Date? {
        queueRuns ? nil : settings.downloadWindow.nextStart(after: Date())
    }

    /// Runs the queue now instead of waiting for the window.
    func startQueueNow() {
        scheduleBypassUntil = settings.downloadWindow.nextStart(after: Date())
        windowWasOpen = true
        schedule()
    }

    /// The schedule was switched on or off, or its hours changed.
    func scheduleChanged() {
        scheduleBypassUntil = nil
        windowWasOpen = settings.scheduleEnabled ? queueRuns : nil
        schedule()
    }

    /// Each tick: start the queue when the window opens; when it closes, put running downloads back in the queue so
    /// they carry on in the next window.
    private func followDownloadWindow() {
        guard settings.scheduleEnabled else {
            windowWasOpen = nil
            return
        }
        let open = queueRuns
        defer { windowWasOpen = open }
        guard let was = windowWasOpen, was != open else { return }
        if open {
            schedule()
        } else {
            for item in items where item.state.isActive {
                pause(item.id)
                mutate(item.id) { $0.state = .queued }
            }
        }
    }

    // MARK: Ticking

    private func update() {
        followDownloadWindow()
        Power.keepAwake(settings.keepAwake && activeCount > 0)
        let idle = engines.isEmpty && !items.contains { $0.kind != .http && $0.state.isActive }
        // Nothing downloading and the speed graph already flat: leave the observed values alone so idle
        // windows don't re-render twice a second.
        if idle, totalSpeed == 0, speedHistory.allSatisfy({ $0 == 0 }) {
            pollTorrents()
            ticksSinceSave += 1
            if tracker.isDirty, ticksSinceSave >= 4 { save() }
            return
        }
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
        total += items.filter { $0.kind != .http && $0.state.isActive }.reduce(0) { $0 + $1.speed }
        totalSpeed = total
        speedHistory.append(total)
        if speedHistory.count > Self.historyLength { speedHistory.removeFirst(speedHistory.count - Self.historyLength) }

        pollTorrents()

        ticksSinceSave += 1
        if tracker.isDirty, ticksSinceSave >= 4 { save() }
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
                bumpCleanupRevision()
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
        tracker.changed()
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
        guard let item = item(id), item.torrentFile == nil, let hash = FileNaming.magnetHash(item.url) else { return }
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

    // MARK: Cleanup hooks

    func bumpCleanupRevision() {
        cleanupRevision += 1
        cleanupObserver?()
    }

    /// Applies a cleanup result to one item (baseline stamps, inspections, pending moves, archive, restore).
    func cleanupMutate(_ id: UUID, bump: Bool = true, _ change: (inout DownloadItem) -> Void) {
        mutate(id, change)
        if bump { bumpCleanupRevision() }
    }

    /// Records the finished file's identity, read off the main actor. Replaces a baseline but never a real stamp.
    private func recordStamp(of item: DownloadItem) {
        let (id, destination) = (item.id, item.destination)
        Task.detached(priority: .utility) {
            guard let stamp = FileStamp.read(destination) else { return }
            await MainActor.run {
                let store = DownloadStore.shared
                guard let current = store.item(id), current.destination == destination,
                      current.stamp == nil || current.stampIsBaseline == true else { return }
                store.cleanupMutate(id) {
                    $0.stamp = stamp
                    $0.stampIsBaseline = nil
                }
            }
        }
    }

    // MARK: Persistence

    private func mutate(_ id: UUID, dirty markDirty: Bool = true, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        if markDirty { tracker.changed() }
    }

    private func markDirty() { tracker.changed() }

    /// Reads the saved list one item at a time, so a single unreadable entry can't wipe the rest. If the file
    /// can't be read at all it is kept aside (never overwritten) and a backup of every good load is kept too.
    private func load() {
        let url = AppPaths.library
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        var loaded: [DownloadItem] = []
        var skipped = 0
        if let all = try? decoder.decode([DownloadItem].self, from: data) {
            // The usual case: one pass over the whole library.
            loaded = all
        } else {
            // Something in it doesn't decode: keep every item that does.
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                preserveUnreadable(url)
                return
            }
            for entry in raw {
                guard let itemData = try? JSONSerialization.data(withJSONObject: entry),
                      let item = try? decoder.decode(DownloadItem.self, from: itemData) else {
                    skipped += 1
                    continue
                }
                loaded.append(item)
            }
        }
        for index in loaded.indices {
            if loaded[index].state.isActive { loaded[index].state = .queued }
            loaded[index].seeding = nil
        }
        if skipped > 0 { preserveUnreadable(url) }
        items = loaded
        // The backup is written off the main thread, from the bytes already read.
        let backup = AppPaths.libraryBackup
        Task.detached(priority: .utility) { try? data.write(to: backup, options: .atomic) }
    }

    private func preserveUnreadable(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().appending(path: "downloads-unreadable-\(stamp).json"))
    }

    /// Encodes now and writes in order on the library writer; the store stays dirty until a write lands.
    func save() {
        ticksSinceSave = 0
        guard let data = try? JSONEncoder().encode(items) else { return }
        let save = tracker.beginSave()
        writer.enqueue(data, seq: save.seq) { ok in
            Task { @MainActor in DownloadStore.shared.tracker.finished(save, success: ok) }
        }
    }

    /// Like `save()`, but waits for the write and throws if it failed.
    func saveNow() async throws {
        ticksSinceSave = 0
        let data = try JSONEncoder().encode(items)
        let save = tracker.beginSave()
        let writer = writer
        let ok = await withCheckedContinuation { continuation in
            writer.enqueue(data, seq: save.seq) { continuation.resume(returning: $0) }
        }
        tracker.finished(save, success: ok)
        if !ok { throw CocoaError(.fileWriteUnknown) }
    }

    /// Called on quit: stop engines so partial progress is captured, then save synchronously.
    func shutdown() {
        for (id, engine) in engines {
            engine.pause()
            apply(engine.snapshot(), to: id)
            mutate(id) { $0.state = .queued }
        }
        engines.removeAll()
        MediaJobs.shared.shutdown()
        for item in items where item.kind == .media && item.state.isActive {
            mutate(item.id) { $0.state = .queued }
        }
        // Drains queued writes first, so the newest state is the last one on disk.
        if let data = try? JSONEncoder().encode(items) {
            _ = writer.writeNowSync(data, seq: tracker.beginSave().seq)
        }
        Task { await Aria2.shared.shutdown() }
    }

    private func notify(title: String, body: String) {
        guard settings.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        guard askedForNotifications else {
            // Asked the first time there's something to say, not at launch (where it covers the window).
            askedForNotifications = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { center.add(request) }
            }
            return
        }
        center.add(request)
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
