import HarnessCore

// Scripted stand-ins for the AI pillars. They answer from the clip's position on
// the meeting timeline, so a whole pipeline run can be specified up front and
// tested without audio, models or a phone.

public struct ScriptedVAD: VoiceActivityDetector {
    public var regions: [TimeRange]

    public init(regions: [TimeRange]) { self.regions = regions }

    public func speechRegions(in audio: AudioClip) async throws -> [TimeRange] { regions }
}

public struct ScriptedLanguageID: LanguageIdentifier {
    public var script: (TimeRange) -> [LanguageGuess]

    public init(_ script: @escaping (TimeRange) -> [LanguageGuess]) { self.script = script }

    public func identify(_ audio: AudioClip) async throws -> [LanguageGuess] { script(audio.timeRange) }
}

public final class ScriptedRecognizer: SpeechRecognizer {
    public struct Call: Equatable {
        public var range: TimeRange
        public var language: LanguageCode?
    }

    public let descriptor: RecognizerDescriptor
    public var script: (TimeRange, LanguageCode?) -> RecognitionResult
    /// Every call made, so tests can assert which model handled what (and that silence reached none).
    public private(set) var calls: [Call] = []

    public init(_ descriptor: RecognizerDescriptor, script: @escaping (TimeRange, LanguageCode?) -> RecognitionResult) {
        self.descriptor = descriptor
        self.script = script
    }

    public func transcribe(_ audio: AudioClip, language: LanguageCode?) async throws -> RecognitionResult {
        calls.append(Call(range: audio.timeRange, language: language))
        return script(audio.timeRange, language)
    }
}

/// The README's example meeting: an English opening, then an Egyptian Arabic
/// sentence that switches to English halfway through.
public struct DemoMeeting {
    public static let englishOpening = TimeRange(start: 2.0, end: 5.5)
    public static let codeSwitch = TimeRange(start: 12.4, end: 15.1)

    public let audio: AudioClip
    public let english: ScriptedRecognizer
    public let egyptian: ScriptedRecognizer
    public let msa: ScriptedRecognizer
    public let multilingual: ScriptedRecognizer

    public init() {
        // Low sample rate: the scripted models never look at the samples.
        audio = .silence(duration: 20, sampleRate: 1_000)
        english = ScriptedRecognizer(
            RecognizerDescriptor(model: ModelInfo(id: "asr-en-small", version: "0.1"), languages: [.english])
        ) { range, _ in
            range.start < 6
                ? RecognitionResult(text: "let's get started", confidence: 0.93)
                : RecognitionResult(text: "quarterly review", confidence: 0.91)
        }
        egyptian = ScriptedRecognizer(
            RecognizerDescriptor(model: ModelInfo(id: "asr-ar-eg-small", version: "0.1"), languages: [.arabic], variant: "egyptian")
        ) { _, _ in RecognitionResult(text: "خلينا نبدأ بالـ", confidence: 0.88) }
        msa = ScriptedRecognizer(
            RecognizerDescriptor(model: ModelInfo(id: "asr-ar-msa-small", version: "0.1"), languages: [.arabic], variant: "msa")
        ) { _, _ in RecognitionResult(text: "(msa should not be used)", confidence: 0.9) }
        multilingual = ScriptedRecognizer(
            RecognizerDescriptor(model: ModelInfo(id: "asr-multi-tiny", version: "0.1"), languages: [], isMultilingual: true)
        ) { _, _ in RecognitionResult(text: "(fallback should not be used)", confidence: 0.5) }
    }

    public var models: PipelineModels {
        PipelineModels(
            vad: ScriptedVAD(regions: [Self.englishOpening, Self.codeSwitch]),
            languageID: ScriptedLanguageID { range in
                if range.end <= 6 { return [LanguageGuess(.english, 0.98)] }
                // As a whole the mixed sentence is ambiguous; short windows are clear.
                if range.duration > 2 { return [LanguageGuess(.arabic, 0.62), LanguageGuess(.english, 0.35)] }
                return range.midpoint < 13.5 ? [LanguageGuess(.arabic, 0.94)] : [LanguageGuess(.english, 0.97)]
            },
            // MSA is listed before Egyptian on purpose: the policy, not the order, picks the variant.
            recognizers: [english, msa, egyptian, multilingual]
        )
    }
}
