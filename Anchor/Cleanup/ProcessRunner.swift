import Foundation

/// Runs a command line tool off the main actor with stdin set to /dev/null (so nothing can wait for input,
/// like a license prompt) and a hard timeout.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var data: Data
        var timedOut: Bool
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path, arguments, timeout: timeout))
            }
        }
    }

    /// Process is not Sendable; it is shared with the timeout handler only through this box.
    private final class Running: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var expired = false

        init(_ process: Process) { self.process = process }

        var timedOut: Bool { lock.withLock { expired } }

        func expire() {
            guard process.isRunning else { return }
            lock.withLock { expired = true }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private static func runBlocking(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return Output(status: -1, data: Data(), timedOut: false)
        }
        let running = Running(process)
        let deadline = DispatchWorkItem { running.expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let timedOut = running.timedOut
        return Output(status: timedOut ? -1 : process.terminationStatus, data: data, timedOut: timedOut)
    }
}
