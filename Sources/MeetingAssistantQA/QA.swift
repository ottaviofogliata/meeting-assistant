import Foundation
import AVFoundation
import MeetingCore
import MeetingRuntime
import AppKit
import SwiftUI

@main struct MeetingAssistantQA {
    @MainActor private static var fixtureAudio: AVAudioPlayer?
    @MainActor private static var fixtureWindows: [NSWindow] = []
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "screen-fixture" {
            // AppKit owns the event loop outside an async MainActor job. Keeping
            // app.run() inside such a job prevents SwiftUI fixture updates.
            MainActor.assumeIsolated { launchScreenFixture(audioPath: args.dropFirst().first) }
            return
        }
        Task {
            do { try await run(); exit(0) }
            catch { FileHandle.standardError.write(Data("QA FAILED: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
        dispatchMain()
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if ["diagnose-audio", "probe-audio"].contains(args.first ?? ""), args.count == 4 { try await diagnoseAudio(directory: URL(fileURLWithPath: args[1]), start: Double(args[2]) ?? 0, end: Double(args[3]) ?? 0, transcribe: args.first == "diagnose-audio"); return }
        if args.first == "recap-fixture", args.count >= 2 { try await recapFixture(directory: URL(fileURLWithPath: args[1]), images: Array(args.dropFirst(2))); return }
        let inference = LocalInference()
        if args.first == "prepare" {
            print("Preparing compressed Whisper turbo…"); try await inference.prepareTranscription(); await inference.unloadAll(); print("Whisper ready"); return
        }
        guard args.count >= 3, args[0] == "fixture" else {
            print("Usage: meeting-assistant-qa prepare | fixture <audio-file> <test-archive> [--codex]")
            return
        }
        let input = URL(fileURLWithPath: args[1]); let root = URL(fileURLWithPath: args[2]); let archive = try ArchiveStore(root: root)
        var options = RecordingOptions(); options.mode = .inPerson
        var meeting = Meeting(title: "QA · riunione di test italiano / English", options: options)
        try await archive.save(meeting)
        let directory = try archive.directory(meeting)
        let filename = "capture/audio/fixture." + input.pathExtension
        try FileManager.default.copyItem(at: input, to: directory.appendingPathComponent(filename))
        meeting.duration = try await AVURLAsset(url: input).load(.duration).seconds
        // The QA fixture is segmented on disk to exercise bounded loading like real capture.
        let source = try AVAudioFile(forReading: directory.appendingPathComponent(filename))
        var offset: Double = 0
        while source.framePosition < source.length {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(source.processingFormat.sampleRate * 24), source.length - source.framePosition))
            let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count)!
            try source.read(into: buffer, frameCount: count)
            let path = "capture/audio/qa-\(UUID().uuidString).caf"
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(path), settings: source.processingFormat.settings)
            try file.write(from: buffer)
            let duration = Double(buffer.frameLength) / source.processingFormat.sampleRate
            meeting.media.append(MediaSegment(path: path, start: offset, duration: duration, track: .microphone)); offset += duration
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        meeting.state = .finalizingTranscript; meeting.saveRevision += 1; try await archive.save(meeting)
        let loading = Date(); try await inference.prepareTranscription(); print("Model loaded in \(Date().timeIntervalSince(loading))s")
        var transcript = TranscriptDocument(); let before = Date()
        let inferenceWindow = args.contains("--realtime-windows") ? 8.0 : 24.0
        for start in stride(from: 0.0, to: meeting.duration, by: inferenceWindow) {
            let segments = try await inference.transcribe(media: meeting.media, directory: directory, track: .microphone, start: start, end: min(meeting.duration, start + inferenceWindow))
            transcript.segments.append(contentsOf: segments)
            print("ASR \(Timestamp.format(min(meeting.duration, start + inferenceWindow)))/\(Timestamp.format(meeting.duration))")
        }
        try await archive.saveTranscript(transcript, meeting: meeting, asr: true)
        let asrTime = Date().timeIntervalSince(before)
        print("ASR completed in \(asrTime)s. Identifying speakers…")
        let diarizationStart = Date()
        transcript = try await inference.identifySpeakers(meeting: meeting, transcript: transcript, directory: directory) { fraction in print("Speakers \(Int(fraction * 100))%") }
        try await archive.saveTranscript(transcript, meeting: meeting, original: true)
        await inference.unloadAll()
        meeting.state = .ready; meeting.saveRevision += 1; try await archive.save(meeting)
        print("READY: \(directory.path)\nSegments: \(transcript.segments.count), speakers: \(transcript.speakerNames.count), ASR seconds: \(asrTime), diarization seconds: \(Date().timeIntervalSince(diarizationStart))")
        guard !transcript.segments.isEmpty else { throw MeetingError.message("Nessun testo nella fixture vocale.") }
        if input.lastPathComponent == "bilingual-meeting.wav" {
            let text = transcript.segments.map(\.text).joined(separator: " ").lowercased()
            guard text.contains("budget"), text.contains("release"), text.contains("feature flag") else { throw MeetingError.message("La fixture bilingue ha perso contenuto italiano o inglese.") }
        }
        if args.contains("--codex") {
            let run = RecapRun(revision: transcript.revision, language: transcript.predominantLanguage, screenshots: [])
            let result = try await CodexService().generate(meeting: meeting, transcript: transcript, directory: directory, run: run, executable: CodexService.executable(), model: CodexService.configuredModel()) { print($0) }
            try await archive.saveRecap(result, run: run, meeting: meeting, transcript: transcript)
            var complete = run; complete.state = .completed; meeting.recapRuns.append(complete); meeting.saveRevision += 1; try await archive.save(meeting)
            print("CODEX RECAP COMPLETE")
        }
    }
    static func diagnoseAudio(directory: URL, start: Double, end: Double, transcribe: Bool) async throws {
        let meeting = try ArchiveStore.decoder().decode(Meeting.self, from: Data(contentsOf: directory.appendingPathComponent("meeting.json")))
        guard meeting.title.hasPrefix("TEST "), end > start, end - start <= 7200, transcribe || end - start <= 24 else { throw MeetingError.message("La diagnostica accetta solo registrazioni di test e lavora su finestre limitate.") }
        let samples = try AudioIO.window(media: meeting.media, directory: directory, track: .microphone, start: start, end: min(end, start + 24))
        let ranges = SpeechWindows.ranges(samples: samples)
        print("AUDIO PROBE: rms=\(AudioIO.energy(samples)); ranges=\(ranges.map { Double($0.count) / 16000 })"); fflush(stdout)
        guard transcribe else { return }
        let inference = LocalInference()
        var segments: [TranscriptSegment] = []
        for offset in stride(from: start, to: end, by: 24) {
            segments += try await inference.transcribe(media: meeting.media, directory: directory, track: .microphone, start: offset, end: min(end, offset + 24))
            print("LOCAL RANGE: \(Int(offset))–\(Int(min(end, offset + 24))) seconds"); fflush(stdout)
        }
        await inference.unloadAll()
        let output = URL(fileURLWithPath: ".local/diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try ArchiveStore.encoder().encode(segments).write(to: output.appendingPathComponent("\(meeting.id.uuidString)-\(Int(start)).json"), options: .atomic)
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        let numbers = ["1": "uno", "2": "due", "3": "tre"]
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map { numbers[String($0)] ?? String($0) })
        print("LOCAL DIAGNOSTIC: segments=\(segments.count); expected tokens=\(["uno", "due", "tre", "prova"].filter { words.contains($0) }.joined(separator: ","))")
    }
    static func recapFixture(directory: URL, images: [String]) async throws {
        var meeting = try ArchiveStore.decoder().decode(Meeting.self, from: Data(contentsOf: directory.appendingPathComponent("meeting.json")))
        guard meeting.title.hasPrefix("QA ·"), meeting.state == .ready else { throw MeetingError.message("Questo comando accetta solo le fixture sintetiche QA pronte.") }
        let archive = try ArchiveStore(root: directory.deletingLastPathComponent())
        let transcript = try await archive.transcript(meeting)
        for (index, image) in images.enumerated() {
            let input = URL(fileURLWithPath: image)
            let path = "screenshots/\(UUID().uuidString).jpg"
            try FileManager.default.copyItem(at: input, to: directory.appendingPathComponent(path))
            meeting.screenshots.append(Screenshot(path: path, time: Double(index * 12), source: "Controlled capture fixture", reasons: [.significantChange]))
        }
        var run = RecapRun(revision: transcript.revision, language: transcript.predominantLanguage, screenshots: meeting.screenshots.map(\.id))
        meeting.recapRuns.append(run); meeting.saveRevision += 1; try await archive.save(meeting)
        let result = try await CodexService().generate(meeting: meeting, transcript: transcript, directory: directory, run: run, executable: CodexService.executable(), model: CodexService.configuredModel()) { print($0) }
        try await archive.saveRecap(result, run: run, meeting: meeting, transcript: transcript)
        run.state = .completed; meeting.recapRuns[meeting.recapRuns.count - 1] = run; meeting.saveRevision += 1; try await archive.save(meeting)
        print("MULTIMODAL CODEX COMPLETE: \(meeting.screenshots.count) images; \(transcript.segments.count) transcript segments")
    }
    @MainActor static func launchScreenFixture(audioPath: String?) {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 900, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Meeting Assistant — Capture Fixture"
        window.level = .floating; window.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary]
        window.contentView = NSHostingView(rootView: CaptureFixtureView())
        window.makeKeyAndOrderFront(nil)
        let second = NSWindow(contentRect: NSRect(x: 220, y: 220, width: 900, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        second.title = "Meeting Assistant — Second Capture Fixture"; second.contentView = NSHostingView(rootView: CaptureFixtureView()); second.orderBack(nil)
        second.level = .floating; second.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary]
        fixtureWindows = [window, second]
        if let audioPath { fixtureAudio = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: audioPath)); fixtureAudio?.numberOfLoops = -1; fixtureAudio?.volume = 0.5; fixtureAudio?.play() }
        app.activate(ignoringOtherApps: true); app.run()
    }
}

private struct CaptureFixtureView: View {
    @State private var slide = 0
    let slides = [
        ("SPRINT REVIEW", "Decision: release on Friday", "Owner: Luca · Tests due Thursday · Budget €2,000"),
        ("OPEN QUESTIONS", "Customer approval is pending", "Marta will ask tomorrow. Feature flag stays disabled."),
        ("DEPLOYMENT", "Verify logs after launch", "Document the rollout. Review errors. Confirm customer sign-off.")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 35) {
            Text("CONTROLLED CAPTURE FIXTURE").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(slides[slide].0).font(.system(size: 50, weight: .bold))
            Text(slides[slide].1).font(.title)
            Text(slides[slide].2).font(.title3)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in Text(context.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }.padding(50).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
            .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in slide = (slide + 1) % slides.count }
    }
}
