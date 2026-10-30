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

    /// Absolute sample index where the current sentence starts.
    private var sentenceStart = 0
    private var lastDraftAt = 0
    private var lastLanguage: LanguageCode?

    private let rate = LiveBuffer.sampleRate
    private let pauseSeconds = 0.6
    private let maxSentenceSeconds = 18.0
    private let draftEverySeconds = 2.0
    private let silenceRMS: Float = 0.008

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
        let now = buffer.totalSamples
        let length = Double(now - sentenceStart) / Double(rate)
        guard length >= 1 else { return }
        let (samples, start) = buffer.samples(from: sentenceStart)
        if start > sentenceStart { sentenceStart = start }

        let paused = isSilent(samples.suffix(Int(pauseSeconds * Double(rate))))
        let hasSpeech = !isSilent(samples[...])
        if !hasSpeech {
            // Nothing but silence so far: move the sentence start along.
            sentenceStart = max(sentenceStart, now - Int(pauseSeconds * Double(rate)))
            return
        }
        if paused || length >= maxSentenceSeconds {
            await commit(samples, start: start)
            sentenceStart = now
            lastDraftAt = now
        } else if Double(now - lastDraftAt) / Double(rate) >= draftEverySeconds {
            lastDraftAt = now
            await transcribeDraft(samples, start: start)
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

    private func isSilent(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Float = 0
        for x in samples { sum += x * x }
        return (sum / Float(samples.count)).squareRoot() < silenceRMS
    }

    /// Demo captions for screenshots.
    func showDemo(_ captions: [(lang: String, text: String)], draft: String) {
        lines = captions.map { Caption(language: $0.lang, text: $0.text) }
        self.draft = Caption(language: "ar", text: draft)
    }
}
