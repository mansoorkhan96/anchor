import AppKit
import Observation

/// The video tools: what is installed, installs and updates (only ever on the user's request), update checks,
/// and whether the Video Tools slide-over is open.
@MainActor @Observable
final class ToolManager {
    static let shared = ToolManager()

    enum Activity: Equatable {
        case downloading(received: Int64, total: Int64?)
        case verifying
        case installing
        case failed(String)

        var isBusy: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    /// Installed or found tools, from tools.json and discovery.
    private(set) var records: [ToolID: ToolRecord] = [:]
    /// Installs in progress or failed; absent means idle.
    private(set) var activity: [ToolID: Activity] = [:]
    /// The newest release seen by the update check, for managed tools.
    private(set) var latest: [ToolID: String] = [:]
    /// The first look at tools.json and the system folders has finished.
    private(set) var refreshed = false
    /// Bytes used by Anchor's own copies.
    private(set) var diskUsage: Int64 = 0
    var panelOpen = false
    /// The slide-over was opened because a video download is waiting for the tools.
    var waitingForVideo = false

    private var started = false
    private var refreshTask: Task<Void, Never>?
    private var installs: [ToolID: Task<Void, Never>] = [:]
    private var updateLoop: Task<Void, Never>?

    private init() {}

    // MARK: State

    var isReady: Bool { ToolID.allCases.allSatisfy { records[$0] != nil } }
    var missing: [ToolID] { ToolID.allCases.filter { records[$0] == nil } }
    var isInstalling: Bool { activity.values.contains(where: \.isBusy) }

    func hasUpdate(_ tool: ToolID) -> Bool {
        guard let record = records[tool], record.source == .managed, let newest = latest[tool] else { return false }
        return newest != record.version
    }

    var hasUpdates: Bool { ToolID.allCases.contains(where: hasUpdate) }

    /// Paths for a yt-dlp run, once every tool is available.
    var paths: MediaToolPaths? {
        guard let ytdlp = records[.ytdlp], let ffmpeg = records[.ffmpeg], let js = records[.deno] else { return nil }
        return MediaToolPaths(ytdlp: ytdlp.url, ffmpegDirectory: ffmpeg.url.deletingLastPathComponent(),
                              jsRuntime: js.runtime ?? "deno", jsRuntimePath: js.url, toolsDirectory: Self.folder)
    }

    static var folder: URL { AppPaths.tools }
    private static var manifestURL: URL { folder.appending(path: "tools.json") }

    /// Tests run inside the app; they must never read or write the real Tools folder or reach the network.
    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    // MARK: Lifecycle

    /// Reads tools.json, looks for system copies, and starts the update checks (30 s after launch, then daily).
    func start() {
        guard !started, !Self.isTesting else { return }
        started = true
        refreshTask = Task { await refresh() }
        updateLoop = Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await checkForUpdates()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    private func refresh() async {
        var manifest = ToolManifest.load(from: Self.manifestURL)
        let original = manifest
        for tool in ToolID.allCases {
            guard let record = manifest[tool] else { continue }
            // System copies are looked for again each launch; managed ones must still be there.
            let present = ToolDiscovery.isExecutable(record.url)
                && (tool != .ffmpeg || ToolDiscovery.isExecutable(record.url.deletingLastPathComponent().appending(path: "ffprobe")))
            if record.source == .system || !present { manifest[tool] = nil }
        }
        let directories = ToolDiscovery.searchDirectories()
        if manifest[.ffmpeg] == nil, let found = await ToolDiscovery.findFFmpeg(in: directories) {
            manifest[.ffmpeg] = ToolRecord(version: found.version, source: .system, path: found.path.path, installedAt: Date(),
                                           sha256: nil, runtime: nil)
        }
        if manifest[.deno] == nil, let found = await ToolDiscovery.findJSRuntime(in: directories) {
            manifest[.deno] = ToolRecord(version: found.version, source: .system, path: found.path.path, installedAt: Date(),
                                         sha256: nil, runtime: found.name)
        }
        records = Dictionary(uniqueKeysWithValues: ToolID.allCases.compactMap { tool in manifest[tool].map { (tool, $0) } })
        if manifest != original { try? manifest.save(to: Self.manifestURL) }
        refreshed = true
        if isReady { waitingForVideo = false }
        updateDiskUsage()
        // Media downloads queued at launch were waiting for this.
        DownloadStore.shared.schedule()
    }

    // MARK: Installing

    /// Installs every tool that isn't available yet.
    func installAll() {
        Task {
            await refreshTask?.value
            for tool in missing { install(tool) }
        }
    }

    /// Installs (or, for a managed tool, updates to) the newest release. The current copy stays until the new one
    /// is verified and in place.
    func install(_ tool: ToolID) {
        guard installs[tool] == nil, records[tool]?.source != .system else { return }
        activity[tool] = .downloading(received: 0, total: nil)
        installs[tool] = Task {
            defer { installs[tool] = nil }
            do {
                let release = try await ToolSources.latestRelease(tool)
                let record = try await ToolInstaller.install(release, into: Self.folder) { phase in
                    Task { @MainActor in ToolManager.shared.report(phase, for: tool) }
                }
                records[tool] = record
                latest[tool] = release.version
                activity[tool] = nil
                saveManifest()
                updateDiskUsage()
                if isReady {
                    waitingForVideo = false
                    DownloadStore.shared.schedule()
                }
            } catch is CancellationError {
                activity[tool] = nil
            } catch {
                activity[tool] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func report(_ phase: ToolInstallPhase, for tool: ToolID) {
        // Late reports from a finished install are dropped.
        guard installs[tool] != nil else { return }
        switch phase {
        case .downloading(let received, let total): activity[tool] = .downloading(received: received, total: total)
        case .verifying: activity[tool] = .verifying
        case .installing: activity[tool] = .installing
        }
    }

    /// A media link was opened in the New Download window: that is the user's go-ahead to install what's missing.
    /// A video link needs the tools: shows the panel explaining why. Nothing downloads until the user clicks
    /// Install all (here or in the New Download window).
    func requestForVideo() {
        Task {
            await refreshTask?.value
            guard !isReady else { return }
            waitingForVideo = true
            openPanel()
        }
    }

    private func saveManifest() {
        var manifest = ToolManifest()
        for (tool, record) in records { manifest[tool] = record }
        try? manifest.save(to: Self.manifestURL)
    }

    // MARK: Updates

    /// Looks up the newest release of each managed tool. Failures are silent and retried next time.
    func checkForUpdates() async {
        for tool in ToolID.allCases where records[tool]?.source == .managed {
            if let release = try? await ToolSources.latestRelease(tool) { latest[tool] = release.version }
        }
    }

    // MARK: Panel

    func openPanel() {
        DownloadStore.shared.focusedID = nil
        panelOpen = true
    }

    func togglePanel() {
        if panelOpen {
            panelOpen = false
            waitingForVideo = false
        } else {
            openPanel()
        }
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.folder])
    }

    private func updateDiskUsage() {
        let folder = Self.folder
        let managed = records.values.filter { $0.source == .managed }.isEmpty == false
        guard managed else {
            diskUsage = 0
            return
        }
        Task.detached(priority: .utility) {
            let size = Self.size(of: folder)
            await MainActor.run { ToolManager.shared.diskUsage = size }
        }
    }

    nonisolated private static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
