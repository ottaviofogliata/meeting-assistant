import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import ScreenCaptureKit
import MeetingCore

public struct MicrophoneDevice: Identifiable { public var id: UInt32; public var name: String }
private final class MicrophoneActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ProcessInfo.processInfo.systemUptime
    func mark() { lock.lock(); last = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    var secondsSinceCallback: Double { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime - last }
}
public enum CaptureDevices {
    public static var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) { case .authorized: "Autorizzato"; case .notDetermined: "Da autorizzare al primo avvio"; case .denied: "Non autorizzato"; default: "Accesso limitato" }
    }
    public static func microphones() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &input, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?; var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name)
            return MicrophoneDevice(id: device, name: name?.takeRetainedValue() as String? ?? "Microfono")
        }
    }
}

private final class SegmentSink: @unchecked Sendable {
    let queue: DispatchQueue
    private let budget = AudioQueueBudget()
    private let directory: URL
    private let track: AudioTrack
    private let clock: RecordingClock
    private var file: AVAudioFile?
    private var start: Double = 0
    private var frames: AVAudioFramePosition = 0
    private var rate: Double = 48000
    private var path = ""
    private var closed: [MediaSegment] = []
    private var lastLevel: Double = 0
    var segmentDuration: Double = 2
    var onSegment: @Sendable (MediaSegment) -> Void
    var onError: @Sendable (String) -> Void
    var onLevel: @Sendable (Float) -> Void
    init(directory: URL, track: AudioTrack, clock: RecordingClock, onSegment: @escaping @Sendable (MediaSegment) -> Void, onError: @escaping @Sendable (String) -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        self.directory = directory; self.track = track; self.clock = clock; self.onSegment = onSegment; self.onError = onError; self.onLevel = onLevel
        queue = DispatchQueue(label: "meeting.audio.\(track.rawValue)", qos: .userInitiated)
    }
    func receive(_ buffer: AVAudioPCMBuffer, host: Double) {
        guard clock.isActive(at: host), buffer.frameLength > 0 else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let byteCount = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
        guard budget.reserve(seconds: duration, bytes: byteCount) else { onError("Il salvataggio audio non riesce a tenere il passo. La registrazione viene fermata per conservare i dati acquisiti."); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { budget.release(seconds: duration, bytes: byteCount); return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices { if let from = source[index].mData, let to = destination[index].mData { memcpy(to, from, Int(source[index].mDataByteSize)) } }
        let offset = clock.elapsed(at: host)
        queue.async { [self] in
            defer { budget.release(seconds: duration, bytes: byteCount) }
            do {
                if file == nil || abs(offset - (start + Double(frames) / rate)) > 0.2 || rate != copy.format.sampleRate { finishSegment(); try open(format: copy.format, start: offset) }
                try file?.write(from: copy); frames += AVAudioFramePosition(copy.frameLength)
                if host - lastLevel > 0.15, let data = copy.floatChannelData?[0] {
                    lastLevel = host
                    var energy: Float = 0
                    for i in stride(from: 0, to: Int(copy.frameLength), by: 8) { energy += data[i] * data[i] }
                    onLevel(sqrt(energy / Float(max(1, Int(copy.frameLength) / 8))))
                }
                if Double(frames) / rate >= segmentDuration { finishSegment() }
            } catch { onError("Errore di salvataggio audio: \(error.localizedDescription)") }
        }
    }
    private func open(format: AVAudioFormat, start: Double) throws {
        self.start = start; rate = format.sampleRate; frames = 0
        path = "capture/audio/\(track.rawValue)-\(UUID().uuidString).caf"
        file = try AVAudioFile(forWriting: directory.appendingPathComponent(path), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let metadata = MediaSegment(path: path, start: start, duration: 0, track: track)
        try ArchiveStore.encoder().encode(metadata).write(to: directory.appendingPathComponent(path + ".json"), options: .atomic)
    }
    private func finishSegment() {
        guard file != nil else { return }; file = nil
        if frames > 0 {
            let segment = MediaSegment(path: path, start: start, duration: Double(frames) / rate, track: track)
            do { try ArchiveStore.encoder().encode(segment).write(to: directory.appendingPathComponent(path + ".json"), options: .atomic) } catch { onError(error.localizedDescription) }
            closed.append(segment); onSegment(segment)
        }
        frames = 0
    }
    func flush() async -> [MediaSegment] {
        await withCheckedContinuation { continuation in queue.async { self.finishSegment(); continuation.resume(returning: self.closed) } }
    }
}

public final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static func requestMicrophoneAccess() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MeetingError.message("Consenti l'accesso al microfono in Impostazioni di Sistema → Privacy e sicurezza → Microfono.") }
    }
    @MainActor private var engine: AVAudioEngine?
    @MainActor private var wantsMicrophone = false
    @MainActor private var configurationObserver: NSObjectProtocol?
    @MainActor private var configurationTask: Task<Void, Never>?
    @MainActor private var microphoneWatchdog: Task<Void, Never>?
    private let microphoneActivity = MicrophoneActivity()
    private var stream: SCStream?
    private var mic: SegmentSink?
    private var system: SegmentSink?
    private var options = RecordingOptions()
    private let queue = DispatchQueue(label: "meeting.system-audio", qos: .userInitiated)
    private let clock: RecordingClock
    public var onSegment: @Sendable (MediaSegment) -> Void = { _ in }
    public var onError: @Sendable (String) -> Void = { _ in }
    public var onLevel: @Sendable (Float) -> Void = { _ in }
    public init(clock: RecordingClock) { self.clock = clock }
    @MainActor public func start(options: RecordingOptions, directory: URL) async throws {
        try await Self.requestMicrophoneAccess()
        self.options = options
        mic = SegmentSink(directory: directory, track: .microphone, clock: clock, onSegment: onSegment, onError: onError, onLevel: onLevel)
        system = SegmentSink(directory: directory, track: .system, clock: clock, onSegment: onSegment, onError: onError, onLevel: { _ in })
        let engine = AVAudioEngine(); self.engine = engine
        if options.mode == .online {
            do { try engine.inputNode.setVoiceProcessingEnabled(true) }
            catch { onError("Elaborazione voce nativa non disponibile: \(error.localizedDescription). Gli originali vengono conservati.") }
        }
        if options.microphoneID != 0, let unit = engine.inputNode.audioUnit {
            var device = options.microphoneID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw MeetingError.message("Il microfono selezionato non è disponibile (\(status)).") }
        }
        try installMicrophoneTap(on: engine)
        wantsMicrophone = true
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.microphoneConfigurationChanged() }
        }
        engine.prepare(); try engine.start()
        if options.mode == .online { try await startSystemAudio() }
        microphoneWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                guard let self else { break }
                if self.wantsMicrophone && self.microphoneActivity.secondsSinceCallback > 4 { self.microphoneConfigurationChanged(force: true) }
            }
        }
    }
    @MainActor private func installMicrophoneTap(on engine: AVAudioEngine) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingError.message("Il microfono non fornisce un formato audio valido.") }
        let sink = mic
        let activity = microphoneActivity; activity.mark()
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            activity.mark()
            let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / buffer.format.sampleRate
            sink?.receive(buffer, host: host)
        }
    }
    @MainActor private func microphoneConfigurationChanged(force: Bool = false) {
        configurationTask?.cancel()
        configurationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self, self.wantsMicrophone, let engine = self.engine, force || !engine.isRunning else { return }
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                try self.installMicrophoneTap(on: engine)
                engine.prepare(); try engine.start()
            } catch is CancellationError {}
            catch { self?.onError("Il microfono deve essere riconnesso: \(error.localizedDescription)") }
        }
    }
    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw MeetingError.message("Nessun display disponibile per l'audio di sistema.") }
        let filter: SCContentFilter
        if options.allSystemAudio { filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []) }
        else {
            guard let pid = options.audioApplication?.pid, let app = content.applications.first(where: { $0.processID == pid }) else { throw MeetingError.message("Seleziona l'app della riunione oppure tutto l'audio del Mac.") }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
        let config = SCStreamConfiguration(); config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true; config.sampleRate = 48000; config.channelCount = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream; try await stream.startCapture()
    }
    @MainActor public func pause() async -> [MediaSegment] {
        wantsMicrophone = false; configurationTask?.cancel()
        engine?.stop(); try? await stream?.stopCapture(); stream = nil
        await drainSystemCallbacks()
        return await flush()
    }
    @MainActor public func resume() async throws { wantsMicrophone = true; try engine?.start(); if options.mode == .online { try await startSystemAudio() } }
    @MainActor public func stop() async -> [MediaSegment] {
        wantsMicrophone = false; configurationTask?.cancel(); configurationTask = nil
        microphoneWatchdog?.cancel(); microphoneWatchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        try? await stream?.stopCapture(); stream = nil
        await drainSystemCallbacks()
        return await flush()
    }
    private func flush() async -> [MediaSegment] { let a = await mic?.flush() ?? []; let b = await system?.flush() ?? []; return a + b }
    private func drainSystemCallbacks() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    public func stream(_ stream: SCStream, didStopWithError error: Error) { onError("Audio di sistema interrotto: \(error.localizedDescription)") }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else { return }
        system?.receive(pcm, host: sampleBuffer.presentationTimeStamp.seconds)
    }
}
