import Foundation

public struct TranscriptionWindow: Sendable {
    public let start: Double
    public let end: Double
    public let commits: Bool
}
public enum TranscriptionScheduling {
    public static func next(available: Double, committed: Double, decodedThrough: Double, mode: TranscriptionMode, force: Bool) -> TranscriptionWindow? {
        let size = mode == .realtime && !force ? 8.0 : 24.0
        let end = min(available, committed + size)
        let full = end - committed >= size - 0.01
        let increment = mode == .realtime ? 1.5 : 20.0
        guard end > committed + 0.1, force || full || end - decodedThrough >= increment else { return nil }
        return TranscriptionWindow(start: committed, end: end, commits: force || full)
    }
}
