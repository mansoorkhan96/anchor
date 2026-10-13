import Foundation

/// Numbers each run of a download, so output from a run that was stopped or replaced is ignored.
struct GenerationGate: Sendable {
    private(set) var current = 0

    mutating func next() -> Int {
        current += 1
        return current
    }

    func accepts(_ generation: Int) -> Bool { generation == current }
}

/// One child process with line-by-line output from stdout and stderr. `onFinish` runs once, after the process has
/// exited *and* both pipes are drained, so the last printed line is never lost. Thread-safe.
final class MediaProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var exited = false
    private var suspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let onLine: @Sendable (String) -> Void
    private let onFinish: @Sendable (Int32) -> Void

    init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil,
         onLine: @escaping @Sendable (String) -> Void, onFinish: @escaping @Sendable (Int32) -> Void) {
        self.onLine = onLine
        self.onFinish = onFinish
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { lock.withLock { !exited } && process.isRunning }

    func start() throws {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        for pipe in [out, err] {
            finished.enter()
            let reader = LineReader { [onLine] in onLine($0) }
            pipe.fileHandleForReading.readabilityHandler = { [finished] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    reader.finish()
                    finished.leave()
                } else {
                    reader.feed(data)
                }
            }
        }
        finished.enter()
        process.terminationHandler = { [weak self, finished] _ in
            self?.markExited()
            finished.leave()
        }
        do {
            try process.run()
        } catch {
            for pipe in [out, err] {
                pipe.fileHandleForReading.readabilityHandler = nil
                finished.leave()
            }
            finished.leave()
            markExited()
            throw error
        }
        finished.notify(queue: .global(qos: .utility)) { [process, onFinish] in
            onFinish(process.terminationStatus)
        }
    }

    /// SIGTERM, then SIGKILL if it is still running after `grace` seconds; returns once the process has exited.
    /// Freezes the process and everything it started (yt-dlp hands merging to an ffmpeg child), so the work
    /// continues from the same point on `resume()`.
    func suspend() {
        guard lock.withLock({ !exited }), process.processIdentifier > 0 else { return }
        signalTree(SIGSTOP)
        lock.withLock { suspended = true }
    }

    func resume() {
        guard lock.withLock({ suspended }) else { return }
        signalTree(SIGCONT)
        lock.withLock { suspended = false }
    }

    var isSuspended: Bool { lock.withLock { suspended && !exited } }

    /// Sends `signal` to the process and all its descendants, parent first so it can't start new children meanwhile.
    private func signalTree(_ signal: Int32) {
        var pending = [process.processIdentifier]
        while let pid = pending.popLast() {
            kill(pid, signal)
            var children = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            if count > 0 { pending += children.prefix(Int(count)).filter { $0 > 0 } }
        }
    }

    func terminate(grace: TimeInterval = 5) async {
        guard lock.withLock({ !exited }), process.processIdentifier > 0 else { return }
        let pid = process.processIdentifier
        // A stopped process can't act on SIGTERM.
        resume()
        kill(pid, SIGTERM)
        let escalation = DispatchWorkItem { [weak self] in
            guard let self, self.lock.withLock({ !self.exited }) else { return }
            kill(pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace, execute: escalation)
        await waitForExit()
        escalation.cancel()
    }

    /// For quitting, where nothing can be awaited: SIGTERM, a short wait, then SIGKILL.
    func terminateBlocking(grace: TimeInterval) {
        guard lock.withLock({ !exited }), process.processIdentifier > 0 else { return }
        let pid = process.processIdentifier
        resume()
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while lock.withLock({ !exited }), Date() < deadline { usleep(50_000) }
        if lock.withLock({ !exited }) { kill(pid, SIGKILL) }
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if exited { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func markExited() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            exited = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// Splits a byte stream into lines (on \n or \r).
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let emit: (String) -> Void

    init(emit: @escaping (String) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        let lines = lock.withLock { () -> [String] in
            buffer.append(data)
            var lines: [String] = []
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
            return lines
        }
        lines.forEach(emit)
    }

    func finish() {
        let rest = lock.withLock { () -> String? in
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
        if let rest { emit(rest) }
    }
}
