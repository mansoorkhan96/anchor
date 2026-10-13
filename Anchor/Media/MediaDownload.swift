import Foundation

/// What a yt-dlp run reports to the store.
enum MediaEvent: Sendable {
    case progress(received: Int64, total: Int64?, speed: Double)
    case phase(MediaPhase)
    /// yt-dlp (and the conversion, if any) finished with this file.
    case finished(String)
    case failed(String)
}

/// One media download. It owns at most one yt-dlp process at a time; every start or stop begins a new generation,
/// and output from older generations is ignored.
@MainActor
final class MediaDownload {
    let id: UUID
    private var gate = GenerationGate()
    private var process: MediaProcess?
    private var stopping: Task<Void, Never>?
    private var tracker = MediaProgressTracker()
    private var lastError: String?
    private var printedPath: String?
    private var conversion: MediaConversion?
    private var tools: MediaToolPaths?
    private var workDirectory: URL?
    private var conversionProgress = MediaConversionProgress(duration: nil)
    private var conversionErrors: [String] = []

    init(id: UUID) { self.id = id }

    func start(arguments: [String], conversion: MediaConversion? = nil, tools: MediaToolPaths, workDirectory: URL,
               onEvent: @escaping @MainActor (MediaEvent) -> Void) {
        // A frozen run must end before a new one starts.
        if process?.isSuspended == true { stop() }
        let generation = gate.next()
        let previous = stopping
        Task {
            // A resume never overlaps the run it replaces.
            await previous?.value
            guard gate.accepts(generation) else { return }
            tracker = MediaProgressTracker()
            lastError = nil
            printedPath = nil
            self.conversion = conversion
            self.tools = tools
            self.workDirectory = workDirectory
            do {
                try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                let process = MediaProcess(
                    executable: tools.ytdlp, arguments: arguments, environment: MediaCommand.environment(tools: tools),
                    currentDirectory: workDirectory,
                    onLine: { line in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(line, generation, onEvent) } }
                    },
                    onFinish: { status in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(status, generation, onEvent) } }
                    })
                self.process = process
                try process.start()
            } catch {
                process = nil
                onEvent(.failed("Couldn't start yt-dlp: \(error.localizedDescription)"))
            }
        }
    }

    /// Freezes the running merge or conversion; false when there is no process to freeze.
    func suspend() -> Bool {
        guard let process, process.isRunning else { return false }
        process.suspend()
        return true
    }

    /// Continues a frozen merge or conversion; false when nothing was frozen.
    func resumeSuspended() -> Bool {
        guard let process, process.isSuspended else { return false }
        process.resume()
        return true
    }

    /// Ends the current run (SIGTERM, then SIGKILL after 5 s). The returned task finishes once the process has exited.
    @discardableResult
    func stop() -> Task<Void, Never> {
        _ = gate.next()
        let process = process
        self.process = nil
        let previous = stopping
        let task = Task<Void, Never> {
            await previous?.value
            await process?.terminate()
        }
        stopping = task
        return task
    }

    /// Quitting: hands over the running process (if any) to be stopped without waiting on the main actor.
    func detachForQuit() -> MediaProcess? {
        _ = gate.next()
        defer { process = nil }
        return process
    }

    private func handle(_ line: String, _ generation: Int, _ onEvent: @MainActor (MediaEvent) -> Void) {
        guard gate.accepts(generation), let output = MediaOutput.parse(line) else { return }
        switch output {
        case .progress(let progress):
            let snapshot = tracker.update(progress)
            onEvent(.progress(received: snapshot.received, total: snapshot.total, speed: progress.speed ?? 0))
        case .processing(let phase):
            onEvent(.phase(phase))
        case .error(let message):
            lastError = message
        case .path(let path):
            printedPath = path
        }
    }

    private func finish(_ status: Int32, _ generation: Int, _ onEvent: @escaping @MainActor (MediaEvent) -> Void) {
        guard gate.accepts(generation) else { return }
        process = nil
        if status == 0, let printedPath {
            if var conversion, let tools, let workDirectory {
                // Sites like Instagram don't give a length; the file's own is exact, and the bitrate and percentage need it.
                onEvent(.phase(.converting(fraction: nil, eta: nil)))
                Task {
                    let ffprobe = tools.ffmpegDirectory.appending(path: "ffprobe")
                    if let measured = await MediaEncoder.duration(of: URL(filePath: printedPath), ffprobe: ffprobe, tools: tools) {
                        conversion.duration = measured
                    }
                    guard gate.accepts(generation) else { return }
                    convert(printedPath, conversion, tools: tools, workDirectory: workDirectory, generation, onEvent)
                }
            } else {
                onEvent(.finished(printedPath))
            }
        } else {
            onEvent(.failed(lastError ?? "yt-dlp stopped unexpectedly (code \(status))"))
        }
    }

    /// Re-encodes yt-dlp's file to an H.264 MP4 in the same working folder, reporting progress. Runs as the item's
    /// one process, so pausing or cancelling stops it like the download.
    private func convert(_ input: String, _ conversion: MediaConversion, tools: MediaToolPaths, workDirectory: URL,
                         _ generation: Int, _ onEvent: @escaping @MainActor (MediaEvent) -> Void) {
        let output = workDirectory.appending(path: MediaConversion.outputName)
        conversionProgress = MediaConversionProgress(duration: conversion.duration)
        conversionErrors = []
        onEvent(.phase(.converting(fraction: conversion.duration == nil ? nil : 0, eta: nil)))
        let process = MediaProcess(
            executable: tools.ffmpegDirectory.appending(path: "ffmpeg"),
            arguments: conversion.arguments(input: URL(filePath: input), output: output,
                                            sourceBytes: (try? FileManager.default.attributesOfItem(atPath: input)[.size] as? NSNumber)?.int64Value),
            environment: MediaCommand.environment(tools: tools), currentDirectory: workDirectory,
            onLine: { line in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.gate.accepts(generation) else { return }
                        if let update = self.conversionProgress.feed(line) {
                            onEvent(.phase(.converting(fraction: update.fraction, eta: update.eta)))
                        } else if !line.contains("=") {
                            self.conversionErrors.append(line)
                        }
                    }
                }
            },
            onFinish: { status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.gate.accepts(generation) else { return }
                        self.process = nil
                        if status == 0 {
                            try? FileManager.default.removeItem(atPath: input)
                            onEvent(.finished(output.path))
                        } else {
                            let reason = self.conversionErrors.last.map { ": \($0)" } ?? ""
                            onEvent(.failed("Couldn't convert the video to MP4\(reason)"))
                        }
                    }
                }
            })
        do {
            self.process = process
            try process.start()
        } catch {
            self.process = nil
            onEvent(.failed("Couldn't start ffmpeg: \(error.localizedDescription)"))
        }
    }
}

