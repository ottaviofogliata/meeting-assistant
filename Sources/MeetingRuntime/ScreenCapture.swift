import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import Vision
import CoreImage
import MeetingCore

public enum ScreenSources {
    public static func available() async throws -> ([VisualSource], [AudioApplication]) {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let displays = content.displays.enumerated().map { VisualSource(kind: .display, number: $0.element.displayID, title: "Schermo \($0.offset + 1)", width: $0.element.width, height: $0.element.height) }
        let windows = content.windows.filter { $0.frame.width >= 280 && $0.frame.height >= 160 && (0...3).contains($0.windowLayer) && !($0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && $0.owningApplication?.applicationName != "WindowManager" && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }.map {
            VisualSource(kind: .window, number: $0.windowID, title: "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "Finestra")", width: Int($0.frame.width * 2), height: Int($0.frame.height * 2))
        }.sorted { $0.title < $1.title }
        let applications = content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }.map { AudioApplication(pid: $0.processID, name: $0.applicationName, bundleID: $0.bundleIdentifier) }.sorted { $0.name < $1.name }
        return (displays + windows, applications)
    }
    static func filter(_ source: VisualSource) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if source.kind == .window, let window = content.windows.first(where: { $0.windowID == source.number }) {
            guard window.frame.width >= 280, window.frame.height >= 160 else { throw MeetingError.message("La finestra selezionata è una miniatura di Stage Manager o non è disponibile. Riportala nel gruppo di finestre attivo, poi aggiorna le sorgenti.") }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        if source.kind == .display, let display = content.displays.first(where: { $0.displayID == source.number }) { return SCContentFilter(display: display, excludingWindows: []) }
        throw MeetingError.message("La sorgente visiva selezionata non è più disponibile.")
    }
}

