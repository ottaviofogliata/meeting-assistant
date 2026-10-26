import Foundation
import WhisperKit
import SpeakerKit
import MeetingCore

public actor LocalInference {
    public static let model = "large-v3-v20240930_626MB"
    private var whisper: WhisperKit?
    private var speaker: SpeakerKit?
    public init() {}
    public static var cacheDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingAssistant/Models") }
    public func prepareTranscription() async throws {
        guard whisper == nil else { return }
        let cache = Self.cacheDirectory
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let folder = cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(Self.model)")
        let cached = ["AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin", "MelSpectrogram.mlmodelc/model.mil"].allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        whisper = try await WhisperKit(WhisperKitConfig(model: Self.model, downloadBase: cache, modelFolder: cached ? folder.path : nil, verbose: false, prewarm: false, load: true, download: !cached))
        if let tokenizer = whisper?.tokenizer { whisper?.tokenizer = BilingualTokenizer(base: tokenizer) }
    }
    public func unloadTranscription() async { await whisper?.unloadModels(); whisper = nil }
    public func unloadAll() async { await unloadTranscription(); await speaker?.unloadModels(); speaker = nil }
    private static func speakerConfiguration() -> PyannoteConfig {
        let cache = cacheDirectory
        let folder = cache.appendingPathComponent("models/argmaxinc/speakerkit-coreml")
        let files = ["speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/model.mil", "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/model.mil", "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/model.mil"]
        let cached = files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        return PyannoteConfig(downloadBase: cache.path, modelFolder: cached ? folder.path : nil, download: !cached, verbose: false, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1)
    }
    public func prepareSpeakerModels() async throws {
        // Downloads only. No speaker weights are loaded and no voices are processed during capture.
        let preparation = try await SpeakerKit(Self.speakerConfiguration())
        await preparation.unloadModels()
    }
    public func transcribe(media: [MediaSegment], directory: URL, track: AudioTrack, start: Double, end: Double, provisional: (@Sendable (String) -> Void)? = nil) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        try await prepareTranscription()
        var samples = try AudioIO.window(media: media, directory: directory, track: track, start: start, end: end)
        if track == .microphone, media.contains(where: { $0.track == .system }) {
            let reference = try AudioIO.window(media: media, directory: directory, track: .system, start: start, end: end)
            samples = AudioIO.removingEcho(samples, reference: reference)
        }
        guard let whisper else { return [] }
        let options = DecodingOptions(temperatureFallbackCount: 2, detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, windowClipTime: 0, suppressBlank: true, concurrentWorkerCount: 1)
        var output: [TranscriptSegment] = []
        for range in SpeechWindows.ranges(samples: samples) {
            try Task.checkCancellation()
            let offset = start + Double(range.lowerBound) / 16000
            let utteranceEnd = min(end, start + Double(range.upperBound) / 16000)
            let utterance = Array(samples[range])
            guard AudioIO.energy(utterance) > 0.001 else { continue }
            let result = try await whisper.transcribe(audioArray: AudioIO.speechLevel(utterance), decodeOptions: options, callback: { progress in
                provisional?(progress.text); return !Task.isCancelled
            })
            output.append(contentsOf: result.flatMap { result in result.segments.compactMap { segment -> TranscriptSegment? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, segment.noSpeechProb < 0.8 else { return nil }
                let lower = max(offset, offset + Double(segment.start)); let upper = min(utteranceEnd, offset + Double(segment.end))
                guard upper > lower else { return nil }
                var value = TranscriptSegment(start: lower, end: upper, text: text, track: track, language: result.language)
                value.words = segment.words?.compactMap { word in
                    let lower = max(offset, offset + Double(word.start)); let upper = min(utteranceEnd, offset + Double(word.end))
                    return upper > lower ? TranscriptWord(start: lower, end: upper, text: word.word) : nil
                }
                return value
            } })
        }
        return output
    }
    public func identifySpeakers(meeting: Meeting, transcript: TranscriptDocument, directory: URL, progress: @Sendable (Double) -> Void) async throws -> TranscriptDocument {
        // A model exclusivity boundary: no live transcription model remains allocated.
        await unloadTranscription()
        if transcript.segments.isEmpty { var result = transcript; result.revision += 1; return result }
        if speaker == nil {
            speaker = try await SpeakerKit(Self.speakerConfiguration())
        }
        guard let speaker else { throw MeetingError.message("Modello parlanti non disponibile.") }
        var clusters = SpeakerClusters(threshold: 0.60)
        struct Turn { var start: Double; var end: Double; var id: String; var track: AudioTrack }
        var turns: [Turn] = []
        let tracks: [AudioTrack] = meeting.media.contains(where: { $0.track == .system }) ? [.microphone, .system] : [.microphone]
        let windows = max(1, Int(ceil(meeting.duration / 60)))
        for (trackIndex, track) in tracks.enumerated() {
            for window in 0..<windows {
                try Task.checkCancellation()
                let start = Double(window) * 60; let end = min(meeting.duration, start + 60)
                var audio = try AudioIO.window(media: meeting.media, directory: directory, track: track, start: start, end: end)
                if track == .microphone, tracks.count > 1 {
                    let reference = try AudioIO.window(media: meeting.media, directory: directory, track: .system, start: start, end: end)
                    audio = AudioIO.removingEcho(audio, reference: reference)
                }
                if AudioIO.energy(audio) > 0.0015, audio.count >= 1600 {
                    let result = try await speaker.diarize(audioArray: audio, options: PyannoteDiarizationOptions(minActiveOffset: 0.15, useExclusiveReconciliation: false))
                    var mapping: [Int: String] = [:]
                    for id in result.speakerCentroidEmbeddings.keys.sorted() {
                        if let embedding = result.speakerCentroidEmbeddings[id], let cluster = clusters.assign(embedding) { mapping[id] = String(format: "speaker_%03d", cluster + 1) }
                    }
                    for segment in result.segments {
                        if let local = segment.speaker.speakerId, let global = mapping[local] {
                            turns.append(Turn(start: start + Double(segment.startTime), end: min(end, start + Double(segment.endTime)), id: global, track: track))
                        }
                    }
                }
                progress(Double(trackIndex * windows + window + 1) / Double(tracks.count * windows))
            }
        }
        await speaker.unloadModels(); self.speaker = nil
        var output = transcript; output.segments = []
        for segment in transcript.segments {
            let relevant = turns.filter { $0.track == segment.track && $0.end > segment.start && $0.start < segment.end }
            func identity(at time: Double) -> String? {
                let ids = Set(relevant.filter { $0.start <= time && $0.end >= time }.map(\.id))
                return ids.count == 1 ? ids.first : nil
            }
            if let words = segment.words, !words.isEmpty {
                var group: TranscriptSegment?
                for word in words {
                    let id = identity(at: (word.start + word.end) / 2)
                    if group == nil || group?.speakerID != id {
                        if let group { output.segments.append(group) }
                        group = TranscriptSegment(start: word.start, end: word.end, text: word.text, track: segment.track, speakerID: id, language: segment.language)
                        group?.words = [word]
                    } else { group?.text += word.text; group?.end = word.end; group?.words?.append(word) }
                }
                if var group { group.text = group.text.trimmingCharacters(in: .whitespacesAndNewlines); output.segments.append(group) }
            } else {
                var value = segment; value.speakerID = identity(at: (segment.start + segment.end) / 2); output.segments.append(value)
            }
        }
        for index in clusters.centroids.indices { output.speakerNames[String(format: "speaker_%03d", index + 1)] = "Parlante \(index + 1)" }
        output.segments.sort { $0.start < $1.start }
        output.revision += 1
        return output
    }
}
