import CoreML
import Foundation
import HarnessCore
import SpeakerKit
import WhisperKit

// Adapters from Argmax's on-device models to the harness contracts. They load
// lazily and unload when the pipeline says their phase is over, so at most one
// large model holds memory at a time.

/// M1–M4: pyannote (community-1) via SpeakerKit. Its speaker clustering is kept;
/// the harness names speakers from the per-speaker centroids.
final class OnDeviceDiarizer: HarnessCore.Diarizer, ModelLifecycle {
    private let folder: URL
    private var kit: SpeakerKit?

    init(folder: URL) { self.folder = folder }

    func diarize(_ audio: AudioClip) async throws -> Diarization {
        let kit = try await loaded()
        let result = try await kit.diarize(audioArray: audio.samples, options: PyannoteDiarizationOptions(useExclusiveReconciliation: true))
        let offset = audio.startTime
        let turns = result.segments.compactMap { segment -> DiarizedTurn? in
            let start = offset + Double(segment.startTime), end = offset + Double(segment.endTime)
            guard end > start else { return nil }
            switch segment.speaker {
            case .speakerId(let id): return DiarizedTurn(range: TimeRange(start: start, end: end), speaker: id)
            case .multiple: return DiarizedTurn(range: TimeRange(start: start, end: end), speaker: nil, overlap: true)
            case .noMatch: return DiarizedTurn(range: TimeRange(start: start, end: end), speaker: nil)
            }
        }
        let centroids = result.speakerCentroidEmbeddings.mapValues { SpeakerEmbedding($0) }
        return Diarization(turns: turns, centroids: centroids)
    }

    /// The voice fingerprint of the main speaker in a short clip, for enrolling a voice.
    func fingerprint(of audio: AudioClip) async throws -> SpeakerEmbedding? {
        let diarization = try await diarize(audio)
        var talk: [Int: Double] = [:]
        for turn in diarization.turns { if let s = turn.speaker { talk[s, default: 0] += turn.range.duration } }
        guard let main = talk.max(by: { $0.value < $1.value })?.key else { return nil }
        return diarization.centroids[main]
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    private func loaded() async throws -> SpeakerKit {
        if let kit { return kit }
        let kit = try await SpeakerKit(PyannoteConfig(modelFolder: folder.path, download: false, load: true, verbose: false))
        self.kit = kit
        return kit
    }
}

/// Loads a WhisperKit model from a downloaded folder on first use.
final class WhisperModel {
    let folder: URL
    private(set) var kit: WhisperKit?

    init(folder: URL) { self.folder = folder }

    func loaded() async throws -> WhisperKit {
        if let kit { return kit }
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        self.kit = kit
        return kit
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}

extension WhisperRecognizer {
    /// Tokens for bracketed notes and symbols ("[music]", "♪"), which Whisper must not
    /// write in a transcript. OpenAI's Whisper and transformers suppress these by default;
    /// WhisperKit suppresses nothing unless told to. Without this, the Egyptian model
    /// turned 26 s of speech into "[مايام الوليد]" (eval/results/coreml-check-2026-10-30.md).
    /// Built from the tokenizer the way OpenAI's `non_speech_tokens` does.
    static func nonSpeechTokens(_ tokenizer: any WhisperTokenizer) -> [Int] {
        let special = tokenizer.specialTokens.specialTokenBegin
        func encode(_ text: String) -> [Int] { tokenizer.encode(text: text).filter { $0 < special } }
        var symbols = "\"#()*+/:;<=>@[\\]^_`{|}~「」『』".map(String.init)
        symbols += "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split(separator: " ").map(String.init)
        let miscellaneous = Set("♩♪♫♬♭♮♯".map(String.init))
        var result = Set<Int>()
        for text in [" -", " '"] { if let first = encode(text).first { result.insert(first) } }
        for symbol in symbols + miscellaneous.sorted() {
            for tokens in [encode(symbol), encode(" " + symbol)] where tokens.count == 1 || (miscellaneous.contains(symbol) && !tokens.isEmpty) {
                result.insert(tokens[0])
            }
        }
        return result.sorted()
    }
}

/// M7: one Whisper model behind the `SpeechRecognizer` contract.
final class WhisperRecognizer: SpeechRecognizer, ModelLifecycle {
    let descriptor: RecognizerDescriptor
    private let model: WhisperModel
    /// English-only models must not be given a language.
    private let forcesLanguage: Bool

