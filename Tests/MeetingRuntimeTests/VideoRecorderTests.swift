import XCTest
import AVFoundation
import MeetingCore
@testable import MeetingRuntime

final class VideoRecorderTests: XCTestCase {
    func testThreeSequentialSegmentsArePlayableAndHavePreciseDurations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("capture/video"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let frame = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(frame, []); memset(CVPixelBufferGetBaseAddress(frame), 120, CVPixelBufferGetDataSize(frame)); CVPixelBufferUnlockBaseAddress(frame, [])
        var paths: Set<String> = []
        for index in 0..<3 {
            let start = Double(index) * 3.7
            let recorder = try VideoRecorder(directory: directory, width: 64, height: 64, start: start, firstPTS: CMTime(seconds: 20000 + start, preferredTimescale: 1_000_000_000))
            for offset in [0.0, 0.033, 0.066, 1.0, 1.033, 1.066, 6.0, 6.033, 6.066, 12.3, 12.4] {
                try recorder.append(frame, at: CMTime(seconds: 20000 + start + offset, preferredTimescale: 1_000_000_000))
                try await Task.sleep(for: .milliseconds(5))
            }
            let finalized = try await recorder.finish(at: start + 12.57, finalPixel: frame)
            let segment = try XCTUnwrap(finalized)
            XCTAssertEqual(segment.start, start, accuracy: 0.001); XCTAssertEqual(segment.duration, 12.57, accuracy: 0.04)
            XCTAssertTrue(paths.insert(segment.path).inserted)
            let asset = AVURLAsset(url: directory.appendingPathComponent(segment.path))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, 12.57, accuracy: 0.04)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(segment.path + ".json").path))
        }
    }
}
