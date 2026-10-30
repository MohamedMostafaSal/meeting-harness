import Foundation

// The contracts for the AI pillars. The harness only ever talks to these
// protocols, so any model (Core ML, a scripted fake, a future Android runtime)
// can be swapped in without touching routing or merging.

/// Mono PCM audio placed on the meeting timeline.
public struct AudioClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    /// Where `samples[0]` sits on the meeting timeline, in seconds.
    public var startTime: Double

    public init(samples: [Float], sampleRate: Int, startTime: Double = 0) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public static func silence(duration: Double, sampleRate: Int, startTime: Double = 0) -> AudioClip {
        AudioClip(
            samples: [Float](repeating: 0, count: Int((duration * Double(sampleRate)).rounded())),
            sampleRate: sampleRate,
            startTime: startTime)
    }

    public var duration: Double { Double(samples.count) / Double(sampleRate) }
    public var timeRange: TimeRange { TimeRange(start: startTime, end: startTime + duration) }

    /// The part of this clip inside `range`, where `range` is in meeting time.
    public func slice(_ range: TimeRange) -> AudioClip {
        let rate = Double(sampleRate)
        let from = max(0, Int(((range.start - startTime) * rate).rounded()))
        let to = min(samples.count, Int(((range.end - startTime) * rate).rounded()))
        guard from < to else {
            return AudioClip(samples: [], sampleRate: sampleRate, startTime: range.start)
        }
        return AudioClip(
            samples: Array(samples[from..<to]),
            sampleRate: sampleRate,
            startTime: startTime + Double(from) / rate)
    }
}

/// M1: where is someone speaking? Nothing reaches speech-to-text without passing this.
public protocol VoiceActivityDetector {
    func speechRegions(in audio: AudioClip) async throws -> [TimeRange]
}

public struct LanguageGuess: Equatable, Sendable {
    public var language: LanguageCode
    public var confidence: Double

    public init(_ language: LanguageCode, _ confidence: Double) {
        self.language = language
        self.confidence = confidence
    }
}

extension Array where Element == LanguageGuess {
    /// The most confident guess.
    public var top: LanguageGuess? { self.max { $0.confidence < $1.confidence } }
}

/// M6: which language is this? Decides language only, never dialect: the
/// Arabic variant is a setting (`RouterPolicy.preferredVariants`).
public protocol LanguageIdentifier {
    func identify(_ audio: AudioClip) async throws -> [LanguageGuess]
}

public struct RecognitionResult: Equatable, Sendable {
    public var text: String
    public var words: [Word]
    public var confidence: Double
    /// Only multilingual recognizers fill this in.
    public var detectedLanguage: LanguageCode?

    public init(text: String, words: [Word] = [], confidence: Double, detectedLanguage: LanguageCode? = nil) {
        self.text = text
        self.words = words
        self.confidence = confidence
        self.detectedLanguage = detectedLanguage
    }
}

/// What the router needs to know about an installed speech-to-text model.
public struct RecognizerDescriptor: Hashable, Sendable {
    public var model: ModelInfo
    public var languages: Set<LanguageCode>
    /// e.g. "egyptian" or "msa" for Arabic specialists.
    public var variant: String?
    /// The catch-all used when no specialist fits. `languages` is ignored for it.
    public var isMultilingual: Bool

    public init(model: ModelInfo, languages: Set<LanguageCode>, variant: String? = nil, isMultilingual: Bool = false) {
        self.model = model
        self.languages = languages
        self.variant = variant
        self.isMultilingual = isMultilingual
    }
}

/// M7: what was said? One conformer per language specialist, plus the multilingual fallback.
public protocol SpeechRecognizer {
    var descriptor: RecognizerDescriptor { get }
    /// `language` is nil when the router doesn't trust any language guess.
    func transcribe(_ audio: AudioClip, language: LanguageCode?) async throws -> RecognitionResult
}

/// M8: punctuation and casing for a raw word stream.
public protocol PunctuationRestorer {
    func restore(_ text: String, language: LanguageCode?) async throws -> String
}
