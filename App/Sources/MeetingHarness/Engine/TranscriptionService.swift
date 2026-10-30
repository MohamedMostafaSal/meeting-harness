import Foundation
import HarnessCore
import Observation
import UIKit
import WhisperKit

/// Runs the harness pipeline for meetings, one at a time, and saves the results.
@MainActor
@Observable
final class TranscriptionService {
    struct Run: Equatable {
        var stage: PipelineProgress.Stage
        var completed: Int
        var total: Int

        var fraction: Double? { total > 0 ? Double(completed) / Double(total) : nil }
    }

    private(set) var runs: [String: Run] = [:]
    private var queue: [String] = []
    private var working = false

    private let store: MeetingStore
    private let models: ModelManager
    private let settings: AppSettings
    private let voices: VoiceStore

    init(store: MeetingStore, models: ModelManager, settings: AppSettings, voices: VoiceStore) {
        self.store = store
        self.models = models
        self.settings = settings
        self.voices = voices
    }

    func isQueued(_ id: String) -> Bool { queue.contains(id) || runs[id] != nil }

    func enqueue(_ meeting: Meeting) {
        guard !isQueued(meeting.id) else { return }
        queue.append(meeting.id)
        var waiting = meeting
        waiting.status = .transcribing
        waiting.failure = nil
        store.update(waiting)
        Task { await drain() }
    }

    private func drain() async {
        guard !working else { return }
        working = true
        defer { working = false }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let meeting = store.meeting(id) else { continue }
            await run(meeting)
        }
    }

    private func run(_ meeting: Meeting) async {
        let missing = models.missing(for: settings.languages)
        guard missing.isEmpty else {
            var waiting = meeting
            waiting.status = .needsModels
            store.update(waiting)
            return
        }

        runs[meeting.id] = Run(stage: .speakers, completed: 0, total: 0)
        UIApplication.shared.isIdleTimerDisabled = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "transcribe")
        defer {
            runs[meeting.id] = nil
            UIApplication.shared.isIdleTimerDisabled = false
            UIApplication.shared.endBackgroundTask(background)
        }

        do {
            let pipeline = makePipeline()
            let audioPath = store.audioURL(for: meeting).path
            let meetingID = meeting.id
            let sink = InMemoryEventSink()
            // Heavy work off the main thread; progress hops back to it.
            let transcript = try await Task.detached(priority: .userInitiated) {
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
                let clip = AudioClip(samples: samples, sampleRate: 16_000)
                return try await pipeline.transcribe(clip, meetingID: meetingID, sink: sink) { progress in
                    Task { @MainActor in
                        self.runs[meetingID] = Run(stage: progress.stage, completed: progress.completed, total: progress.total)
                    }
                }
            }.value
            try store.save(transcript: transcript, events: sink.events, report: pipeline.report, voices: pipeline.speakerVoices, for: meeting)
        } catch {
            var failed = meeting
            failed.status = .failed
            failed.failure = error.localizedDescription
            store.update(failed)
        }
    }

    /// The harness wired to whichever packs are installed.
    func makePipeline() -> Pipeline {
        let languages = settings.languages
        var recognizers: [any SpeechRecognizer] = []
        var multilingual: WhisperModel?
        if let folder = models.folder(for: .multilingual) {
            let model = WhisperModel(folder: folder)
            multilingual = model
            recognizers.append(WhisperRecognizer(
                descriptor: RecognizerDescriptor(model: ModelInfo(id: "whisper-base", version: "coreml"), languages: [], isMultilingual: true),
                model: model, forcesLanguage: true))
        }
        if let folder = models.folder(for: .english) {
            recognizers.append(WhisperRecognizer(
                descriptor: RecognizerDescriptor(model: ModelInfo(id: "whisper-small.en", version: "coreml"), languages: [.english]),
                model: WhisperModel(folder: folder), forcesLanguage: false))
        }
        if let folder = models.folder(for: .arabic) {
            recognizers.append(WhisperRecognizer(
                descriptor: RecognizerDescriptor(model: ModelInfo(id: "whisper-small-eg", version: "coreml"), languages: [.arabic], variant: "egyptian"),
                model: WhisperModel(folder: folder), forcesLanguage: true))
        }
        let diarizer: any Diarizer = models.folder(for: .speakers).map { SpeakerKitDiarizer(folder: $0) }
            ?? NoSpeechDiarizer()
        let languageID: any LanguageIdentifier = multilingual.map { WhisperLanguageID(model: $0, allowed: languages) }
            ?? FixedLanguageID(language: languages.first ?? "en")
        return Pipeline(
            models: PipelineModels(diarizer: diarizer, languageID: languageID, recognizers: recognizers),
            policy: settings.policy,
            registry: voices.registry)
    }

    /// A fingerprint of the main voice in a recording, for "My voice".
    func fingerprint(ofAudioAt url: URL) async throws -> SpeakerEmbedding? {
        guard let folder = models.folder(for: .speakers) else { return nil }
        let diarizer = SpeakerKitDiarizer(folder: folder)
        defer { Task { await diarizer.unload() } }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        return try await diarizer.fingerprint(of: AudioClip(samples: samples, sampleRate: 16_000))
    }
}

/// Used only when the Speakers pack is missing; runs are refused before that, so it finds nothing.
private struct NoSpeechDiarizer: Diarizer {
    func diarize(_ audio: AudioClip) async throws -> Diarization { Diarization(turns: []) }
}

/// When only one meeting language is set there is nothing to detect.
private struct FixedLanguageID: LanguageIdentifier {
    let language: String
    func identify(_ audio: AudioClip) async throws -> [LanguageGuess] { [LanguageGuess(LanguageCode(language), 1)] }
}