/// All media downloads, by item. Processes that are still shutting down keep their download slot.
@MainActor
final class MediaJobs {
    static let shared = MediaJobs()
    private var downloads: [UUID: MediaDownload] = [:]
    /// Items whose process has been told to stop but hasn't exited yet.
    private(set) var stopping: Set<UUID> = []

    static func workDirectory(for id: UUID) -> URL {
        AppPaths.mediaWork.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func start(_ item: DownloadItem, tools: MediaToolPaths, limit: Int64, onEvent: @escaping @MainActor (UUID, MediaEvent) -> Void) {
        let id = item.id
        let work = Self.workDirectory(for: id)
        let quality = item.mediaQuality ?? .best
        let conversion = quality.isAudio ? nil : item.mediaConvertHeight.map {
            MediaConversion(shortSide: $0, hardware: MediaEncoder.hasHardwareEncoder(ffmpegDirectory: tools.ffmpegDirectory),
                            duration: item.mediaInfo?.duration)
        }
        let arguments = MediaCommand.downloadArguments(url: item.url, quality: quality, convert: conversion != nil,
                                                       workDirectory: work, tools: tools, limitBytesPerSecond: limit)
        let download = downloads[id] ?? MediaDownload(id: id)
        downloads[id] = download
        download.start(arguments: arguments, conversion: conversion, tools: tools, workDirectory: work) { onEvent(id, $0) }
    }

    /// Pausing while merging or converting: freezes the work instead of stopping it.
    func suspend(_ id: UUID) -> Bool { downloads[id]?.suspend() ?? false }

    /// Resuming a frozen merge or conversion; false when the item has to start again.
    func resumeSuspended(_ id: UUID) -> Bool { downloads[id]?.resumeSuspended() ?? false }

    /// Stops the item's process; `then` runs after it has exited.
    func stop(_ id: UUID, then: (@MainActor () -> Void)? = nil) {
        guard let download = downloads[id] else {
            then?()
            return
        }
        stopping.insert(id)
        let task = download.stop()
        Task {
            await task.value
            stopping.remove(id)
            then?()
        }
    }

    /// Stops the process, waits for it, deletes the working folder and forgets the item.
    func discard(_ id: UUID) {
        stop(id) { [weak self] in
            try? FileManager.default.removeItem(at: Self.workDirectory(for: id))
            self?.downloads[id] = nil
        }
    }

    /// Quitting: SIGTERM every yt-dlp at once, wait up to 2 s, then SIGKILL what is left.
    func shutdown() {
        let processes = downloads.values.compactMap { $0.detachForQuit() }
        DispatchQueue.concurrentPerform(iterations: processes.count) { processes[$0].terminateBlocking(grace: 2) }
    }
}

enum MediaFinishError: LocalizedError {
    case outsideWorkFolder
    case missingFile
    case move(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkFolder: "yt-dlp reported a file outside Anchor's working folder"
        case .missingFile: "yt-dlp finished but the file is missing"
        case .move(let message): "Couldn't save the file: \(message)"
        }
    }
}

/// Moves a finished yt-dlp result into the download folder under the user's name.
enum MediaFinisher {
    /// Validates that `printedPath` is a regular file inside `workDirectory`, moves it to `folder` as
    /// `<stem>.<ext>` (made unique), deletes the working folder, and returns the final file name.
    static func finish(printedPath: String, workDirectory: URL, stem: String, into folder: URL, taken: Set<String>) throws -> String {
        let fm = FileManager.default
        let work = workDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let file = URL(filePath: printedPath).standardizedFileURL
        let resolved = file.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(work.hasSuffix("/") ? work : work + "/") else { throw MediaFinishError.outsideWorkFolder }
        guard let attributes = try? fm.attributesOfItem(atPath: file.path) else { throw MediaFinishError.missingFile }
        // A link inside the folder could point anywhere; only a plain file is accepted.
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw MediaFinishError.outsideWorkFolder }

        let ext = file.pathExtension.lowercased()
        let base = FileNaming.sanitize(stem.isEmpty ? "Video" : stem)
        let name = FileNaming.unique(ext.isEmpty ? base : "\(base).\(ext)", in: folder, taken: taken)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.moveItem(at: file, to: folder.appending(path: name))
        } catch {
            throw MediaFinishError.move(error.localizedDescription)
        }
        try? fm.removeItem(at: workDirectory)
        return name
    }
}
