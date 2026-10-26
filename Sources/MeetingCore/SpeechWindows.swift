import Foundation

public enum SpeechWindows {
    /// Energy segmentation only; no speaker inference or embeddings during capture.
    /// Language is redetected at each utterance instead of being locked for a 24-second block.
    public static func ranges(samples: [Float], sampleRate: Int = 16000) -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }
        let hop = max(1, sampleRate / 50)
        let energies = stride(from: 0, to: samples.count, by: hop).map { start -> Float in
            let end = min(samples.count, start + hop)
            return sqrt(samples[start..<end].reduce(0) { $0 + $1 * $1 } / Float(end - start))
        }
        let threshold = max(Float(0.002), min(Float(0.012), (energies.max() ?? 0) * 0.08))
        var ranges: [Range<Int>] = []; var begin: Int?; var silence = 0; var emittedThrough = 0
        for frame in energies.indices {
            if energies[frame] >= threshold { if begin == nil { begin = max(emittedThrough, frame - 7) }; silence = 0 }
            else if begin != nil { silence += 1 }
            if let start = begin, silence >= 25 || frame - start >= 600 {
                let end = min(samples.count, (frame - max(0, silence - 10) + 1) * hop)
                if end - start * hop > sampleRate / 5 { ranges.append((start * hop)..<end); emittedThrough = (end + hop - 1) / hop }
                begin = nil; silence = 0
            }
        }
        if let start = begin, samples.count - start * hop > sampleRate / 5 { ranges.append((start * hop)..<samples.count) }
        return ranges
    }
}