    init(descriptor: RecognizerDescriptor, model: WhisperModel, forcesLanguage: Bool) {
        self.descriptor = descriptor
        self.model = model
        self.forcesLanguage = forcesLanguage
    }

    func transcribe(_ audio: AudioClip, language: LanguageCode?) async throws -> RecognitionResult {
        let kit = try await model.loaded()
        let options = DecodingOptions(
            task: .transcribe,
            language: forcesLanguage ? language?.rawValue : nil,
            temperatureFallbackCount: 3,
            usePrefillPrompt: forcesLanguage && language != nil,
            detectLanguage: forcesLanguage && language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            suppressTokens: kit.tokenizer.map(Self.nonSpeechTokens) ?? [])
        let results = try await kit.transcribe(audioArray: audio.samples, decodeOptions: options)
        let segments = results.flatMap(\.segments)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Confidence: the duration-weighted mean token probability.
        let weighted = segments.reduce(into: (sum: 0.0, weight: 0.0)) { acc, s in
            let w = Double(max(s.end - s.start, 0.1))
            acc.sum += exp(Double(s.avgLogprob)) * w
            acc.weight += w
        }
        let confidence = weighted.weight > 0 ? weighted.sum / weighted.weight : 0
        let detected = results.first.map { LanguageCode($0.language) }
        return RecognitionResult(text: text, confidence: confidence, detectedLanguage: detected)
    }

    func unload() async { await model.unload() }
}

/// M6: Whisper's language-token scores after <|startoftranscript|>, renormalized
/// over the meeting's languages only. WhisperKit's own detector reports just the
/// winning language, so this reads the scores through a sampler hook.
final class WhisperLanguageID: LanguageIdentifier, ModelLifecycle {
    private let model: WhisperModel
    private let allowed: [String]

    init(model: WhisperModel, allowed: [String]) {
        self.model = model
        self.allowed = allowed
    }

    func identify(_ audio: AudioClip) async throws -> [LanguageGuess] {
        if allowed.count == 1 { return [LanguageGuess(LanguageCode(allowed[0]), 1)] }
        let kit = try await model.loaded()
        guard let tokenizer = kit.tokenizer else { throw WhisperError.tokenizerUnavailable() }

        var tokens: [String: Int] = [:]
        for code in allowed {
            if let id = tokenizer.convertTokenToId("<|\(code)|>") { tokens[code] = id }
        }
        let window = kit.featureExtractor.windowSamples ?? 480_000
        guard let samples = kit.audioProcessor.padOrTrim(fromArray: audio.samples, startAt: 0, toLength: window),
              let mel = try await kit.featureExtractor.logMelSpectrogram(fromAudio: samples),
              let encoded = try await kit.audioEncoder.encodeFeatures(mel) else {
            throw WhisperError.transcriptionFailed("Could not encode audio for language detection")
        }
        let inputs = try kit.textDecoder.prepareDecoderInputs(withPrompt: [tokenizer.specialTokens.startOfTranscriptToken])
        let options = DecodingOptions()
        let sampler = LanguageScoreSampler(
            tokens: tokens,
            inner: GreedyTokenSampler(temperature: 0, eotToken: tokenizer.specialTokens.endToken, decodingOptions: options))
        _ = try await kit.textDecoder.detectLanguage(from: encoded, using: inputs, sampler: sampler, options: options, temperature: 0)

        let scores = sampler.scores
        guard let maxScore = scores.values.max() else { return [] }
        let exps = scores.mapValues { exp(Double($0 - maxScore)) }
        let total = exps.values.reduce(0, +)
        return exps.map { LanguageGuess(LanguageCode($0.key), $0.value / total) }
            .sorted { $0.confidence > $1.confidence }
    }

    func unload() async { await model.unload() }
}

/// Passes sampling through, but records the logits of the meeting's language tokens.
final class LanguageScoreSampler: TokenSampling {
    private let tokens: [String: Int]
    private let inner: TokenSampling
    private(set) var scores: [String: Float] = [:]

    init(tokens: [String: Int], inner: TokenSampling) {
        self.tokens = tokens
        self.inner = inner
    }

    func update(tokens current: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        for (code, id) in tokens where id < logits.count {
            scores[code] = logits[id].floatValue
        }
        return await inner.update(tokens: current, logits: logits, logProbs: logProbs)
    }

    func finalize(tokens current: [Int], logProbs: [Float]) -> SamplingResult {
        inner.finalize(tokens: current, logProbs: logProbs)
    }
}
