import Foundation
import AVFoundation
import MeetingCore

/// One bounded encoder for one continuous source/recording interval.
/// The capture queue serializes append calls and stops them before finish.
final class VideoRecorder: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let firstPTS: CMTime
    private let start: Double
    private let directory: URL
    private let path: String
    private var lastTime: Double = -1
    init(directory: URL, width: Int, height: Int, start: Double, firstPTS: CMTime) throws {
        self.directory = directory; self.start = start; self.firstPTS = firstPTS
        path = "capture/video/\(UUID().uuidString).mp4"
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent(path), fileType: .mp4)
        writer.movieTimeScale = 60000
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: 60, AVVideoExpectedSourceFrameRateKey: 30, AVVideoAllowFrameReorderingKey: false]]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = 60000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw MeetingError.message("Il codificatore video non accetta questa sorgente.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MeetingError.message("Impossibile avviare il file video.") }
        writer.startSession(atSourceTime: .zero)
        try ArchiveStore.encoder().encode(MediaSegment(path: path, start: start, duration: 0, track: nil)).write(to: directory.appendingPathComponent(path + ".json"), options: .atomic)
    }
    func append(_ pixel: CVPixelBuffer, at pts: CMTime) throws {
        guard writer.status == .writing else { throw writer.error ?? MeetingError.message("Il codificatore video si è fermato.") }
        let time = CMTimeConvertScale(CMTimeSubtract(pts, firstPTS), timescale: 60000, method: .default)
        guard time.seconds.isFinite, time.seconds >= 0, time.seconds > lastTime, input.isReadyForMoreMediaData else { return }
        guard adaptor.append(pixel, withPresentationTime: time) else { throw writer.error ?? MeetingError.message("Fotogramma video non salvato.") }
        lastTime = time.seconds
    }
    func finish(at end: Double, finalPixel: CVPixelBuffer?) async throws -> MediaSegment? {
        guard writer.status == .writing else { throw writer.error ?? MeetingError.message("Il file video non è più in registrazione.") }
        guard lastTime >= 0 else { writer.cancelWriting(); return nil }
        let duration = max(lastTime + 1.0 / 30, end - start)
        if let finalPixel, input.isReadyForMoreMediaData, duration - 1.0 / 30 > lastTime {
            _ = adaptor.append(finalPixel, withPresentationTime: CMTime(seconds: duration - 1.0 / 30, preferredTimescale: 60000))
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MeetingError.message("Finalizzazione video non completata.") }
        let actual = try await AVURLAsset(url: directory.appendingPathComponent(path)).load(.duration).seconds
        guard actual.isFinite, actual > 0 else { throw MeetingError.message("Il video non contiene fotogrammi leggibili.") }
        let segment = MediaSegment(path: path, start: start, duration: min(duration, actual), track: nil)
        try ArchiveStore.encoder().encode(segment).write(to: directory.appendingPathComponent(path + ".json"), options: .atomic)
        return segment
    }
}
