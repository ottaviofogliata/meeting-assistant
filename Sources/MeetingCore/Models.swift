import Foundation

public enum RecordingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case online, inPerson, presentation
    public var id: String { rawValue }
    public var title: String { switch self { case .online: "Online"; case .inPerson: "In presenza"; case .presentation: "In presenza con presentazione" } }
    public var hasScreen: Bool { self != .inPerson }
}
public enum TranscriptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case background, realtime
    public var id: String { rawValue }
    public var title: String { self == .background ? "In background" : "Realtime" }
}
public enum ProcessingState: String, Codable, Sendable {
    case recording, paused, finalizingMedia, finalizingTranscript, identifyingSpeakers, ready, interrupted, failed
    public var title: String {
        switch self {
        case .recording: "Registrazione"; case .paused: "In pausa"; case .finalizingMedia: "Salvataggio audio e video"
        case .finalizingTranscript: "Completamento trascrizione"; case .identifyingSpeakers: "Identificazione parlanti"
        case .ready: "Pronta"; case .interrupted: "Registrazione interrotta"; case .failed: "Elaborazione da riprovare"
        }
    }
    public var isCapturing: Bool { self == .recording || self == .paused }
}
public struct VisualSource: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case display, window }
    public var kind: Kind
    public var number: UInt32
    public var title: String
    public var width: Int
    public var height: Int
    public var id: String { "\(kind.rawValue)-\(number)" }
    public init(kind: Kind, number: UInt32, title: String, width: Int = 1920, height: Int = 1080) {
        self.kind = kind; self.number = number; self.title = title; self.width = width; self.height = height
    }
}
public struct AudioApplication: Codable, Hashable, Identifiable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleID: String
    public var id: Int32 { pid }
    public init(pid: Int32, name: String, bundleID: String) { self.pid = pid; self.name = name; self.bundleID = bundleID }
}
public struct IgnoreRegion: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct RecordingOptions: Codable, Sendable {
    public var mode: RecordingMode = .online
    public var transcription: TranscriptionMode = .background
    public var video = false
    public var visualSource: VisualSource?
    public var audioApplication: AudioApplication?
    public var allSystemAudio = false
    public var microphoneID: UInt32 = 0
    public var ignoredRegions: [IgnoreRegion] = []
    public var ignoredRegionsBySource: [String: [IgnoreRegion]]?
    public init() {}
}
public enum AudioTrack: String, Codable, Sendable { case microphone, system }
public struct MediaSegment: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    public var start: Double
    public var duration: Double
    public var track: AudioTrack?
    public var isVideo: Bool { track == nil }
    public init(path: String, start: Double, duration: Double, track: AudioTrack?) {
        self.path = path; self.start = start; self.duration = duration; self.track = track
    }
}
public enum ScreenshotReason: String, Codable, Hashable, Sendable {
    case periodic, significantChange, recordingStart, recordingEnd, resume, sourceChange
}
public struct Screenshot: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    public var time: Double
    public var source: String
    public var reasons: Set<ScreenshotReason>
    public var periodicSlot: Int?
    public var signature: UInt64
    public var text: String
    public init(path: String, time: Double, source: String, reasons: Set<ScreenshotReason>, periodicSlot: Int? = nil, signature: UInt64 = 0, text: String = "") {
        self.path = path; self.time = time; self.source = source; self.reasons = reasons; self.periodicSlot = periodicSlot; self.signature = signature; self.text = text
    }
    public var protected: Bool { !reasons.subtracting([.periodic]).isEmpty }
}
public struct TranscriptWord: Codable, Sendable {
    public var start: Double; public var end: Double; public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
public struct TranscriptSegment: Codable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var track: AudioTrack
    public var speakerID: String?
    public var language: String?
    public var words: [TranscriptWord]?
    public var edited = false
    public init(id: UUID = UUID(), start: Double, end: Double, text: String, track: AudioTrack = .microphone, speakerID: String? = nil, language: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.track = track; self.speakerID = speakerID; self.language = language
    }
}
public struct TranscriptDocument: Codable, Sendable {
    public var schemaVersion = 1
    public var revision = 0
    public var segments: [TranscriptSegment] = []
    public var speakerNames: [String: String] = [:]
    public init() {}
    public mutating func edit(id: UUID, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }), segments[index].text != text else { return }
        segments[index].text = text; segments[index].edited = true; segments[index].words = nil; revision += 1
    }
    public mutating func rename(speaker: String, name: String) {
        guard speakerNames[speaker] != name else { return }
        speakerNames[speaker] = name; revision += 1
    }
    public var predominantLanguage: String {
        let durations = segments.reduce(into: [String: Double]()) { result, segment in
            if let language = segment.language, ["it", "en"].contains(language) { result[language, default: 0] += max(0, segment.end - segment.start) }
        }
        return (durations["it", default: 0] >= durations["en", default: 0]) ? "it" : "en"
    }
    public func markdown() -> String {
        segments.map { s in
            let name = s.speakerID.map { speakerNames[$0] ?? $0 } ?? ""
            return "[\(Timestamp.format(s.start))] \(name.isEmpty ? "" : "**\(name)**: ")\(s.text)"
        }.joined(separator: "\n\n") + "\n"
    }
}
public struct RecapEntry: Codable, Sendable {
    public var text: String
    public var sourceIDs: [String]
    public init(text: String, sourceIDs: [String]) { self.text = text; self.sourceIDs = sourceIDs }
}
public struct ActionItem: Codable, Sendable {
    public var task: String
    public var owner: String?
    public var deadline: String?
    public var sourceIDs: [String]
}
public struct RecapDocument: Codable, Sendable {
    public var language: String
    public var summary: String
    public var topics: [RecapEntry]
    public var decisions: [RecapEntry]
    public var actionItems: [ActionItem]
    public var openQuestions: [RecapEntry]
    public func validate(knownSourceIDs: Set<String>) throws {
        guard ["it", "en"].contains(language), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingError.invalidRecap("Lingua o sintesi non valida.") }
        let references = topics.flatMap(\.sourceIDs) + decisions.flatMap(\.sourceIDs) + actionItems.flatMap(\.sourceIDs) + openQuestions.flatMap(\.sourceIDs)
        guard (topics + decisions + openQuestions).allSatisfy({ !$0.sourceIDs.isEmpty }), actionItems.allSatisfy({ !$0.sourceIDs.isEmpty }) else { throw MeetingError.invalidRecap("Il recap contiene elementi senza riferimenti alle fonti.") }
        guard references.allSatisfy(knownSourceIDs.contains) else { throw MeetingError.invalidRecap("Il recap contiene riferimenti non presenti nella riunione.") }
    }
    public func markdown(sourceTimes: [String: Double]) -> String {
        let italian = language == "it"
        func refs(_ ids: [String]) -> String { ids.compactMap { id in sourceTimes[id].map { "[\(Timestamp.format($0))]" } }.joined(separator: " ") }
        func section(_ title: String, _ entries: [RecapEntry]) -> String { "## \(title)\n\n" + (entries.isEmpty ? "—" : entries.map { "- \($0.text) \(refs($0.sourceIDs))" }.joined(separator: "\n")) + "\n\n" }
        var result = "# \(italian ? "Recap della riunione" : "Meeting recap")\n\n## \(italian ? "Sintesi" : "Summary")\n\n\(summary)\n\n"
        result += section(italian ? "Argomenti discussi" : "Topics discussed", topics)
        result += section(italian ? "Decisioni" : "Decisions", decisions)
        result += "## \(italian ? "Attività" : "Action items")\n\n"
        result += actionItems.isEmpty ? "—\n\n" : actionItems.map { "- \($0.task) — \($0.owner ?? (italian ? "Responsabile non specificato" : "Owner unspecified")); \($0.deadline ?? (italian ? "scadenza non specificata" : "deadline unspecified")). \(refs($0.sourceIDs))" }.joined(separator: "\n") + "\n\n"
        result += section(italian ? "Punti aperti" : "Open questions", openQuestions)
        return result
    }
}
public enum RecapState: String, Codable, Sendable { case running, completed, failed, cancelled }
public struct RecapRun: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var transcriptRevision: Int
    public var language: String
    public var screenshotIDs: [UUID]
    public var state: RecapState = .running
    public var error: String?
    public init(revision: Int, language: String, screenshots: [UUID]) { transcriptRevision = revision; self.language = language; screenshotIDs = screenshots }
}
public struct Meeting: Codable, Identifiable, Sendable {
    public struct CaptureEvent: Codable, Sendable {
        public var kind: String
        public var activeTime: Double
        public var wallTime = Date()
        public var detail: String?
        public init(_ kind: String, at time: Double, detail: String? = nil) { self.kind = kind; activeTime = time; self.detail = detail }
    }
    public struct Engine: Codable, Sendable {
        public var transcription = "large-v3-v20240930_626MB"
        public var sdk = "argmax-oss-swift/1.1.1"
        public var diarization = "Pyannote community-1; 60s bounded windows; meeting-wide cosine reconciliation"
        public var application = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        public var sourceRevision = Bundle.main.object(forInfoDictionaryKey: "MeetingAssistantSourceRevision") as? String
        public init() {}
    }
    public var schemaVersion = 1
    public var engine: Engine? = Engine()
    public var events: [CaptureEvent]? = []
    public var id = UUID()
    public var createdAt = Date()
    public var title: String
    public var folder: String
    public var options: RecordingOptions
    public var state: ProcessingState = .recording
    public var duration: Double = 0
    public var media: [MediaSegment] = []
    public var screenshots: [Screenshot] = []
    public var recapRuns: [RecapRun] = []
    public var recapLanguage: String?
    public var error: String?
    public var warnings: [String] = []
    public var saveRevision = 0
    public init(title: String, options: RecordingOptions) {
        self.title = title; self.options = options
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        folder = "\(formatter.string(from: createdAt))_\(id.uuidString.prefix(8))"
    }
}
public enum MeetingError: LocalizedError {
    case message(String), unsafePath, invalidRecap(String)
    public var errorDescription: String? {
        switch self { case .message(let s), .invalidRecap(let s): s; case .unsafePath: "Percorso del file non valido nell'archivio." }
    }
}
public enum Timestamp {
    public static func format(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
