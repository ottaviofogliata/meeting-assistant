import Foundation

public final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [(Double, Double?)] = []
    public init() {}
    public func start(at now: Double = ProcessInfo.processInfo.systemUptime) { lock.lock(); intervals = [(now, nil)]; lock.unlock() }
    public func pause(at now: Double = ProcessInfo.processInfo.systemUptime) { lock.lock(); if let last = intervals.last, last.1 == nil { intervals[intervals.count - 1].1 = now }; lock.unlock() }
    public func resume(at now: Double = ProcessInfo.processInfo.systemUptime) { lock.lock(); if intervals.last?.1 != nil { intervals.append((now, nil)) }; lock.unlock() }
    public func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        lock.lock(); defer { lock.unlock() }
        return intervals.reduce(0) { $0 + max(0, min(now, $1.1 ?? now) - $1.0) }
    }
    public func isActive(at now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return intervals.contains { now >= $0.0 && ($0.1 == nil || now < $0.1!) }
    }
}
public enum ScreenshotPolicy {
    public static func cadence(at elapsed: Double) -> Int { elapsed > 900 ? 120 : 60 }
    public static func nextSlot(after slot: Int, elapsed: Double) -> Int { ((slot / cadence(at: elapsed)) + 1) * cadence(at: elapsed) }
    public static func removable(_ image: Screenshot, elapsed: Double) -> Bool {
        elapsed > 900 && !image.protected && image.reasons == [.periodic] && image.periodicSlot.map { $0 % 120 != 0 } == true
    }
    public static func select(_ images: [Screenshot], budget: Int = 24, duration: Double) -> [Screenshot] {
        guard budget > 0 else { return [] }
        let sorted = images.sorted { $0.time < $1.time }
        guard sorted.count > budget else { return sorted }
        var chosen: [Screenshot] = []
        for bucket in 0..<budget {
            let low = max(0, duration) * Double(bucket) / Double(budget)
            let high = max(0, duration) * Double(bucket + 1) / Double(budget)
            let candidates = sorted.filter { $0.time >= low && (bucket == budget - 1 ? $0.time <= high + 1 : $0.time < high) }
            let best = candidates.max { a, b in
                func score(_ value: Screenshot) -> Double {
                    let diversity = chosen.map { Double(($0.signature ^ value.signature).nonzeroBitCount) }.min() ?? 32
                    return log(Double(value.text.count) + 2) + (value.reasons.contains(.significantChange) ? 3 : 0) + diversity / 8
                }
                return score(a) < score(b)
            }
            if let best { chosen.append(best) }
        }
        return chosen.sorted { $0.time < $1.time }
    }
}

/// Meeting-wide online clustering of bounded-window speaker embeddings.
/// Only compact centroids and segment metadata are retained, not the audio windows.
public struct SpeakerClusters {
    public private(set) var centroids: [[Float]] = []
    private var counts: [Int] = []
    public var threshold: Float
    public var maximum: Int
    public init(threshold: Float = 0.68, maximum: Int = 10) { self.threshold = threshold; self.maximum = maximum }
    public mutating func assign(_ embedding: [Float]) -> Int? {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite), centroids.isEmpty || centroids[0].count == embedding.count else { return nil }
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        guard norm > 0.00001 else { return nil }
        let normalized = embedding.map { $0 / norm }
        let scores = centroids.map { zip($0, normalized).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        let best = scores.indices.max { scores[$0] < scores[$1] }
        if let best, scores[best] >= threshold || centroids.count >= maximum {
            counts[best] += 1
            let weight = 1 / Float(counts[best])
            centroids[best] = zip(centroids[best], normalized).map { $0 * (1 - weight) + $1 * weight }
            let magnitude = sqrt(centroids[best].reduce(0) { $0 + $1 * $1 })
            centroids[best] = centroids[best].map { $0 / max(magnitude, 0.00001) }
            return best
        }
        centroids.append(normalized); counts.append(1); return centroids.count - 1
    }
}
