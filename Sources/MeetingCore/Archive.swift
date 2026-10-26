import Foundation

public actor ArchiveStore {
    public let root: URL
    private var savedRevisions: [UUID: Int] = [:]
    public init(root: URL, createIfNeeded: Bool = true) throws {
        self.root = root
        if createIfNeeded { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    }
    public nonisolated static func encoder() -> JSONEncoder {
        let result = JSONEncoder(); result.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; result.dateEncodingStrategy = .iso8601; return result
    }
    public nonisolated static func decoder() -> JSONDecoder { let result = JSONDecoder(); result.dateDecodingStrategy = .iso8601; return result }
    public nonisolated func directory(_ meeting: Meeting) throws -> URL { try Self.safeURL(meeting.folder, inside: root) }
    public nonisolated static func safeURL(_ path: String, inside directory: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw MeetingError.unsafePath }
        let url = directory.appendingPathComponent(path).standardizedFileURL
        let rootPath = directory.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(rootPath) else { throw MeetingError.unsafePath }
        return url
    }
    public func scan() throws -> [Meeting] {
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return dirs.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")), var meeting = try? Self.decoder().decode(Meeting.self, from: data) else { return nil }
            meeting.folder = folder.lastPathComponent
            return meeting
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func preflight() throws {
        let probe = root.appendingPathComponent(".meeting-write-\(UUID().uuidString)")
        try Data("check".utf8).write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
        if let available = Self.availableBytes(at: root), available < 512 * 1024 * 1024 {
            throw MeetingError.message("Spazio insufficiente nell'archivio. Libera almeno 512 MB prima di registrare.")
        }
    }
    public nonisolated static func availableBytes(at root: URL) -> Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    public func save(_ meeting: Meeting) throws {
        guard meeting.saveRevision >= savedRevisions[meeting.id, default: -1] else { return }
        let dir = try directory(meeting)
        for path in ["capture/audio", "capture/video", "screenshots", "transcripts", "recaps"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true) }
        try Self.encoder().encode(meeting).write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
        savedRevisions[meeting.id] = meeting.saveRevision
    }
    public func transcript(_ meeting: Meeting) throws -> TranscriptDocument {
        let url = try directory(meeting).appendingPathComponent("transcripts/current.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return TranscriptDocument() }
        return try Self.decoder().decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }
    public func originalASR(_ meeting: Meeting) throws -> TranscriptDocument? {
        let file = try directory(meeting).appendingPathComponent("transcripts/asr-original.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Self.decoder().decode(TranscriptDocument.self, from: Data(contentsOf: file))
    }
    public func saveTranscript(_ transcript: TranscriptDocument, meeting: Meeting, original: Bool = false, asr: Bool = false) throws {
        let dir = try directory(meeting).appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(transcript)
        if original || asr {
            let originalURL = dir.appendingPathComponent(asr ? "asr-original.json" : "original.json")
            if !FileManager.default.fileExists(atPath: originalURL.path) { try data.write(to: originalURL, options: .atomic) }
        }
        let current = dir.appendingPathComponent("current.json")
        if let existing = try? Self.decoder().decode(TranscriptDocument.self, from: Data(contentsOf: current)), existing.revision > transcript.revision { return }
        try data.write(to: dir.appendingPathComponent("current.json"), options: .atomic)
        try Data(transcript.markdown().utf8).write(to: dir.appendingPathComponent("current.md"), options: .atomic)
    }
    public func saveRecap(_ recap: RecapDocument, run: RecapRun, meeting: Meeting, transcript: TranscriptDocument) throws {
        let folder = try directory(meeting).appendingPathComponent("recaps/\(run.id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder().encode(recap).write(to: folder.appendingPathComponent("recap.json"), options: .atomic)
        let times = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id.uuidString, $0.start) } + meeting.screenshots.map { ($0.id.uuidString, $0.time) })
        try Data(recap.markdown(sourceTimes: times).utf8).write(to: folder.appendingPathComponent("recap.md"), options: .atomic)
    }
    public func recap(_ meeting: Meeting, run: RecapRun) throws -> RecapDocument {
        let url = try directory(meeting).appendingPathComponent("recaps/\(run.id.uuidString)/recap.json")
        return try Self.decoder().decode(RecapDocument.self, from: Data(contentsOf: url))
    }
}
