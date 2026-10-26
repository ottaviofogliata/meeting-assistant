import XCTest
import AVFoundation
@testable import MeetingRuntime

final class AudioIOTests: XCTestCase {
    func testDiscreteFiveChannelMicrophoneSurvivesMonoConversion() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: path) }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 5)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for channel in 0..<5 { for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = channel == 4 ? Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.1 : 0 } }
        var file: AVAudioFile? = try AVAudioFile(forWriting: path, settings: format.settings)
        try file?.write(from: buffer); file = nil
        let result = try AudioIO.normalized(path)
        XCTAssertEqual(result.count, 16000, accuracy: 64)
        XCTAssertGreaterThan(AudioIO.energy(result), 0.01)
    }
    func testSpeechLevelBoostsQuietVoiceWithoutClippingOrChangingSilence() {
        let quiet = (0..<16000).map { Float(sin(Double($0) * 0.1)) * 0.003 }
        let boosted = AudioIO.speechLevel(quiet)
        XCTAssertGreaterThan(AudioIO.energy(boosted), 0.02)
        XCTAssertLessThanOrEqual(boosted.map(abs).max()!, 0.98)
        XCTAssertEqual(AudioIO.speechLevel([0, 0, 0]), [0, 0, 0])
    }
}
