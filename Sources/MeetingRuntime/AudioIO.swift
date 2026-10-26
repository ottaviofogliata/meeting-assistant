import Foundation
import AVFoundation
import MeetingCore

public enum AudioIO {
    public static func normalized(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard file.length <= AVAudioFramePosition(input.sampleRate * 120) else { throw MeetingError.message("Un segmento audio supera il limite di memoria previsto.") }
        guard let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: source)
        guard let channels = source.floatChannelData else { return [] }
        let count = Int(source.frameLength); let channelCount = Int(input.channelCount)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false)!
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: source.frameLength), let destination = mono.floatChannelData?[0] else { return [] }
        mono.frameLength = source.frameLength
        for frame in 0..<count { destination[frame] = 0 }
        // Discrete multichannel microphone layouts can be silently remapped to
        // an empty channel by AVAudioConverter. Mix explicitly before resampling.
        var strongest = 0; var strongestPower: Float = 0
        for channel in 0..<channelCount {
            var power: Float = 0
            for frame in 0..<count {
                let sample = channels[channel][frame]
                destination[frame] += sample / Float(channelCount); power += sample * sample
            }
            if power > strongestPower { strongest = channel; strongestPower = power }
        }
        var mixedPower: Float = 0
        for frame in 0..<count { mixedPower += destination[frame] * destination[frame] }
        if mixedPower < strongestPower * 0.01 { for frame in 0..<count { destination[frame] = channels[strongest][frame] } }
        if input.sampleRate == 16000 { return Array(UnsafeBufferPointer(start: destination, count: count)) }
        guard let converter = AVAudioConverter(from: monoFormat, to: output) else { return [] }
        converter.primeMethod = .none
        let capacity = AVAudioFrameCount(Double(source.frameLength) * 16000 / input.sampleRate) + 64
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return mono
        }
        if let error { throw error }
        guard let samples = target.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(target.frameLength)))
    }
    public static func speechLevel(_ samples: [Float]) -> [Float] {
        let rms = energy(samples); let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard rms > 0.00001, peak > 0 else { return samples }
        let gain = max(1, min(20, min(0.04 / rms, 0.98 / peak)))
        return samples.map { $0 * gain }
    }
    public static func window(media: [MediaSegment], directory: URL, track: AudioTrack, start: Double, end: Double) throws -> [Float] {
        guard end > start, end - start <= 65 else { return [] }
        var samples = [Float](repeating: 0, count: Int(ceil((end - start) * 16000)))
        for segment in media where segment.track == track && segment.start < end && segment.start + segment.duration > start {
            let url = try ArchiveStore.safeURL(segment.path, inside: directory)
            let audio = try normalized(url)
            let sourceStart = max(0, Int((start - segment.start) * 16000))
            let destinationStart = max(0, Int((segment.start - start) * 16000))
            let count = min(audio.count - min(sourceStart, audio.count), samples.count - min(destinationStart, samples.count))
            if count > 0 { samples.replaceSubrange(destinationStart..<(destinationStart + count), with: audio[sourceStart..<(sourceStart + count)]) }
        }
        return samples
    }
    public static func energy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }; return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
    /// Conservative reference cancellation. Native voice processing remains the first stage.
    /// Subtract only a strong correlated far-end component, preserving independent near-end speech.
    public static func removingEcho(_ microphone: [Float], reference: [Float]) -> [Float] {
        guard microphone.count == reference.count, microphone.count > 1600, energy(reference) > 0.001 else { return microphone }
        var bestCorrelation: Float = 0; var bestDelay = 0; var bestGain: Float = 0
        for delay in stride(from: -4000, through: 4000, by: 160) {
            var cross: Float = 0; var micPower: Float = 0; var refPower: Float = 0
            let lower = max(0, delay); let upper = min(microphone.count, reference.count + delay)
            if lower >= upper { continue }
            for i in stride(from: lower, to: upper, by: 32) {
                let m = microphone[i]; let r = reference[i - delay]
                cross += m * r; micPower += m * m; refPower += r * r
            }
            let correlation = cross / max(0.000001, sqrt(micPower * refPower))
            if correlation > bestCorrelation { bestCorrelation = correlation; bestDelay = delay; bestGain = min(2, max(0, cross / max(refPower, 0.000001))) }
        }
        guard bestCorrelation > 0.70 else { return microphone }
        var cleaned = microphone
        for i in max(0, bestDelay)..<min(microphone.count, reference.count + bestDelay) { cleaned[i] -= reference[i - bestDelay] * bestGain }
        return cleaned
    }
    public static func composition(meeting: Meeting, directory: URL) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for kind in [AudioTrack.microphone, .system] {
            let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            for segment in meeting.media.filter({ $0.track == kind }).sorted(by: { $0.start < $1.start }) {
                let asset = AVURLAsset(url: try ArchiveStore.safeURL(segment.path, inside: directory))
                if let track = try await asset.loadTracks(withMediaType: .audio).first {
                    let duration = min(segment.duration, try await asset.load(.duration).seconds)
                    if duration > 0 { try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48000)), of: track, at: CMTime(seconds: segment.start, preferredTimescale: 48000)) }
                }
            }
        }
        if meeting.options.video, let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            for segment in meeting.media.filter(\.isVideo).sorted(by: { $0.start < $1.start }) {
                let asset = AVURLAsset(url: try ArchiveStore.safeURL(segment.path, inside: directory))
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let duration = min(segment.duration, try await asset.load(.duration).seconds)
                    if duration > 0 { try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)), of: track, at: CMTime(seconds: segment.start, preferredTimescale: 600)) }
                }
            }
        }
        return composition
    }
}
