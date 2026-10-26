import XCTest
@testable import MeetingCore

final class MeetingCoreTests: XCTestCase {
    func testFullTranscriptionWindowsAlwaysCommitAfterAPartialDecode() {
        let partial = TranscriptionScheduling.next(available: 20.1, committed: 0, decodedThrough: 0, mode: .background, force: false)!
        XCTAssertFalse(partial.commits)
        let complete = TranscriptionScheduling.next(available: 30, committed: 0, decodedThrough: partial.end, mode: .background, force: false)!
        XCTAssertTrue(complete.commits); XCTAssertEqual(complete.end, 24)
        let realtime = TranscriptionScheduling.next(available: 8.3, committed: 0, decodedThrough: 7.2, mode: .realtime, force: false)!
        XCTAssertTrue(realtime.commits); XCTAssertEqual(realtime.end, 8)
        let next = TranscriptionScheduling.next(available: 26, committed: complete.end, decodedThrough: complete.end, mode: .realtime, force: false)!
        XCTAssertEqual(next.start, 24); XCTAssertEqual(next.end, 26)
        let tail = TranscriptionScheduling.next(available: 26, committed: 24, decodedThrough: 26, mode: .background, force: true)!
        XCTAssertTrue(tail.commits); XCTAssertEqual(tail.end, 26)
        XCTAssertNil(TranscriptionScheduling.next(available: 26, committed: 26, decodedThrough: 26, mode: .realtime, force: true))
    }
    func testScreenTextIgnoresClockButDetectsCodeAndResultChanges() {
        XCTAssertFalse(ScreenText.changed(from: "Budget 2000 13:14:02", to: "Budget 2000 13:14:03"))
        XCTAssertFalse(ScreenText.changed(from: "Title |", to: "Title"))
        XCTAssertTrue(ScreenText.changed(from: "let approved = true", to: "let approved = false"))
        XCTAssertTrue(ScreenText.changed(from: "HTTP 200", to: "HTTP 500"))
        XCTAssertTrue(ScreenText.changed(from: "Result", to: "Result FAILED"))
    }
    func testShortAudioPacketBurstsDoNotLookLikeDiskFailure() {
        let budget = AudioQueueBudget()
        for _ in 0..<200 { XCTAssertTrue(budget.reserve(seconds: 0.005, bytes: 1920)) }
        XCTAssertFalse(budget.reserve(seconds: 2, bytes: 1920))
        for _ in 0..<200 { budget.release(seconds: 0.005, bytes: 1920) }
        XCTAssertTrue(budget.reserve(seconds: 2, bytes: 2_000_000))
        XCTAssertFalse(budget.reserve(seconds: 0.01, bytes: 8 * 1024 * 1024))
    }
    func testSpeechWindowsSplitLanguageTurnsAtSilenceWithoutSpeakerModels() {
        let voice = [Float](repeating: 0.1, count: 16000)
        let silence = [Float](repeating: 0, count: 16000)
        let samples = voice + silence + voice
        let ranges = SpeechWindows.ranges(samples: samples)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertLessThan(ranges[0].upperBound, ranges[1].lowerBound)
        XCTAssertEqual(ranges[0].lowerBound, 0)
        XCTAssertEqual(ranges[1].upperBound, samples.count)
        XCTAssertTrue(SpeechWindows.ranges(samples: silence).isEmpty)
        let continuous = [Float](repeating: 0.1, count: 30 * 16000)
        let windows = SpeechWindows.ranges(samples: continuous)
        XCTAssertEqual(windows.reduce(0) { $0 + $1.count }, continuous.count)
        for pair in zip(windows, windows.dropFirst()) { XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound) }
    }
    func testFifteenMinuteBoundaryAndAnchoredCadence() {
        XCTAssertEqual(ScreenshotPolicy.cadence(at: 899), 60)
        XCTAssertEqual(ScreenshotPolicy.cadence(at: 900), 60)
        XCTAssertEqual(ScreenshotPolicy.cadence(at: 900.001), 120)
        XCTAssertEqual(ScreenshotPolicy.nextSlot(after: 900, elapsed: 901), 960)
    }
    func testRetroactiveThinningProtectsChangeAndBoundaryImages() {
        let periodic = Screenshot(path: "odd.jpg", time: 60, source: "slide", reasons: [.periodic], periodicSlot: 60)
        let even = Screenshot(path: "even.jpg", time: 120, source: "slide", reasons: [.periodic], periodicSlot: 120)
        var dual = periodic; dual.reasons.insert(.significantChange)
        var boundary = periodic; boundary.reasons.insert(.sourceChange)
        XCTAssertFalse(ScreenshotPolicy.removable(periodic, elapsed: 900))
        XCTAssertTrue(ScreenshotPolicy.removable(periodic, elapsed: 901))
        XCTAssertFalse(ScreenshotPolicy.removable(even, elapsed: 901))
        XCTAssertFalse(ScreenshotPolicy.removable(dual, elapsed: 7200))
        XCTAssertFalse(ScreenshotPolicy.removable(boundary, elapsed: 7200))
    }
    func testWholeTwoHourSchedule() {
        let firstQuarter = (1...15).map { Screenshot(path: "\($0).jpg", time: Double($0 * 60), source: "display", reasons: [.periodic], periodicSlot: $0 * 60) }
        let kept = firstQuarter.filter { !ScreenshotPolicy.removable($0, elapsed: 7200) }
        XCTAssertEqual(kept.map(\.periodicSlot), [120, 240, 360, 480, 600, 720, 840])
    }
    func testClockExcludesPausesAndHandlesDelayedBuffers() {
        let clock = RecordingClock(); clock.start(at: 100); clock.pause(at: 200); clock.resume(at: 500); clock.pause(at: 550)
        XCTAssertEqual(clock.elapsed(at: 600), 150)
        XCTAssertEqual(clock.elapsed(at: 150), 50)
        XCTAssertTrue(clock.isActive(at: 120)); XCTAssertFalse(clock.isActive(at: 200)); XCTAssertFalse(clock.isActive(at: 400)); XCTAssertTrue(clock.isActive(at: 520))
    }
    func testMeetingWideSpeakerIdentityAcrossWindows() {
        var speakers = SpeakerClusters(threshold: 0.8)
        XCTAssertEqual(speakers.assign([1, 0, 0]), 0)
        XCTAssertEqual(speakers.assign([0, 1, 0]), 1)
        XCTAssertEqual(speakers.assign([5, 0.1, 0]), 0)
        XCTAssertEqual(speakers.assign([0.1, 4, 0]), 1)
        XCTAssertEqual(speakers.centroids.count, 2)
        XCTAssertNil(speakers.assign([])); XCTAssertNil(speakers.assign([Float.nan, 0, 1])); XCTAssertNil(speakers.assign([1, 2]))
    }
    func testScreenshotSelectionCoversTimelineAndDoesNotDeleteArchive() {
        let images = (0..<120).map { Screenshot(path: "\($0).jpg", time: Double($0 * 60), source: "display", reasons: [.significantChange], signature: UInt64($0), text: "Slide \($0)") }
        let selected = ScreenshotPolicy.select(images, budget: 24, duration: 7200)
        XCTAssertEqual(images.count, 120); XCTAssertEqual(selected.count, 24)
        XCTAssertLessThan(selected.first!.time, 300); XCTAssertGreaterThan(selected.last!.time, 6800)
        XCTAssertEqual(Set(selected.map { Int($0.time) / 300 }).count, 24)
    }
    func testEditsPreserveIdentityTimingAndLanguage() {
        var doc = TranscriptDocument(); let segment = TranscriptSegment(start: 12, end: 19, text: "original", speakerID: "speaker_001", language: "en")
        doc.segments = [segment]; doc.edit(id: segment.id, text: "corrected"); doc.rename(speaker: "speaker_001", name: "Alice")
        XCTAssertEqual(doc.revision, 2); XCTAssertEqual(doc.segments[0].start, 12); XCTAssertEqual(doc.segments[0].end, 19); XCTAssertEqual(doc.segments[0].id, segment.id); XCTAssertTrue(doc.segments[0].edited)
        XCTAssertEqual(doc.predominantLanguage, "en"); XCTAssertTrue(doc.markdown().contains("Alice"))
    }
    func testOriginalsAreImmutableAndStaleAutosaveCannotOverwriteEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(root: root); let meeting = Meeting(title: "Fixture", options: RecordingOptions())
        try await archive.save(meeting)
        var original = TranscriptDocument(); let segment = TranscriptSegment(start: 0, end: 3, text: "original"); original.segments = [segment]
        try await archive.saveTranscript(original, meeting: meeting, original: true)
        var edited = original; edited.edit(id: segment.id, text: "corrected")
        try await archive.saveTranscript(edited, meeting: meeting, original: true)
        try await archive.saveTranscript(original, meeting: meeting)
        let current = try await archive.transcript(meeting)
        XCTAssertEqual(current.segments[0].text, "corrected")
        let dir = try archive.directory(meeting)
        let savedOriginal = try ArchiveStore.decoder().decode(TranscriptDocument.self, from: Data(contentsOf: dir.appendingPathComponent("transcripts/original.json")))
        XCTAssertEqual(savedOriginal.segments[0].text, "original")
    }
    func testArchivePathTraversalAndSymlinkEscapeAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ArchiveStore.safeURL("../outside", inside: root))
        XCTAssertThrowsError(try ArchiveStore.safeURL("/etc/passwd", inside: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try ArchiveStore.safeURL("escape/passwd", inside: root))
        XCTAssertNoThrow(try ArchiveStore.safeURL("capture/audio/test.caf", inside: root))
    }
    func testInvalidRecapReferencesAreRejected() throws {
        let json = #"{"language":"it","summary":"Summary","topics":[{"text":"Topic","sourceIDs":["invented"]}],"decisions":[],"actionItems":[],"openQuestions":[]}"#
        let recap = try ArchiveStore.decoder().decode(RecapDocument.self, from: Data(json.utf8))
        XCTAssertThrowsError(try recap.validate(knownSourceIDs: ["real"]))
        XCTAssertNoThrow(try recap.validate(knownSourceIDs: ["invented"]))
        let missingReferences = json.replacingOccurrences(of: "[\"invented\"]", with: "[]")
        let ungrounded = try ArchiveStore.decoder().decode(RecapDocument.self, from: Data(missingReferences.utf8))
        XCTAssertThrowsError(try ungrounded.validate(knownSourceIDs: ["real"]))
    }
    func testArchivePreflightChecksTheSelectedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = try ArchiveStore(root: root)
        try await archive.preflight()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try FileManager.default.removeItem(at: root)
        do { try await archive.preflight(); XCTFail("An unavailable archive must fail before capture.") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)) }
    }
}