public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "meeting.screen", qos: .utility)
    private let imageQueue = DispatchQueue(label: "meeting.screenshot", qos: .utility)
    private let clock: RecordingClock
    private var stream: SCStream?
    private var source: VisualSource?
    private var directory: URL?
    private var options = RecordingOptions()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var previous: [UInt8] = []
    private var accepted: [UInt8] = []
    private var stable = 0
    private var lastChange: Double = -10
    private var pending: Set<ScreenshotReason> = []
    private var pendingSlot: Int?
    private var capturing = false
    private var snapshotWaiters: [() -> Void] = []
    private var analysisTimer: DispatchSourceTimer?
    private var faces: [IgnoreRegion] = []
    private var lastPixel: CVPixelBuffer?
    private var lastFrameCopy: Double = -10
    private var captureStart: Double = 0
    private var warnedNoFrame = false
    private var video: VideoRecorder?
    private var videoFailed = false
    private var acceptedText = ""
    private var textAnalysisRunning = false
    private var lastTextAnalysis: Double = -10
    private var stopping = false
    public var onScreenshot: @Sendable (Screenshot) -> Void = { _ in }
    public var onVideo: @Sendable (MediaSegment) -> Void = { _ in }
    public var onError: @Sendable (String) -> Void = { _ in }
    public init(clock: RecordingClock) { self.clock = clock }
    public func start(options: RecordingOptions, directory: URL, reason: ScreenshotReason = .recordingStart) async throws {
        guard let source = options.visualSource else { throw MeetingError.message("Seleziona uno schermo o una finestra.") }
        self.options = options; self.source = source; self.directory = directory
        captureStart = clock.elapsed()
        let filter = try await ScreenSources.filter(source)
        let width = max(2, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
        let height = max(2, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        let scale = options.video ? min(1, min(1920 / Double(width), 1080 / Double(height))) : min(1, 2560 / Double(max(width, height)))
        let config = SCStreamConfiguration()
        config.width = max(2, Int(Double(width) * scale) / 2 * 2)
        config.height = max(2, Int(Double(height) * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: options.video ? 30 : 1)
        config.queueDepth = 3; config.showsCursor = false; config.pixelFormat = kCVPixelFormatType_32BGRA; config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true; config.shouldBeOpaque = true
        queue.sync { previous = []; accepted = []; stable = 0; pending = [reason]; pendingSlot = nil; lastPixel = nil; acceptedText = ""; stopping = false }
        let stream = SCStream(filter: filter, configuration: config, delegate: self); self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sampleFrame() }
        analysisTimer = timer; timer.resume()
    }
    public func request(_ reason: ScreenshotReason, slot: Int? = nil) {
        queue.async { self.pending.insert(reason); if let slot { self.pendingSlot = slot }; self.captureIfRequested() }
    }
    public func setIgnoredRegions(_ regions: [IgnoreRegion]) { queue.async { self.options.ignoredRegions = regions; self.accepted = [] } }
    public func stop(finalImage: Bool = true) async -> [MediaSegment] {
        let videoEnd = clock.elapsed()
        queue.sync { stopping = true }
        analysisTimer?.cancel(); analysisTimer = nil
        do { try await stream?.stopCapture() } catch { onError(Self.describe(error)) }
        await withCheckedContinuation { continuation in
            queue.async {
                if finalImage, self.lastPixel != nil { self.pending.insert(.recordingEnd) }
                self.snapshotWaiters.append { continuation.resume() }; self.captureIfRequested()
            }
        }
        let (recorder, pixel, end): (VideoRecorder?, CVPixelBuffer?, Double) = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: (self.video, self.lastPixel, videoEnd)) }
        }
        var segments: [MediaSegment] = []
        if let recorder {
            do { if let segment = try await recorder.finish(at: end, finalPixel: pixel) { segments = [segment]; onVideo(segment) } }
            catch { onError("Finalizzazione video: \(Self.describe(error))") }
        }
        queue.sync { lastPixel = nil; video = nil }
        stream = nil
        return segments
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.stopping = true; self.analysisTimer?.cancel(); self.analysisTimer = nil; self.lastPixel = nil; self.pending = []; self.drainSnapshotWaiters(); self.onError("Cattura schermo interrotta: \(Self.describe(error))") }
    }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopping, sampleBuffer.isValid, clock.isActive(), let pixel = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue {
            if status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.suspended.rawValue { lastPixel = nil }
            return
        }
        if options.video, !videoFailed, let directory {
            do {
                if video == nil { video = try VideoRecorder(directory: directory, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel), start: clock.elapsed(at: sampleBuffer.presentationTimeStamp.seconds), firstPTS: sampleBuffer.presentationTimeStamp) }
                try video?.append(pixel, at: sampleBuffer.presentationTimeStamp)
            } catch { videoFailed = true; onError("Registrazione video: \(Self.describe(error))") }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameCopy >= 0.9 || lastPixel == nil else { return }
        // Never retain ScreenCaptureKit's pooled IOSurface through OCR/analysis:
        // that can exhaust the small server pool while video encoding is active.
        guard let copy = copyFrame(pixel) else { return }
        lastPixel = copy; lastFrameCopy = now
        if !pending.isEmpty { captureIfRequested() }
    }
    private func copyFrame(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(input); let height = CVPixelBufferGetHeight(input)
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess, let result else { return nil }
        CVPixelBufferLockBaseAddress(input, .readOnly); CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []); CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        guard let from = CVPixelBufferGetBaseAddress(input), let to = CVPixelBufferGetBaseAddress(result), CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(input); let targetStride = CVPixelBufferGetBytesPerRow(result)
        for row in 0..<height { memcpy(to.advanced(by: row * targetStride), from.advanced(by: row * sourceStride), width * 4) }
        return result
    }
    private func sampleFrame() {
        guard clock.isActive() else { return }
        guard let pixel = lastPixel else {
            if !warnedNoFrame, clock.elapsed() - captureStart > 6 { warnedNoFrame = true; onError("La sorgente visiva non sta fornendo fotogrammi. Verifica la finestra o scegli un'altra sorgente; l'audio continua a essere salvato.") }
            return
        }
        let time = clock.elapsed(); let image = CIImage(cvPixelBuffer: pixel)
        let scale = CGAffineTransform(scaleX: 320 / image.extent.width, y: 180 / image.extent.height)
        guard let small = context.createCGImage(image.transformed(by: scale), from: CGRect(x: 0, y: 0, width: 320, height: 180)) else { return }
        var gray = [UInt8](repeating: 0, count: 320 * 180)
        gray.withUnsafeMutableBytes { bytes in
            if let drawing = CGContext(data: bytes.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) { drawing.draw(small, in: CGRect(x: 0, y: 0, width: 320, height: 180)) }
        }
        if Int(time) % 5 == 0 {
            let request = VNDetectFaceRectanglesRequest(); let scale = 640 / image.extent.width
            if let faceImage = context.createCGImage(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), from: CGRect(x: 0, y: 0, width: 640, height: image.extent.height * scale)) {
                try? VNImageRequestHandler(cgImage: faceImage).perform([request])
                faces = (request.results ?? []).map { let b = $0.boundingBox; return IgnoreRegion(x: max(0, b.midX - b.width * 1.25), y: max(0, 1 - b.maxY - b.height * 0.5), width: min(1, b.width * 2.5), height: min(1, b.height * 2.5)) }
            }
        }
        let masks = options.ignoredRegions + faces
        func difference(_ other: [UInt8]) -> Double {
            guard other.count == gray.count else { return 1 }
            var changed = 0; var total = 0
            for i in gray.indices {
                let x = Double(i % 320) / 320; let y = Double(i / 320) / 180
                if masks.contains(where: { x >= $0.x && x <= $0.x + $0.width && y >= $0.y && y <= $0.y + $0.height }) { continue }
                total += 1; if abs(Int(gray[i]) - Int(other[i])) > 24 { changed += 1 }
            }
            return Double(changed) / Double(max(1, total))
        }
        if accepted.isEmpty { accepted = gray }
        stable = difference(previous) < 0.025 ? stable + 1 : 0
        let delta = difference(accepted)
        if stable >= 1, delta > 0.008, time - lastChange >= 5 { pending.insert(.significantChange); lastChange = time; accepted = gray }
        else if stable >= 1, delta > 0.0002, time - lastChange >= 5, time - lastTextAnalysis >= 3, !textAnalysisRunning {
            checkSmallTextChange(pixel: pixel, fingerprint: gray, time: time)
        }
        previous = gray
        captureIfRequested()
    }
    private func captureIfRequested() {
        guard !capturing else { return }
        guard !pending.isEmpty, let pixel = lastPixel, let source, let directory else { drainSnapshotWaiters(); return }
        capturing = true
        let reasons = pending; let slot = pendingSlot; pending = []; pendingSlot = nil
        let time = clock.elapsed(); let sourceTitle = source.title
        var hash: UInt64 = 0
        for index in 0..<64 where previous.count >= 320 * 180 { let x = index % 8 * 40; let y = index / 8 * 20; if previous[y * 320 + x] > previous[y * 320 + min(319, x + 20)] { hash |= 1 << index } }
        let signature = hash
        imageQueue.async {
            do {
                let input = CIImage(cvPixelBuffer: pixel)
                guard let image = self.context.createCGImage(input, from: input.extent) else { throw MeetingError.message("Fotogramma non leggibile.") }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.recognitionLanguages = ["it-IT", "en-US"]; request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                let path = "screenshots/\(UUID().uuidString).jpg"
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw MeetingError.message("Impossibile codificare lo screenshot.") }
                try data.write(to: directory.appendingPathComponent(path), options: .atomic)
                let screenshot = Screenshot(path: path, time: time, source: sourceTitle, reasons: reasons, periodicSlot: slot, signature: signature, text: text)
                self.queue.async { self.acceptedText = text; self.onScreenshot(screenshot); self.finishSnapshot() }
            } catch { self.queue.async { self.onError(Self.describe(error)); self.finishSnapshot() } }
        }
    }
    private func finishSnapshot() { capturing = false; if pending.isEmpty { drainSnapshotWaiters() } else { captureIfRequested() } }
    private func checkSmallTextChange(pixel: CVPixelBuffer, fingerprint: [UInt8], time: Double) {
        textAnalysisRunning = true; lastTextAnalysis = time
        imageQueue.async {
            let input = CIImage(cvPixelBuffer: pixel)
            var text = ""
            if let image = self.context.createCGImage(input, from: input.extent) {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["it-IT", "en-US"]
                try? VNImageRequestHandler(cgImage: image).perform([request])
                text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            let observed = text
            self.queue.async {
                self.textAnalysisRunning = false
                guard !self.stopping, !observed.isEmpty, ScreenText.changed(from: self.acceptedText, to: observed) else { return }
                self.acceptedText = observed; self.accepted = fingerprint; self.lastChange = time; self.pending.insert(.significantChange); self.captureIfRequested()
            }
        }
    }
    private func drainSnapshotWaiters() { let callbacks = snapshotWaiters; snapshotWaiters = []; callbacks.forEach { $0() } }
    private static func describe(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.localizedDescription) (\(value.domain) \(value.code))\(value.userInfo[NSUnderlyingErrorKey].map { ": \($0)" } ?? "")"
    }
}
