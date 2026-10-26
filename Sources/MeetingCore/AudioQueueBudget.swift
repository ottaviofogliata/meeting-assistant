import Foundation

/// Bounds queued audio by duration and bytes, not callback count.
public final class AudioQueueBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    private var bytes = 0
    public init() {}
    public func reserve(seconds duration: Double, bytes count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard duration.isFinite, duration >= 0, count >= 0, seconds + duration <= 2.5, bytes + count <= 8 * 1024 * 1024 else { return false }
        seconds += duration; bytes += count; return true
    }
    public func release(seconds duration: Double, bytes count: Int) { lock.lock(); seconds = max(0, seconds - duration); bytes = max(0, bytes - count); lock.unlock() }
}
