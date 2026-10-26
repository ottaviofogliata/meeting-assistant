import SwiftUI
import AppKit
import AVFoundation
import MeetingCore
import MeetingRuntime

struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack { Text("Riunioni").font(.title2.bold()); Spacer(); Button { Task { await state.select(nil) } } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Nuova riunione").disabled(state.isRecording) }.padding(20)
                if state.meetings.isEmpty {
                    VStack(spacing: 12) { Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary); Text("Le tue riunioni, qui.").font(.headline); Text("Audio, trascrizione e immagini\nin un unico archivio locale.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: Binding(get: { state.selectedID }, set: { id in Task { await state.select(id) } })) {
                        ForEach(state.meetings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { meeting in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline) { Image(systemName: meeting.options.mode == .inPerson ? "mic" : "rectangle.on.rectangle").foregroundStyle(meeting.state.isCapturing ? Color.red : Color.secondary); Text(meeting.title).font(.headline).lineLimit(2) }
                                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                HStack { Text(Timestamp.format(meeting.duration)).monospacedDigit(); Spacer(); Text(meeting.state.title).lineLimit(1) }.font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 9).tag(meeting.id)
                            .contextMenu { Button("Mostra nel Finder") { state.reveal(meeting) }; Button("Sposta nel Cestino", role: .destructive) { state.delete(meeting) }.disabled(state.isRecording || state.busy || state.codexRunning) }
                        }
                    }.listStyle(.sidebar).searchable(text: $search, prompt: "Cerca una riunione")
                }
                Divider()
                HStack { Button { NSWorkspace.shared.open(state.archiveRoot) } label: { Label("Archivio locale", systemImage: "folder") }.buttonStyle(.plain).font(.caption); Spacer(); SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain) }.padding(16)
            }.navigationSplitViewColumnWidth(min: 235, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let active = state.active, active.id != state.selectedID {
                    HStack(spacing: 14) {
                        Image(systemName: active.state == .paused ? "pause.circle.fill" : "record.circle.fill").foregroundStyle(.red)
                        Text("\(active.state.title) · \(Timestamp.format(state.elapsed))").font(.caption.monospacedDigit())
                        Button("Torna alla registrazione") { Task { await state.select(active.id) } }
                        Spacer()
                        Button(active.state == .paused ? "Riprendi" : "Pausa", action: state.pauseResume).disabled(state.busy)
                        Button("Stop e salva", action: state.stop).disabled(state.busy)
                    }.padding(14).background(.bar)
                    Divider()
                }
                if let meeting = state.selected { MeetingDetail(meeting: meeting) }
                else { SetupView() }
                Divider()
                HStack(spacing: 8) {
                    if state.busy || state.codexRunning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if let progress = state.progress { Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()) }
                    if state.codexRunning { Button("Annulla recap") { state.cancelCodex() }.font(.caption) }
                }.padding(.horizontal, 22).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("Meeting Assistant", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) { Button("OK") { state.error = nil } } message: { Text(state.error ?? "") }
    }
}

