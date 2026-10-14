import Foundation
import Darwin

struct DownloadSnapshot: Sendable {
    var segments: [Segment]
    var received: Int64
    var totalBytes: Int64?
    var supportsRanges: Bool
    var validator: String?
    var connections: Int
    /// Bytes written since the previous snapshot, for speed sampling.
    var delta: Int64
}

enum DownloadEvent: Sendable {
    case started
    case renamed(fileName: String)
    case completed(fileName: String)
    case failed(String)
}

/// One segmented HTTP(S) download. Each connection gets its own URLSession so requests are spread across
/// separate TCP connections instead of being multiplexed onto a single HTTP/2 connection.
final class HTTPDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxRetries = 6

    let id: UUID
    private let lock = NSLock()
    private let onEvent: @Sendable (DownloadEvent) -> Void
    private let maxConnections: Int
    private let delegateQueue: OperationQueue

    private var url: URL
    private var headers: [String: String]
    private var directory: URL
    private var fileName: String
    private var segments: [Segment]
    private var totalBytes: Int64?
    private var supportsRanges: Bool
    private var validator: String?

    private var sessions: [URLSession] = []
    private var freeSlots: [Int] = []
    private var tasks: [ObjectIdentifier: (task: URLSessionDataTask, segment: Int, slot: Int)] = [:]
    private var taskErrors: [ObjectIdentifier: Error] = [:]
    private var retries: [Int: Int] = [:]
    private var cooling: Set<Int> = []
    /// Lowered when the server pushes back (429/503) so we stop opening more connections than it allows; raised
    /// again by one every 30 s without pushback.
    private var connectionCap: Int
    private var lastPushback: ContinuousClock.Instant?
    /// How long a 429/503 asked us to wait (Retry-After), by task.
    private var retryAfter: [ObjectIdentifier: Double] = [:]
    /// A server answered a range request with the whole file: the download continues as one stream.
    private var rangesRejected = false
    private var fd: Int32 = -1
    private var stopped = false
    private var sampled: Int64 = 0
    private let adoptServerName: Bool
    /// Per-download cap, applied on top of the global limiter.
    private let ownLimiter = RateLimiter()
    private let overwrite: Bool

    init(item: DownloadItem, maxConnections: Int, onEvent: @escaping @Sendable (DownloadEvent) -> Void) {
        id = item.id
        url = item.url
        headers = item.headers
        directory = item.directory
        fileName = item.fileName
        segments = item.segments
        totalBytes = item.totalBytes
        supportsRanges = item.supportsRanges
        validator = item.validator
        adoptServerName = item.nameFromServer == true && item.segments.isEmpty
        ownLimiter.limit = Int64(item.speedLimitKB ?? 0) * 1000
        overwrite = item.overwrite == true
        self.maxConnections = max(1, maxConnections)
        connectionCap = max(1, maxConnections)
        self.onEvent = onEvent
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        super.init()
    }

    private var partialURL: URL { directory.appending(path: fileName + DownloadItem.partialSuffix) }
    private var busy: Set<Int> { Set(tasks.values.map(\.segment)).union(cooling) }

    // MARK: Lifecycle

    func start() {
        Task.detached(priority: .userInitiated) { [self] in
            do {
                try await prepare()
                lock.withLock {
                    guard !stopped else { return }
                    makeSessions()
                    fillSlots()
                }
                if lock.withLock({ !stopped }) { onEvent(.started) }
            } catch {
                fail(error)
            }
        }
    }

    func pause() {
        let toCancel: [URLSession] = lock.withLock {
            stopped = true
            tasks.values.forEach { $0.task.cancel() }
            tasks.removeAll()
            closeFile()
            defer { sessions.removeAll() }
            return sessions
        }
        toCancel.forEach { $0.invalidateAndCancel() }
    }

    /// Changes this download's own cap while it runs; 0 removes it.
    func setSpeedLimit(_ bytesPerSecond: Int64) {
        ownLimiter.limit = bytesPerSecond
    }

    func snapshot() -> DownloadSnapshot {
        lock.withLock {
            let received = SegmentPlanner.received(segments)
            defer { sampled = received }
            return DownloadSnapshot(segments: segments, received: received, totalBytes: totalBytes,
                                    supportsRanges: supportsRanges, validator: validator,
                                    connections: tasks.count, delta: max(0, received - sampled))
        }
    }

    private func prepare() async throws {
        var fresh = false
        let needsProbe = lock.withLock { segments.isEmpty }

        if needsProbe {
            let probe = try await Probe.run(url, headers: headers)
            lock.withLock {
                totalBytes = probe.totalBytes
                supportsRanges = probe.supportsRanges && probe.totalBytes != nil
                validator = probe.validator
                segments = Self.initialSegments(total: totalBytes, ranges: supportsRanges, connections: maxConnections)
                sampled = 0
            }
            if adoptServerName, probe.fileName != fileName {
                let name = FileNaming.unique(probe.fileName, in: directory)
                lock.withLock { fileName = name }
                onEvent(.renamed(fileName: name))
            }
            fresh = true
        } else if lock.withLock({ !supportsRanges }) {
            lock.withLock { segments = segments.map { Segment(start: $0.start, end: $0.end) } }
            fresh = true
        } else if let probe = try? await Probe.run(url, headers: headers) {
            let changed = lock.withLock {
                (validator != nil && probe.validator != nil && probe.validator != validator)
                    || (probe.totalBytes != nil && probe.totalBytes != totalBytes)
            }
            if changed {
                lock.withLock {
                    totalBytes = probe.totalBytes
                    validator = probe.validator
                    segments = Self.initialSegments(total: totalBytes, ranges: supportsRanges, connections: maxConnections)
                    sampled = 0
                }
                fresh = true
            }
        }

        try lock.withLock {
            guard !stopped else { return }
            if !FileManager.default.fileExists(atPath: partialURL.path) { fresh = true }
            fd = open(partialURL.path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { throw DownloadError.disk("Can't write to \(directory.path): \(String(cString: strerror(errno)))") }
            if fresh {
                ftruncate(fd, 0)
                segments = segments.map { Segment(start: $0.start, end: $0.end) }
                sampled = 0
                if let totalBytes, ftruncate(fd, off_t(totalBytes)) != 0 {
                    throw DownloadError.disk("Not enough disk space for \(Format.bytes(totalBytes))")
                }
            }
        }
    }

    static func initialSegments(total: Int64?, ranges: Bool, connections: Int) -> [Segment] {
        guard let total, total > 0 else { return [Segment(start: 0, end: Int64.max - 1)] }
        return ranges ? SegmentPlanner.plan(total: total, connections: connections) : [Segment(start: 0, end: total - 1)]
    }

    // MARK: Scheduling (call with lock held)

    private func makeSessions() {
        let count = supportsRanges ? maxConnections : 1
        sessions = (0..<count).map { _ in
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            config.httpMaximumConnectionsPerHost = 1
            config.httpCookieAcceptPolicy = .never
            return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        }
        freeSlots = Array(sessions.indices)
    }

    private func fillSlots() {
        guard !stopped else { return }
        if connectionCap < maxConnections, let last = lastPushback, ContinuousClock.now - last > .seconds(30) {
            connectionCap += 1
            lastPushback = .now
        }
        while !freeSlots.isEmpty, tasks.count + cooling.count < connectionCap {
            var index = SegmentPlanner.nextPending(segments, busy: busy)
            if index == nil, supportsRanges {
                index = SegmentPlanner.splitLargest(&segments, busy: Set(tasks.values.map(\.segment)))
            }
            guard let index else { break }
            launch(index)
        }
        if tasks.isEmpty, cooling.isEmpty, segments.allSatisfy(\.isComplete) {
            finish()
        }
    }

    private func launch(_ index: Int) {
        let slot = freeSlots.removeLast()
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if supportsRanges {
            let segment = segments[index]
            request.setValue("bytes=\(segment.nextOffset)-\(segment.end)", forHTTPHeaderField: "Range")
        }
        let task = sessions[slot].dataTask(with: request)
        tasks[ObjectIdentifier(task)] = (task, index, slot)
        task.resume()
    }

    private func finish() {
        stopped = true
        closeFile()
        let received = SegmentPlanner.received(segments)
        if totalBytes == nil {
            totalBytes = received
            segments = [Segment(start: 0, end: max(0, received - 1), received: received)]
            truncate(partialURL.path, off_t(received))
        }
        let existing = directory.appending(path: fileName)
        if overwrite, FileManager.default.fileExists(atPath: existing.path) {
            try? FileManager.default.trashItem(at: existing, resultingItemURL: nil)
        }
        let finalName = FileNaming.unique(fileName, in: directory, ignoringPartials: true)
        do {
            try FileManager.default.moveItem(at: partialURL, to: directory.appending(path: finalName))
            fileName = finalName
            let finished = sessions
            sessions.removeAll()
            finished.forEach { $0.finishTasksAndInvalidate() }
            onEvent(.completed(fileName: finalName))
        } catch {
            onEvent(.failed(error.localizedDescription))
        }
    }

    private func fail(_ error: Error) {
        let toCancel: [URLSession] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            tasks.values.forEach { $0.task.cancel() }
            tasks.removeAll()
            closeFile()
            defer { sessions.removeAll() }
            return sessions
        }
        toCancel.forEach { $0.invalidateAndCancel() }
        onEvent(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
    }

    private func closeFile() {
        if fd >= 0 {
            fsync(fd)
            close(fd)
            fd = -1
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let key = ObjectIdentifier(dataTask)
        let disposition: URLSession.ResponseDisposition = lock.withLock {
            guard let http = response as? HTTPURLResponse, let entry = tasks[key] else { return .cancel }
            if !(200..<300).contains(http.statusCode) {
                taskErrors[key] = DownloadError.badResponse(http.statusCode)
                if let wait = Self.retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After")) { retryAfter[key] = wait }
                return .cancel
            }
            if supportsRanges, http.statusCode != 206, segments[entry.segment].nextOffset != 0 || segments.count > 1 {
                // The server ignored the Range header (some mirrors and CDNs do, even after saying they support it).
                rangesRejected = true
                taskErrors[key] = DownloadError.badResponse(http.statusCode)
                return .cancel
            }
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = ObjectIdentifier(dataTask)
        var diskError: Error?
        let written: Int = lock.withLock {
            guard !stopped, fd >= 0, let entry = tasks[key] else { return 0 }
            let segment = segments[entry.segment]
            let count = Int(min(Int64(data.count), segment.remaining))
            guard count > 0 else {
                dataTask.cancel()
                return 0
            }
            var offset = 0
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while offset < count {
                    let n = pwrite(fd, base + offset, count - offset, off_t(segment.nextOffset) + off_t(offset))
                    if n <= 0 {
                        diskError = DownloadError.disk("Write failed: \(String(cString: strerror(errno)))")
                        return
                    }
                    offset += n
                }
            }
            segments[entry.segment].received += Int64(offset)
            retries[entry.segment] = 0
            if segments[entry.segment].isComplete { dataTask.cancel() }
            return offset
        }
        if let diskError { fail(diskError); return }
        RateLimiter.shared.throttle(written)
        ownLimiter.throttle(written)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = ObjectIdentifier(task)
        var fatal: Error?
        lock.withLock {
            guard let entry = tasks.removeValue(forKey: key) else { return }
            freeSlots.append(entry.slot)
            let taskError = taskErrors.removeValue(forKey: key)
            let waitHint = retryAfter.removeValue(forKey: key)
            guard !stopped else { return }
            if rangesRejected, supportsRanges {
                switchToSingleStream()
                return
            }

            let index = entry.segment
            let streamEnded = error == nil && taskError == nil && totalBytes == nil
            if segments[index].isComplete || streamEnded {
                if streamEnded { segments[index].end = segments[index].start + segments[index].received - 1 }
                fillSlots()
                return
            }

            let attempt = (retries[index] ?? 0) + 1
            retries[index] = attempt
            let reason = taskError ?? error ?? DownloadError.badResponse(0)
            if case .badResponse(let code)? = taskError as? DownloadError, code == 429 || code == 503 {
                connectionCap = max(1, min(connectionCap - 1, tasks.count + 1))
                lastPushback = .now
            }
            if attempt > Self.maxRetries || (taskError as? DownloadError).map(Self.isPermanent) == true {
                fatal = reason
                return
            }
            if !supportsRanges { segments[index].received = 0 }
            cooling.insert(index)
            // Exponential backoff, or longer if the server said so, with jitter so connections don't retry in step.
            var delay = min(pow(2, Double(attempt - 1)), 20)
            if let waitHint { delay = max(delay, min(waitHint, 60)) }
            delay *= Double.random(in: 1...1.2)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                lock.withLock {
                    cooling.remove(index)
                    fillSlots()
                }
            }
            fillSlots()
        }
        if let fatal { fail(fatal) }
    }

    /// Starts over as a single full-file stream after the server ignored a Range request. Call with the lock held.
    private func switchToSingleStream() {
        supportsRanges = false
        connectionCap = 1
        lastPushback = nil
        tasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
        taskErrors.removeAll()
        retryAfter.removeAll()
        retries.removeAll()
        cooling.removeAll()
        freeSlots = Array(sessions.indices)
        segments = Self.initialSegments(total: totalBytes, ranges: false, connections: 1)
        sampled = 0
        fillSlots()
    }

    /// Retry-After as seconds: a number, or an HTTP date. nil when missing or unreadable.
    static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    private static func isPermanent(_ error: DownloadError) -> Bool {
        if case .badResponse(let code) = error { return [401, 403, 404, 410].contains(code) }
        return false
    }
}
