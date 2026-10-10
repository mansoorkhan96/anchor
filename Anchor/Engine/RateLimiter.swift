import Foundation

/// Global token bucket shared by every connection. A limit of 0 means unlimited.
final class RateLimiter: @unchecked Sendable {
    static let shared = RateLimiter()

    private let lock = NSLock()
    private var bytesPerSecond: Double = 0
    private var tokens: Double = 0
    private var lastRefill = ContinuousClock.now

    var limit: Int64 {
        get { lock.withLock { Int64(bytesPerSecond) } }
        set {
            lock.withLock {
                bytesPerSecond = Double(max(0, newValue))
                tokens = min(tokens, bytesPerSecond)
            }
        }
    }

    /// Takes `count` tokens and returns how long the caller should wait before reading more.
    func reserve(_ count: Int) -> Duration {
        lock.withLock {
            guard bytesPerSecond > 0 else { return .zero }
            let now = ContinuousClock.now
            let elapsed = now - lastRefill
            lastRefill = now
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            tokens = min(bytesPerSecond, tokens + seconds * bytesPerSecond)
            tokens -= Double(count)
            guard tokens < 0 else { return .zero }
            return .milliseconds(Int(-tokens / bytesPerSecond * 1000))
        }
    }

    /// Blocking variant for URLSession delegate queues: sleeping there applies TCP back-pressure.
    func throttle(_ count: Int) {
        let wait = reserve(count)
        guard wait > .zero else { return }
        let ms = Double(wait.components.seconds) * 1000 + Double(wait.components.attoseconds) / 1e15
        Thread.sleep(forTimeInterval: min(ms / 1000, 2))
    }
}