struct SetupView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("PRESENTE,\nANCHE DOPO.").font(.system(size: 38, weight: .bold, design: .rounded)).tracking(-1.5)
                        Text("Registra la riunione. Ritrova ciò che conta.").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "waveform.circle.fill").font(.system(size: 100, weight: .ultraLight)).foregroundStyle(.tint.opacity(0.85)).accessibilityHidden(true)
                }.padding(.top, 16)
                TextField("Titolo della riunione", text: $state.title).font(.title2).textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: 16) {
                    sectionLabel("01", "Come ci incontriamo")
                    Picker("Modalità", selection: $state.options.mode) { ForEach(RecordingMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                    Text(state.options.mode == .online ? "Microfono e audio della call, con immagini dello schermo." : state.options.mode == .inPerson ? "Solo il microfono. Funziona anche senza connessione." : "Audio della stanza e immagini della presentazione visibile sul Mac.").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    sectionLabel("02", "Le sorgenti")
                    Picker("Microfono", selection: $state.options.microphoneID) { Text("Predefinito di sistema").tag(UInt32(0)); ForEach(state.microphones) { Text($0.name).tag($0.id) } }
                    if state.options.mode.hasScreen {
                        SourcePicker(active: false)
                        Toggle("Conserva anche il video completo", isOn: $state.options.video)
                            .help("Si sceglie prima di avviare la registrazione. Audio e screenshot vengono sempre conservati.")
                    }
                    if state.options.mode == .online {
                        Toggle("Cattura tutto l’audio del Mac", isOn: $state.options.allSystemAudio)
                        if !state.options.allSystemAudio {
                            Picker("App della call", selection: $state.options.audioApplication) { Text("Scegli un'app").tag(Optional<AudioApplication>.none); ForEach(state.applications) { Text($0.name).tag(Optional($0)) } }
                            Text("L’audio del browser può includere le altre schede aperte.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    sectionLabel("03", "La trascrizione")
                    Picker("Trascrizione", selection: $state.options.transcription) { ForEach(TranscriptionMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                    Text("Whisper turbo sul Mac · Italiano e inglese · Parlanti identificati dopo Stop").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(36).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Label("File sul tuo Mac. Recap solo su richiesta.", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: state.start) { Label(state.busy ? "Preparazione…" : "Avvia registrazione", systemImage: "record.circle").padding(.horizontal, 8).padding(.vertical, 5) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!state.canStart)
            }.padding(.horizontal, 30).padding(.vertical, 18).background(.bar)
        }.disabled(state.busy && !state.canInterruptProcessing)
    }
    private func sectionLabel(_ number: String, _ title: String) -> some View { HStack(spacing: 10) { Text(number).font(.caption.monospaced()).foregroundStyle(.tint); Text(title).font(.headline) } }
}

struct SourcePicker: View {
    @EnvironmentObject var state: AppState
    var active: Bool
    var body: some View {
        HStack {
            Picker("Schermo / finestra", selection: Binding(get: { active ? state.active?.options.visualSource : state.options.visualSource }, set: { state.changeSource($0) })) {
                Text("Scegli una sorgente").tag(Optional<VisualSource>.none)
                ForEach(state.sources) { Text($0.title).tag(Optional($0)) }
            }
            Button { Task { await state.refreshSources() } } label: { Image(systemName: "arrow.clockwise") }.help("Aggiorna sorgenti e autorizza la cattura schermo")
        }.disabled(active && state.busy)
    }
}

struct MeetingDetail: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(meeting.title).font(.system(size: 28, weight: .bold, design: .rounded)).textSelection(.enabled)
                        HStack(spacing: 12) { Label(meeting.options.mode.title, systemImage: meeting.options.mode == .inPerson ? "mic" : "display"); Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)); Text(Timestamp.format(meeting.duration)).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if meeting.state == .ready { Button("Send to Codex", systemImage: "arrow.up.right", action: state.sendToCodex).buttonStyle(.borderedProminent).disabled(state.codexRunning) }
                    Button { state.reveal(meeting) } label: { Image(systemName: "folder") }.help("Mostra nel Finder")
                }
                if meeting.state.isCapturing {
                    HStack(spacing: 16) {
                        Circle().fill(meeting.state == .paused ? Color.orange : Color.red).frame(width: 9, height: 9)
                        Text(Timestamp.format(state.elapsed)).font(.system(.title2, design: .monospaced)).bold()
                        AudioMeter(level: state.level).frame(width: 90, height: 25)
                        Toggle("Realtime", isOn: Binding(get: { meeting.options.transcription == .realtime }, set: { state.setTranscription($0 ? .realtime : .background) })).toggleStyle(.switch).fixedSize()
                        if state.transcriptionLag > (meeting.options.transcription == .realtime ? 8 : 35) { Text("Trascrizione in recupero: \(Int(state.transcriptionLag)) s").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(meeting.state == .paused ? "Riprendi" : "Pausa", systemImage: meeting.state == .paused ? "play.fill" : "pause.fill", action: state.pauseResume).disabled(state.busy)
                        Button("Stop e salva", systemImage: "stop.fill", action: state.stop).buttonStyle(.borderedProminent).disabled(state.busy)
                    }
                    if meeting.options.mode.hasScreen { SourcePicker(active: true) }
                } else if meeting.state == .interrupted || meeting.state == .failed {
                    HStack { Label(meeting.error ?? "Elaborazione incompleta", systemImage: "exclamationmark.triangle").font(.callout); Spacer(); Button("Riprendi elaborazione") { state.retryLocal(meeting) }.disabled(state.busy) }
                } else if meeting.state != .ready {
                    HStack { ProgressView().controlSize(.small); Text(meeting.state.title).font(.callout); if let progress = state.progress { ProgressView(value: progress).frame(width: 130) } }
                }
                if let warning = meeting.warnings.last { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(3) }
            }.padding(26)
            Divider()
            Picker("Vista", selection: $state.selectedTab) { Text("Trascrizione").tag("transcript"); Text("Schermate · \(meeting.screenshots.count)").tag("screens"); Text("Recap").tag("recap") }.pickerStyle(.segmented).padding(.horizontal, 26).padding(.vertical, 15)
            Group {
                switch state.selectedTab {
                case "screens": ScreensView(meeting: meeting)
                case "recap": RecapView(meeting: meeting)
                default: TranscriptView(meeting: meeting)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let player = state.player {
                Divider()
                if meeting.media.contains(where: \.isVideo) { NativeVideoPlayer(player: player).frame(height: 160) }
                HStack(spacing: 15) {
                    Button { if player.timeControlStatus == .playing { player.pause() } else { player.play() } } label: { Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill").frame(width: 20) }
                    Button { state.playbackMuted.toggle() } label: { Image(systemName: state.playbackMuted ? "speaker.slash" : "speaker.wave.2") }.accessibilityLabel(state.playbackMuted ? "Riattiva audio" : "Disattiva audio")
                    Text(Timestamp.format(state.playbackTime)).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { min(state.playbackTime, max(1, meeting.duration)) }, set: { state.seek($0) }), in: 0...max(1, meeting.duration))
                    Text(Timestamp.format(meeting.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.horizontal, 26).padding(.vertical, 14)
            }
        }.sheet(item: $state.inspectedScreenshot) { image in ScreenshotDetail(image: image, meeting: meeting) }
    }
}
private struct AudioMeter: View {
    let level: Float
    var body: some View { HStack(alignment: .center, spacing: 3) { ForEach(0..<16) { index in RoundedRectangle(cornerRadius: 2).fill(Double(level) * 70 > Double(index) ? Color.accentColor : Color.secondary.opacity(0.15)).frame(width: 3, height: CGFloat(8 + (index % 5) * 4)) } }.animation(.easeOut(duration: 0.15), value: level) }
}

struct TranscriptView: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    var body: some View {
        VStack(spacing: 0) {
            if meeting.state == .ready && !state.transcript.speakerNames.isEmpty {
                ScrollView(.horizontal) { HStack(spacing: 12) { ForEach(state.transcript.speakerNames.keys.sorted(), id: \.self) { id in HStack(spacing: 6) { Image(systemName: "person.crop.circle").foregroundStyle(.secondary); TextField(id, text: Binding(get: { state.transcript.speakerNames[id] ?? id }, set: { state.renameSpeaker(id, name: $0) })).textFieldStyle(.roundedBorder).frame(width: 145) } } }.padding(.horizontal, 26).padding(.bottom, 12) }
            }
            if meeting.state.isCapturing && meeting.options.transcription == .background {
                ContentUnavailableView("Puoi concentrarti sulla riunione", systemImage: "waveform", description: Text("L'audio viene trascritto a blocchi sul Mac. Attiva Realtime per vedere il testo durante la call."))
            } else if state.transcript.segments.isEmpty && state.provisional.isEmpty {
                ContentUnavailableView("In ascolto", systemImage: "text.alignleft", description: Text(meeting.state == .ready ? "Non è stato rilevato parlato nella registrazione." : "La trascrizione apparirà qui. I parlanti saranno identificati dopo Stop."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(state.transcript.segments) { segment in
                            HStack(alignment: .top, spacing: 18) {
                                Button(Timestamp.format(segment.start)) { state.seek(segment.start) }.font(.caption.monospacedDigit()).buttonStyle(.plain).foregroundStyle(.tint).frame(width: 72, alignment: .leading).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 7) {
                                    if !meeting.state.isCapturing, let speaker = segment.speakerID { Text(state.transcript.speakerNames[speaker] ?? speaker).font(.caption.bold()).foregroundStyle(.secondary) }
                                    if meeting.state == .ready {
                                        TextField("Trascrizione", text: Binding(get: { state.transcript.segments.first { $0.id == segment.id }?.text ?? "" }, set: { state.editSegment(segment.id, text: $0) }), axis: .vertical).textFieldStyle(.plain).font(.system(size: 15)).lineSpacing(4)
                                        if segment.edited { Text("Modificato · originale conservato").font(.caption2).foregroundStyle(.tertiary) }
                                    } else { Text(segment.text).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !state.provisional.isEmpty && meeting.state.isCapturing && meeting.options.transcription == .realtime { Text(state.provisional).font(.system(size: 15)).foregroundStyle(.secondary).padding(.leading, 90) }
                    }.padding(26)
                }
            }
        }
    }
}

struct ScreensView: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    var body: some View {
        if !meeting.options.mode.hasScreen { ContentUnavailableView("Solo audio", systemImage: "mic", description: Text("Questa riunione è stata registrata senza acquisire lo schermo.")) }
        else if meeting.screenshots.isEmpty { ContentUnavailableView("Le immagini appariranno qui", systemImage: "photo.on.rectangle", description: Text("Uno scatto ogni minuto e quando il contenuto cambia. Dopo 15 minuti gli scatti periodici passano a uno ogni due minuti.")) }
        else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 20) {
                    ForEach(meeting.screenshots.sorted { $0.time < $1.time }) { image in
                        Button { state.inspectedScreenshot = image; state.seek(image.time) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Thumbnail(url: state.folder(meeting)?.appendingPathComponent(image.path)).aspectRatio(16 / 10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                                HStack { Text(Timestamp.format(image.time)).font(.caption.monospacedDigit()); Spacer(); if image.reasons.contains(.significantChange) { Image(systemName: "sparkle").foregroundStyle(.tint) } }.foregroundStyle(.secondary)
                            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }.padding(26)
            }
        }
    }
}
struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Rectangle().fill(.quaternary).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } } }
            .task(id: url) {
                guard let url else { return }
                let thumbnail = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 700] as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: .zero)
                }.value
                image = thumbnail
            }
    }
}
struct ScreenshotDetail: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let image: Screenshot
    let meeting: Meeting
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var ignoring = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("\(Timestamp.format(image.time)) · \(image.source)").font(.headline); Spacer(); Button("Chiudi") { dismiss() } }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if let url = state.folder(meeting)?.appendingPathComponent(image.path), let picture = NSImage(contentsOf: url) { Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if let start = dragStart, let end = dragEnd { Rectangle().fill(.red.opacity(0.15)).border(.red).frame(width: abs(end.x - start.x), height: abs(end.y - start.y)).offset(x: min(start.x, end.x), y: min(start.y, end.y)) }
                }.contentShape(Rectangle()).gesture(DragGesture().onChanged { if ignoring { if dragStart == nil { dragStart = $0.startLocation }; dragEnd = $0.location } }.onEnded { value in
                    guard ignoring else { return }
                    let start = dragStart ?? value.startLocation; let end = value.location
                    let picture = state.folder(meeting).flatMap { NSImage(contentsOf: $0.appendingPathComponent(image.path)) }
                    let imageSize = picture?.size ?? geometry.size
                    let scale = min(geometry.size.width / max(1, imageSize.width), geometry.size.height / max(1, imageSize.height))
                    let width = imageSize.width * scale; let height = imageSize.height * scale
                    let offsetX = (geometry.size.width - width) / 2; let offsetY = (geometry.size.height - height) / 2
                    let x0 = max(0, min(1, (min(start.x, end.x) - offsetX) / width)); let y0 = max(0, min(1, (min(start.y, end.y) - offsetY) / height))
                    let x1 = max(0, min(1, (max(start.x, end.x) - offsetX) / width)); let y1 = max(0, min(1, (max(start.y, end.y) - offsetY) / height))
                    if x1 > x0, y1 > y0 { state.addIgnoredRegion(IgnoreRegion(x: Double(x0), y: Double(y0), width: Double(x1 - x0), height: Double(y1 - y0))) }
                    ignoring = false
                })
            }.frame(height: 420)
            if state.activeID == meeting.id {
                HStack { Toggle("Ignora un'area nel rilevamento cambiamenti", isOn: $ignoring); Button("Rimuovi aree ignorate") { state.clearIgnoredRegions(); dragStart = nil; dragEnd = nil } }.font(.caption)
                Text("Trascina un rettangolo sull'immagine. L'area rimane visibile nei file salvati.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView { Text(image.text.isEmpty ? "Nessun testo rilevato." : image.text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100)
        }.padding(24).frame(width: 820)
    }
}

