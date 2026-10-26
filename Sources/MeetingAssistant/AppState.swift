import SwiftUI
import AppKit
import AVFoundation
import MeetingCore
import MeetingRuntime

@MainActor final class AppState: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedID: UUID?
    @Published var transcript = TranscriptDocument()
    @Published var recap: RecapDocument?
    @Published var options = RecordingOptions()
    @Published var title = ""
    @Published var sources: [VisualSource] = []
    @Published var applications: [AudioApplication] = []
    @Published var microphones = CaptureDevices.microphones()
    @Published var archiveRoot: URL
    @Published var status = "Pronto per una nuova riunione"
    @Published var error: String?
    @Published var busy = false
    @Published var progress: Double?
    @Published var activeID: UUID?
    @Published var level: Float = 0
    @Published var elapsed: Double = 0
    @Published var transcriptionLag: Double = 0
    @Published var provisional = ""
    @Published var codexRunning = false
    @Published var codexPath: String { didSet { UserDefaults.standard.set(codexPath, forKey: "codexPath") } }
    @Published var codexModel: String { didSet { UserDefaults.standard.set(codexModel, forKey: "codexModel") } }
    @Published var player: AVPlayer?
    @Published var playbackTime: Double = 0
    @Published var playbackMuted = false { didSet { player?.isMuted = playbackMuted } }
    @Published var selectedTab = "transcript"
    @Published var inspectedScreenshot: Screenshot?
    @Published var archiveUnavailable: String?
    private var archive: ArchiveStore
    private let inference = LocalInference()
    private let codex = CodexService()
    private var clock = RecordingClock()
    private var audio: AudioCapture?
    private var screen: ScreenCapture?
    private var timer: Timer?
    private var asrTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var recapTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var editTask: Task<Void, Never>?
    private var committed: [AudioTrack: Double] = [:]
    private var decodedThrough: [AudioTrack: Double] = [:]
    private var provisionalIDs: [AudioTrack: Set<UUID>] = [:]
    private var nextPeriodic = 60
    private var timeObserver: Any?
    private var activeTranscript = TranscriptDocument()
    private var processingID: UUID?
    private var pendingLocalIDs: [UUID] = []
    private var startingRecording = false
    private var shuttingDown = false
    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var active: Meeting? { meetings.first { $0.id == activeID } }
    var isRecording: Bool { active?.state.isCapturing == true }
    var canInterruptProcessing: Bool { processingID != nil && activeID == nil && !startingRecording }
    var canStart: Bool { !shuttingDown && archiveUnavailable == nil && !startingRecording && !isRecording && (!busy || canInterruptProcessing) && (options.mode == .inPerson || options.visualSource != nil) && (options.mode != .online || options.allSystemAudio || options.audioApplication != nil) }
    init() {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
        let root = UserDefaults.standard.string(forKey: "archiveRoot").map { URL(fileURLWithPath: $0) } ?? fallback
        archiveRoot = root
        do { archive = try ArchiveStore(root: root) }
        catch {
            archive = try! ArchiveStore(root: root, createIfNeeded: false)
            archiveUnavailable = error.localizedDescription
            self.error = "Archivio non disponibile. Scegli una cartella scrivibile nelle impostazioni. \(error.localizedDescription)"
        }
        codexPath = UserDefaults.standard.string(forKey: "codexPath") ?? CodexService.executable()
        codexModel = UserDefaults.standard.string(forKey: "codexModel") ?? CodexService.configuredModel()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
        Task { await reload() }
    }
    func reload() async {
        guard archiveUnavailable == nil else { return }
        do {
            var restored = try await archive.scan()
            for index in restored.indices {
                if restored[index].state != .ready && restored[index].state != .failed {
                    restored[index].state = .interrupted
                    restored[index].error = "Registrazione recuperata. Premi Riprendi elaborazione per completare il materiale salvato."
                }
                if restored[index].state == .interrupted || restored[index].state == .failed {
                    let folder = try archive.directory(restored[index])
                    let sidecars = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("capture/audio"), includingPropertiesForKeys: nil)) ?? []
                    for sidecar in sidecars where sidecar.pathExtension == "json" {
                        guard var segment = try? ArchiveStore.decoder().decode(MediaSegment.self, from: Data(contentsOf: sidecar)), let url = try? ArchiveStore.safeURL(segment.path, inside: folder) else { continue }
                        if segment.duration <= 0, let audio = try? AVAudioFile(forReading: url) { segment.duration = Double(audio.length) / audio.processingFormat.sampleRate }
                        if segment.duration > 0, !restored[index].media.contains(where: { $0.path == segment.path }) { restored[index].media.append(segment) }
                    }
                    let videos = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("capture/video"), includingPropertiesForKeys: nil)) ?? []
                    for sidecar in videos where sidecar.pathExtension == "json" {
                        guard var segment = try? ArchiveStore.decoder().decode(MediaSegment.self, from: Data(contentsOf: sidecar)), let url = try? ArchiveStore.safeURL(segment.path, inside: folder) else { continue }
                        if segment.duration <= 0 { segment.duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0 }
                        if segment.duration > 0, !restored[index].media.contains(where: { $0.path == segment.path }) { restored[index].media.append(segment) }
                    }
                    restored[index].duration = max(restored[index].duration, restored[index].media.map { $0.start + $0.duration }.max() ?? 0)
                }
                for run in restored[index].recapRuns.indices where restored[index].recapRuns[run].state == .running { restored[index].recapRuns[run].state = .cancelled; restored[index].recapRuns[run].error = "L'app è stata chiusa durante l'elaborazione." }
                restored[index].saveRevision += 1; try await archive.save(restored[index])
            }
            meetings = restored
        } catch { self.error = error.localizedDescription }
    }
    func chooseArchive() {
        guard !isRecording && !busy && !codexRunning else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Usa come archivio"; panel.directoryURL = archiveRoot
        if panel.runModal() == .OK, let url = panel.url {
            do { archive = try ArchiveStore(root: url); archiveUnavailable = nil; archiveRoot = url; UserDefaults.standard.set(url.path, forKey: "archiveRoot"); selectedID = nil; Task { await reload() } }
            catch { self.error = error.localizedDescription }
        }
    }
    func refreshSources() async {
        do {
            status = "Ricerca di schermi, finestre e applicazioni…"
            let (sources, apps) = try await ScreenSources.available(); self.sources = sources; applications = apps
            if options.visualSource == nil { options.visualSource = sources.first }
            status = "Sorgenti disponibili"
        } catch { self.error = "Consenti la registrazione schermo e audio in Impostazioni di Sistema → Privacy e sicurezza. \(error.localizedDescription)" }
    }
    func prepareModels() {
        guard !busy && !isRecording else { return }; busy = true; status = "Preparazione di Whisper turbo. Al primo avvio il modello viene scaricato…"
        Task {
            defer { busy = false }
            do {
                try await inference.prepareTranscription(); await inference.unloadAll()
                status = "Preparazione dei modelli parlanti sul Mac…"; try await inference.prepareSpeakerModels()
                status = "Tutti i modelli sono disponibili sul Mac"
            }
            catch { self.error = error.localizedDescription; status = "Preparazione non completata"; await inference.unloadAll() }
        }
    }
    func start() {
        guard canStart else { return }
        let previousTask = processingID == nil ? nil : processingTask
        if let id = processingID, !pendingLocalIDs.contains(id) { pendingLocalIDs.append(id) }
        previousTask?.cancel(); startingRecording = true; busy = true; status = "Preparazione di Whisper turbo…"; error = nil
        captureTask = Task { [self] in
            do {
                await previousTask?.value; busy = true
                try await archive.preflight()
                try await AudioCapture.requestMicrophoneAccess()
                status = "Verifica dei modelli locali…"; try await inference.prepareSpeakerModels()
                status = "Preparazione di Whisper turbo…"
                try await inference.prepareTranscription()
                try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
                var new = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Riunione \(Date().formatted(date: .abbreviated, time: .shortened))" : title, options: options)
                if new.options.mode == .inPerson { new.options.video = false }
                try await archive.save(new)
                let directory = try archive.directory(new)
                activeID = new.id; selectedID = new.id; meetings.insert(new, at: 0)
                activeTranscript = TranscriptDocument(); transcript = activeTranscript; recap = nil; provisional = ""; elapsed = 0; transcriptionLag = 0
                committed = [:]; decodedThrough = [:]; provisionalIDs = [:]; nextPeriodic = 60
                clock = RecordingClock(); clock.start()
                update(new.id) { $0.events = [.init("start", at: 0)] }
                let audio = AudioCapture(clock: clock); self.audio = audio
                let id = new.id
                audio.onSegment = { [weak self] segment in Task { @MainActor in self?.addMedia(segment, to: id) } }
                audio.onError = { [weak self] warning in Task { @MainActor in self?.captureWarning(warning, id: id) } }
                audio.onLevel = { [weak self] level in Task { @MainActor in self?.level = level } }
                try await audio.start(options: new.options, directory: directory)
                if new.options.mode.hasScreen { try await startScreen(meeting: new, reason: .recordingStart) }
                startingRecording = false; busy = false; status = "Registrazione in corso"; startASRLoop(id: id)
            } catch {
                clock.pause(); _ = await audio?.stop(); _ = await screen?.stop(finalImage: false); audio = nil; screen = nil
                if let id = activeID { update(id) { $0.state = .interrupted; $0.error = error.localizedDescription } }
                activeID = nil; startingRecording = false; busy = false
                if !Task.isCancelled && !shuttingDown { self.error = error.localizedDescription }; status = "Registrazione non avviata"; await inference.unloadAll(); resumePendingLocalWork()
            }
        }
    }
    private func startScreen(meeting: Meeting, reason: ScreenshotReason) async throws {
        let service = ScreenCapture(clock: clock); screen = service
        let id = meeting.id
        service.onScreenshot = { [weak self] screenshot in Task { @MainActor in self?.addScreenshot(screenshot, to: id) } }
        service.onVideo = { [weak self] segment in Task { @MainActor in self?.addMedia(segment, to: id) } }
        service.onError = { [weak self] warning in Task { @MainActor in self?.captureWarning(warning, id: id) } }
        try await service.start(options: meeting.options, directory: archive.directory(meeting), reason: reason)
    }
    func setTranscription(_ mode: TranscriptionMode) {
        options.transcription = mode
        if let id = activeID { update(id) { $0.options.transcription = mode } }
        if mode == .background { provisional = "" }
    }
    func changeSource(_ source: VisualSource?) {
        guard activeID == nil || !busy else { return }
        var masks = options.ignoredRegionsBySource ?? [:]
        if let previous = options.visualSource { masks[previous.id] = options.ignoredRegions }
        options.visualSource = source; options.ignoredRegionsBySource = masks; options.ignoredRegions = source.flatMap { masks[$0.id] } ?? []
        guard let id = activeID else { return }
        update(id) { $0.options.visualSource = source; $0.options.ignoredRegions = options.ignoredRegions; $0.options.ignoredRegionsBySource = masks; $0.events = ($0.events ?? []) + [.init("source_change", at: clock.elapsed(), detail: source?.title)] }
        guard active?.state == .recording, let meeting = active else { return }
        busy = true; status = "Cambio della sorgente visiva…"
        captureTask = Task {
            defer { busy = false }
            for segment in await screen?.stop(finalImage: false) ?? [] { addMedia(segment, to: id) }; screen = nil
            do { try Task.checkCancellation(); try await startScreen(meeting: meeting, reason: .sourceChange); status = "Registrazione in corso" }
            catch is CancellationError {}
            catch { captureWarning(error.localizedDescription, id: id) }
        }
    }
    func addIgnoredRegion(_ region: IgnoreRegion) {
        options.ignoredRegions.append(region)
        if let id = activeID { update(id) { $0.options.ignoredRegions.append(region) }; screen?.setIgnoredRegions(active?.options.ignoredRegions ?? []) }
    }
    func clearIgnoredRegions() {
        options.ignoredRegions = []
        if let id = activeID { update(id) { $0.options.ignoredRegions = [] }; screen?.setIgnoredRegions([]) }
    }
    func pauseResume() {
        guard let id = activeID, let meeting = active, !busy else { return }
        busy = true
        captureTask = Task {
            defer { busy = false }
            if meeting.state == .recording {
                clock.pause(); update(id) { $0.state = .paused; $0.duration = clock.elapsed(); $0.events = ($0.events ?? []) + [.init("pause", at: clock.elapsed())] }
                for segment in await audio?.pause() ?? [] { addMedia(segment, to: id) }
                for segment in await screen?.stop() ?? [] { addMedia(segment, to: id) }; screen = nil
                update(id) { $0.duration = clock.elapsed() }
                status = "Registrazione in pausa"; level = 0
            } else {
                do {
                    clock.resume(); try await audio?.resume()
                    try Task.checkCancellation()
                    if let current = active, current.options.mode.hasScreen { try await startScreen(meeting: current, reason: .resume) }
                    update(id) { $0.state = .recording; $0.events = ($0.events ?? []) + [.init("resume", at: clock.elapsed())] }; status = "Registrazione in corso"
                } catch { clock.pause(); captureWarning(error.localizedDescription, id: id) }
            }
        }
    }
    func stop() {
        guard let id = activeID, !busy else { return }; busy = true; clock.pause()
        update(id) { $0.state = .finalizingMedia; $0.duration = clock.elapsed(); $0.events = ($0.events ?? []) + [.init("stop", at: clock.elapsed())] }
        processingTask = Task {
            asrTask?.cancel(); await asrTask?.value; asrTask = nil
            for segment in await audio?.stop() ?? [] { addMedia(segment, to: id) }; audio = nil
            for segment in await screen?.stop() ?? [] { addMedia(segment, to: id) }; screen = nil
            activeID = nil; level = 0; provisional = ""
            await finishLocal(id: id)
        }
    }
    func retryLocal(_ meeting: Meeting, select: Bool = true) {
        guard !busy && !isRecording else { return }; busy = true
        if select { selectedID = meeting.id; transcript = TranscriptDocument() }
        activeTranscript = TranscriptDocument()
        committed = [:]; decodedThrough = [:]; provisionalIDs = [:]
        processingTask = Task {
            if let previous = try? await archive.transcript(meeting) { activeTranscript.revision = previous.revision + 1 }
            await finishLocal(id: meeting.id)
        }
    }
    private func finishLocal(id: UUID) async {
        processingID = id
        do {
            update(id) { $0.state = .finalizingTranscript; $0.error = nil }; status = "Completamento trascrizione…"
            guard var meeting = meetings.first(where: { $0.id == id }) else { throw MeetingError.message("Riunione non trovata.") }
            if var saved = try await archive.originalASR(meeting) {
                saved.revision = max(saved.revision, activeTranscript.revision); activeTranscript = saved
            } else { try await processAvailable(id: id, force: true) }
            try Task.checkCancellation()
            activeTranscript.segments.sort { $0.start < $1.start }
            try await archive.saveTranscript(activeTranscript, meeting: meeting, asr: true)
            update(id) { $0.state = .identifyingSpeakers }; status = "Identificazione dei parlanti…"; progress = 0
            meeting = meetings.first(where: { $0.id == id })!
            let result = try await inference.identifySpeakers(meeting: meeting, transcript: activeTranscript, directory: archive.directory(meeting)) { [weak self] fraction in Task { @MainActor in self?.progress = fraction } }
            activeTranscript = result
            try await archive.saveTranscript(result, meeting: meeting, original: true)
            update(id) { $0.state = .ready; $0.error = nil }
            if selectedID == id { transcript = result; await loadPlayer(meetings.first { $0.id == id }!) }
            status = "Trascrizione pronta. Il recap si avvia con Send to Codex."
        } catch is CancellationError {
            update(id) { $0.state = .interrupted; $0.error = "Elaborazione locale sospesa. I materiali sono salvati." }
        } catch { update(id) { $0.state = .failed; $0.error = error.localizedDescription }; self.error = error.localizedDescription; status = "Elaborazione locale da riprovare" }
        await inference.unloadAll(); progress = nil; busy = false; processingID = nil
        resumePendingLocalWork()
    }
    private func resumePendingLocalWork() {
        guard !shuttingDown, !startingRecording, activeID == nil, !busy, !pendingLocalIDs.isEmpty else { return }
        let id = pendingLocalIDs.removeFirst()
        if let meeting = meetings.first(where: { $0.id == id }) { retryLocal(meeting, select: false) }
    }
    private func startASRLoop(id: UUID) {
        asrTask = Task {
            while !Task.isCancelled {
                do { try await processAvailable(id: id, force: false); try await Task.sleep(for: .seconds(0.5)) }
                catch is CancellationError { break }
                catch { captureWarning("Trascrizione in ritardo: \(error.localizedDescription). L'audio continua a essere salvato.", id: id); try? await Task.sleep(for: .seconds(3)) }
            }
        }
    }
    private func processAvailable(id: UUID, force: Bool) async throws {
        guard let initial = meetings.first(where: { $0.id == id }) else { return }
        let directory = try archive.directory(initial)
        for track in [AudioTrack.microphone, .system] {
            while let meeting = meetings.first(where: { $0.id == id }) {
                try Task.checkCancellation()
                let available = meeting.media.filter { $0.track == track }.map { $0.start + $0.duration }.max() ?? 0
                let cursor = committed[track, default: 0]
                guard let window = TranscriptionScheduling.next(available: available, committed: cursor, decodedThrough: decodedThrough[track, default: cursor], mode: meeting.options.transcription, force: force) else { break }
                let start = window.start; let end = window.end
                let showLive = !force && meeting.options.transcription == .realtime
                let callback: (@Sendable (String) -> Void)? = showLive ? liveCallback(for: id) : nil
                let result = try await inference.transcribe(media: meeting.media, directory: directory, track: track, start: start, end: end, provisional: callback)
                let ids = provisionalIDs[track, default: []]
                activeTranscript.segments.removeAll { ids.contains($0.id) }
                activeTranscript.segments.append(contentsOf: result); activeTranscript.segments.sort { $0.start < $1.start }; activeTranscript.revision += 1
                provisionalIDs[track] = Set(result.map(\.id)); decodedThrough[track] = end
                if selectedID == id { transcript = activeTranscript; provisional = "" }
                try await archive.saveTranscript(activeTranscript, meeting: meeting)
                if window.commits { committed[track] = end; provisionalIDs[track] = [] } else { break }
            }
        }
    }
    private func tick() {
        guard let id = activeID, let meeting = active else { return }
        elapsed = clock.elapsed()
        if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index].duration = elapsed }
        if meeting.state == .recording, Int(elapsed) % 5 == 0 {
            update(id) { $0.duration = elapsed }
            if let available = ArchiveStore.availableBytes(at: archiveRoot), available < 256 * 1024 * 1024 {
                captureWarning("Spazio su disco quasi esaurito. La registrazione viene fermata per conservare i materiali acquisiti.", id: id)
            }
        }
        transcriptionLag = [AudioTrack.microphone, .system].map { track in
            let available = meeting.media.filter { $0.track == track }.map { $0.start + $0.duration }.max() ?? 0
            return max(0, available - decodedThrough[track, default: 0])
        }.max() ?? 0
        if meeting.state == .recording, elapsed > 10, elapsed - (meeting.media.filter({ $0.track == .microphone }).map({ $0.start + $0.duration }).max() ?? 0) > 8 {
            captureWarning("Il microfono non invia più audio. Controlla il dispositivo selezionato; gli altri ingressi continuano a essere salvati.", id: id)
        }
        if meeting.state == .recording, meeting.options.mode.hasScreen {
            if elapsed > 900, nextPeriodic % 120 != 0 { nextPeriodic = ((nextPeriodic / 120) + 1) * 120 }
            if elapsed >= Double(nextPeriodic) { screen?.request(.periodic, slot: nextPeriodic); nextPeriodic += ScreenshotPolicy.cadence(at: elapsed) }
            pruneScreenshots(id: id)
        }
    }
    private func liveCallback(for id: UUID) -> @Sendable (String) -> Void {
        return { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedID == id else { return }
                self.provisional = text
            }
        }
    }
    private func addMedia(_ segment: MediaSegment, to id: UUID) { update(id, persist: false) { if !$0.media.contains(where: { $0.id == segment.id }) { $0.media.append(segment) }; $0.duration = max($0.duration, segment.start + segment.duration) } }
    private func addScreenshot(_ image: Screenshot, to id: UUID) { update(id) { $0.screenshots.append(image) }; pruneScreenshots(id: id) }
    private func pruneScreenshots(id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        let discarded = meeting.screenshots.filter { ScreenshotPolicy.removable($0, elapsed: meeting.duration) }
        guard !discarded.isEmpty else { return }
        let ids = Set(discarded.map(\.id)); update(id) { $0.screenshots.removeAll { ids.contains($0.id) } }
        guard let current = meetings.first(where: { $0.id == id }), let directory = try? archive.directory(current) else { return }
        Task { do { try await archive.save(current); for image in discarded { let url = try ArchiveStore.safeURL(image.path, inside: directory); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } } } catch { self.error = error.localizedDescription } }
    }
    private func captureWarning(_ message: String, id: UUID) {
        update(id) { if !$0.warnings.contains(message) { $0.warnings.append(message); $0.events = ($0.events ?? []) + [.init("source_issue", at: $0.duration, detail: message)] } }
        if (message.contains("disco") || message.lowercased().contains("salvataggio audio")) && isRecording { error = message; stop() }
    }
    func update(_ id: UUID, persist: Bool = true, _ mutation: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&meetings[index]); meetings[index].saveRevision += 1; let snapshot = meetings[index]
        guard persist else { return }
        let storage = archive
        Task { do { try await storage.save(snapshot) } catch { self.error = error.localizedDescription } }
    }
    func select(_ id: UUID?) async {
        selectedID = id; recap = nil; provisional = ""
        guard let meeting = selected else { transcript = TranscriptDocument(); clearPlayer(); return }
        do {
            let loaded = id == activeID ? activeTranscript : try await archive.transcript(meeting)
            guard selectedID == id else { return }
            transcript = loaded
            if let run = meeting.recapRuns.last(where: { $0.state == .completed }) { recap = try await archive.recap(meeting, run: run) }
            if meeting.state == .ready || meeting.state == .interrupted || meeting.state == .failed { await loadPlayer(meeting) }
        } catch { self.error = error.localizedDescription }
    }
    func editSegment(_ id: UUID, text: String) { transcript.edit(id: id, text: text); saveEdits() }
    func renameSpeaker(_ id: String, name: String) { transcript.rename(speaker: id, name: name); saveEdits() }
    private func saveEdits() {
        guard let meeting = selected, meeting.state == .ready else { return }
        editTask?.cancel(); let snapshot = transcript
        let storage = archive
        editTask = Task { do { try await Task.sleep(for: .milliseconds(250)); try await storage.saveTranscript(snapshot, meeting: meeting) } catch is CancellationError {} catch { self.error = error.localizedDescription } }
    }
    func sendToCodex() {
        guard let meeting = selected, meeting.state == .ready, !codexRunning else { return }
        let snapshot = transcript; let language = meeting.recapLanguage ?? snapshot.predominantLanguage
        let images = ScreenshotPolicy.select(meeting.screenshots, duration: meeting.duration)
        let run = RecapRun(revision: snapshot.revision, language: language, screenshots: images.map(\.id))
        update(meeting.id) { $0.recapRuns.append(run) }; codexRunning = true; status = "Preparazione del materiale per Codex…"
        recapTask = Task { [self] in
            do {
                try await archive.saveTranscript(snapshot, meeting: meeting)
                let result = try await codex.generate(meeting: meeting, transcript: snapshot, directory: archive.directory(meeting), run: run, executable: codexPath, model: codexModel) { [weak self] value in Task { @MainActor in self?.status = value } }
                try await archive.saveRecap(result, run: run, meeting: meeting, transcript: snapshot)
                update(meeting.id) { if let index = $0.recapRuns.firstIndex(where: { $0.id == run.id }) { $0.recapRuns[index].state = .completed } }
                if selectedID == meeting.id { recap = result; selectedTab = "recap" }; status = "Recap pronto"
            } catch {
                let cancelled = Task.isCancelled
                update(meeting.id) { if let index = $0.recapRuns.firstIndex(where: { $0.id == run.id }) { $0.recapRuns[index].state = cancelled ? .cancelled : .failed; $0.recapRuns[index].error = error.localizedDescription } }
                if !cancelled { self.error = error.localizedDescription }; status = cancelled ? "Recap annullato" : "Invio a Codex da riprovare"
            }
            codexRunning = false
        }
    }
    func cancelCodex() { recapTask?.cancel(); codex.cancel() }
    func folder(_ meeting: Meeting) -> URL? { try? archive.directory(meeting) }
    func reveal(_ meeting: Meeting) { if let folder = folder(meeting) { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
    func delete(_ meeting: Meeting) {
        guard meeting.id != activeID && !busy && !codexRunning, let folder = folder(meeting) else { return }
        do { try FileManager.default.trashItem(at: folder, resultingItemURL: nil); meetings.removeAll { $0.id == meeting.id }; if selectedID == meeting.id { selectedID = nil; clearPlayer() } }
        catch { self.error = error.localizedDescription }
    }
    private func clearPlayer() { if let timeObserver { player?.removeTimeObserver(timeObserver); self.timeObserver = nil }; player?.pause(); player = nil; playbackTime = 0 }
    private func loadPlayer(_ meeting: Meeting) async {
        clearPlayer()
        guard !meeting.media.isEmpty else { return }
        do {
            let composition = try await AudioIO.composition(meeting: meeting, directory: archive.directory(meeting))
            guard selectedID == meeting.id else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: composition)); player.isMuted = playbackMuted; self.player = player
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in Task { @MainActor in self?.playbackTime = max(0, time.seconds.isFinite ? time.seconds : 0) } }
        } catch { self.error = "Riproduzione non disponibile: \(error.localizedDescription)" }
    }
    func seek(_ time: Double) { player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); playbackTime = time }
    func prepareToQuit() async {
        shuttingDown = true; clock.pause(); busy = true
        captureTask?.cancel(); await captureTask?.value; captureTask = nil; busy = true
        asrTask?.cancel(); await asrTask?.value; asrTask = nil
        processingTask?.cancel(); await processingTask?.value; processingTask = nil
        if let id = activeID {
            for segment in await audio?.stop() ?? [] { addMedia(segment, to: id) }; audio = nil
            for segment in await screen?.stop() ?? [] { addMedia(segment, to: id) }; screen = nil
            update(id) { $0.state = .interrupted; $0.duration = clock.elapsed(); $0.error = "Registrazione salvata alla chiusura. Puoi completare l'elaborazione locale."; $0.events = ($0.events ?? []) + [.init("quit", at: clock.elapsed())] }
            if let meeting = active { try? await archive.saveTranscript(activeTranscript, meeting: meeting) }
            activeID = nil
        }
        cancelCodex(); await recapTask?.value
        await editTask?.value
        for meeting in meetings { try? await archive.save(meeting) }
        clearPlayer(); await inference.unloadAll()
    }
}
