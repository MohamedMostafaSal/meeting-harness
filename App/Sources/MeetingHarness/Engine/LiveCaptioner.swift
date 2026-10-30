import Foundation
import HarnessCore
import Observation

/// Live captions while recording: the draft pass of "draft live, refine later".
///
/// Pauses cut the speech into sentences. While someone talks, the current sentence
/// is re-transcribed every couple of seconds as a draft; at a pause it is committed
/// in the language detected for it (among the meeting's languages). The full
/// pipeline still runs after recording and replaces these drafts.
@MainActor
@Observable
final class LiveCaptioner {
    struct Caption: Identifiable, Equatable {
        let id = UUID()
        var language: String?
        var text: String
    }

    private(set) var lines: [Caption] = []
    private(set) var draft: Caption?
    private(set) var running = false

    private let buffer: LiveBuffer
    private let languageID: any LanguageIdentifier
    private let recognizer: any SpeechRecognizer
    private var task: Task<Void, Never>?

    private var sentences = LiveSentences(sampleRate: LiveBuffer.sampleRate)
    private var lastLanguage: LanguageCode?
    private let rate = LiveBuffer.sampleRate

    init(buffer: LiveBuffer, languageID: any LanguageIdentifier, recognizer: any SpeechRecognizer) {
        self.buffer = buffer
        self.languageID = languageID
        self.recognizer = recognizer
    }

    func start() {
        guard task == nil else { return }
        running = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.step()
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        running = false
        await (recognizer as? ModelLifecycle)?.unload()
    }

    private func step() async {
        let total = buffer.totalSamples
        let (samples, start) = buffer.samples(from: sentences.sentenceStart)
        switch sentences.step(total: total, samples: samples[...], start: start) {
        case .commit(let from):
            await commit(Array(samples[max(0, from - start)...]), start: from)
        case .draft(let from):
            await transcribeDraft(Array(samples[max(0, from - start)...]), start: from)
        case .wait, .skip:
            break
        }
    }

    private func commit(_ samples: [Float], start: Int) async {
        let clip = AudioClip(samples: samples, sampleRate: rate, startTime: Double(start) / Double(rate))
        let guesses = (try? await languageID.identify(clip)) ?? []
        let language = guesses.top?.language ?? lastDraftLanguage
        guard let result = try? await recognizer.transcribe(clip, language: language) else { return }
        draft = nil
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HallucinationGuard.check(text, duration: clip.duration) == .ok else { return }
        lastLanguage = language
        lines.append(Caption(language: language?.rawValue, text: text))
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
    }

    private func transcribeDraft(_ samples: [Float], start: Int) async {
        let clip = AudioClip(samples: samples, sampleRate: rate, startTime: Double(start) / Double(rate))
        guard let result = try? await recognizer.transcribe(clip, language: lastDraftLanguage) else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HallucinationGuard.check(text, duration: clip.duration) == .ok else { return }
        draft = Caption(language: (lastDraftLanguage ?? result.detectedLanguage)?.rawValue, text: text)
    }

    /// Drafts reuse the last sentence's language; detection runs once per sentence.
    private var lastDraftLanguage: LanguageCode? { lastLanguage }

    /// Demo captions for screenshots.
    func showDemo(_ captions: [(lang: String, text: String)], draft: String) {
        lines = captions.map { Caption(language: $0.lang, text: $0.text) }
        self.draft = Caption(language: "ar", text: draft)
    }
}