struct RecapView: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Lingua", selection: Binding(get: { meeting.recapLanguage ?? state.transcript.predominantLanguage }, set: { value in state.update(meeting.id) { $0.recapLanguage = value } })) { Text("Italiano").tag("it"); Text("English").tag("en") }.frame(width: 210)
                Spacer()
                Button(action: state.sendToCodex) { Label("Send to Codex", systemImage: "arrow.up.right") }.buttonStyle(.borderedProminent).disabled(meeting.state != .ready || state.codexRunning)
            }.padding(.horizontal, 26).padding(.bottom, 16)
            let selectedImages = ScreenshotPolicy.select(meeting.screenshots, duration: meeting.duration)
            Text("Trascrizione completa · \(selectedImages.count) screenshot selezionati · audio e video restano sul Mac").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.bottom, 12)
            if !selectedImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(selectedImages) { image in Button { state.inspectedScreenshot = image } label: { Thumbnail(url: state.folder(meeting)?.appendingPathComponent(image.path)).frame(width: 90, height: 55).clipShape(RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain).help(Timestamp.format(image.time)) } }.padding(.horizontal, 26)
                }.frame(height: 62)
            }
            if let recap = state.recap {
                if let run = meeting.recapRuns.last(where: { $0.state == .completed }), run.transcriptRevision != state.transcript.revision || run.language != (meeting.recapLanguage ?? state.transcript.predominantLanguage) { Label("La trascrizione o la lingua sono cambiate. Puoi rigenerare il recap.", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange).padding(.bottom, 12) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(recap.language == "it" ? "Sintesi" : "Summary").font(.title2.bold()); Text(recap.summary).textSelection(.enabled)
                        entries(recap.language == "it" ? "Argomenti discussi" : "Topics discussed", recap.topics)
                        entries(recap.language == "it" ? "Decisioni" : "Decisions", recap.decisions)
                        Text(recap.language == "it" ? "Attività" : "Action items").font(.title2.bold())
                        if recap.actionItems.isEmpty { Text("—").foregroundStyle(.secondary) }
                        ForEach(Array(recap.actionItems.enumerated()), id: \.offset) { _, action in VStack(alignment: .leading, spacing: 7) { Text(action.task).textSelection(.enabled); Text("\(action.owner ?? "—") · \(action.deadline ?? "—")").font(.caption).foregroundStyle(.secondary); references(action.sourceIDs) } }
                        entries(recap.language == "it" ? "Punti aperti" : "Open questions", recap.openQuestions)
                        Button("Copia Markdown", systemImage: "doc.on.doc") {
                            let times = Dictionary(uniqueKeysWithValues: state.transcript.segments.map { ($0.id.uuidString, $0.start) } + meeting.screenshots.map { ($0.id.uuidString, $0.time) })
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(recap.markdown(sourceTimes: times), forType: .string)
                        }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Il recap parte da te", systemImage: "text.bubble", description: Text("Quando la trascrizione è pronta, Send to Codex invia il testo e una selezione di screenshot. Puoi farlo anche riaprendo una riunione passata."))
            }
            if let run = meeting.recapRuns.last, run.state == .failed { Text(run.error ?? "Elaborazione non completata. Puoi riprovare.").font(.caption).foregroundStyle(.red).padding(20) }
        }
    }
    @ViewBuilder private func entries(_ title: String, _ values: [RecapEntry]) -> some View { Text(title).font(.title2.bold()); if values.isEmpty { Text("—").foregroundStyle(.secondary) }; ForEach(Array(values.enumerated()), id: \.offset) { _, entry in VStack(alignment: .leading, spacing: 7) { Text(entry.text).textSelection(.enabled); references(entry.sourceIDs) } } }
    private func references(_ ids: [String]) -> some View {
        HStack { ForEach(ids, id: \.self) { id in if let time = state.transcript.segments.first(where: { $0.id.uuidString == id })?.start ?? meeting.screenshots.first(where: { $0.id.uuidString == id })?.time { Button(Timestamp.format(time)) { state.seek(time); if let image = meeting.screenshots.first(where: { $0.id.uuidString == id }) { state.inspectedScreenshot = image } }.font(.caption.monospacedDigit()).buttonStyle(.borderless) } } }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Section("Archivio") {
                LabeledContent("Cartella", value: state.archiveRoot.path)
                Button("Scegli cartella…", action: state.chooseArchive).disabled(state.isRecording || state.busy || state.codexRunning)
                Text("Una cartella per riunione. I materiali rimangono sul Mac finché li elimini.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Trascrizione locale") {
                LabeledContent("Modello", value: "Whisper large-v3-turbo compresso")
                Text("Il primo avvio richiede il download del modello e la preparazione per questo Mac. L'identificazione dei parlanti viene eseguita soltanto dopo Stop.").font(.caption).foregroundStyle(.secondary)
                Button("Prepara i modelli sul Mac", action: state.prepareModels).disabled(state.busy || state.isRecording)
            }
            Section("Autorizzazioni macOS") {
                LabeledContent("Microfono", value: CaptureDevices.microphonePermission)
                LabeledContent("Schermo / audio", value: CGPreflightScreenCaptureAccess() ? "Autorizzato" : "Da autorizzare dalla scelta sorgenti")
            }
            Section("Codex") {
                TextField("Percorso CLI", text: $state.codexPath)
                TextField("Modello Codex", text: $state.codexModel, prompt: Text("Predefinito di Codex"))
                Text("Utilizza l'accesso del tuo Codex CLI. Il recap parte solo da Send to Codex; invia la trascrizione e gli screenshot selezionati, senza audio e video.").font(.caption).foregroundStyle(.secondary)
            }
            Section { Text(state.status).font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding(16).frame(width: 640, height: 520)
    }
}
