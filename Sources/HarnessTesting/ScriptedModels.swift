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

/// A diarizer that answers with fixed turns and centroids, like SpeakerKit would.
public final class ScriptedDiarizer: Diarizer, ModelLifecycle {
    public var diarization: Diarization
    public private(set) var unloads = 0

    public init(_ diarization: Diarization) { self.diarization = diarization }

    public func diarize(_ audio: AudioClip) async throws -> Diarization { diarization }
    public func unload() async { unloads += 1 }
}

/// Records the order models are used and unloaded in, across all scripted models.
public final class ModelLog {
    public private(set) var entries: [String] = []
    public init() {}
    public func add(_ entry: String) { entries.append(entry) }
}

public final class ScriptedRecognizer: SpeechRecognizer, ModelLifecycle {
    public struct Call: Equatable {
        public var range: TimeRange
        public var language: LanguageCode?
    }

    public let descriptor: RecognizerDescriptor
    public var script: (TimeRange, LanguageCode?) -> RecognitionResult
    /// Every call made, so tests can assert which model handled what (and that silence reached none).
    public private(set) var calls: [Call] = []
    public var log: ModelLog?

    public init(_ descriptor: RecognizerDescriptor, script: @escaping (TimeRange, LanguageCode?) -> RecognitionResult) {
        self.descriptor = descriptor
        self.script = script
    }

    public func transcribe(_ audio: AudioClip, language: LanguageCode?) async throws -> RecognitionResult {
        calls.append(Call(range: audio.timeRange, language: language))
        log?.add("transcribe \(descriptor.model.id)")
        return script(audio.timeRange, language)
    }

    public func unload() async { log?.add("unload \(descriptor.model.id)") }
}

public struct ScriptedSpeakerSegmenter: SpeakerSegmenter {
    public var turns: [TimeRange]

    public init(turns: [TimeRange]) { self.turns = turns }

    /// The scripted turns that fall inside the clip; the pipeline clamps them to the region.
    public func speakerTurns(in audio: AudioClip) async throws -> [TimeRange] {
        let range = audio.timeRange
        return turns.filter { $0.start < range.end && range.start < $0.end }
    }
}

public struct ScriptedOverlapDetector: OverlapDetector {
    public var regions: [TimeRange]

    public init(regions: [TimeRange]) { self.regions = regions }

    public func overlapRegions(in audio: AudioClip) async throws -> [TimeRange] { regions }
}

public final class ScriptedEmbedder: SpeakerEmbedder {
    public var script: (TimeRange) -> SpeakerEmbedding
    public private(set) var calls: [TimeRange] = []

    public init(_ script: @escaping (TimeRange) -> SpeakerEmbedding) { self.script = script }

    public func embed(_ audio: AudioClip) async throws -> SpeakerEmbedding {
        calls.append(audio.timeRange)
        return script(audio.timeRange)
    }
}

/// The README's example meeting. Sara (enrolled) opens in English, a guest
/// answers, then Sara says an Egyptian Arabic sentence that switches to English
/// halfway through.
public struct DemoMeeting {
    public static let englishOpening = TimeRange(start: 2.0, end: 5.5)
    public static let saraOpens = TimeRange(start: 2.0, end: 3.6)
    public static let guestAnswers = TimeRange(start: 3.6, end: 5.5)
    public static let codeSwitch = TimeRange(start: 12.4, end: 15.1)

    public static let saraVoice = SpeakerEmbedding([1, 0, 0])
    public static let guestVoice = SpeakerEmbedding([0, 1, 0])

    public let audio: AudioClip
    public let english: ScriptedRecognizer
    public let egyptian: ScriptedRecognizer
    public let msa: ScriptedRecognizer
    public let multilingual: ScriptedRecognizer
    public let embedder: ScriptedEmbedder
    /// Sara is enrolled; the guest is not.
    public let registry: SpeakerRegistry

    // Knobs tests turn to vary the meeting.
    public var speechRegions = [DemoMeeting.englishOpening, DemoMeeting.codeSwitch]
    public var overlapRegions: [TimeRange] = []
    /// Without speaker models the pipeline only finds speech, not who spoke.
    public var useSpeakerModels = true

    public init() {
        // Low sample rate: the scripted models never look at the samples.
        audio = .silence(duration: 20, sampleRate: 1_000)
        english = ScriptedRecognizer(
            RecognizerDescriptor(model: ModelInfo(id: "asr-en-small", version: "0.1"), languages: [.english])
        ) { range, _ in
            if range.start < Self.guestAnswers.start { return RecognitionResult(text: "let's get started", confidence: 0.93) }
            if range.start < 6 { return RecognitionResult(text: "sounds good", confidence: 0.9) }
            return RecognitionResult(text: "quarterly review", confidence: 0.91)
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
        // Real fingerprints are never exact; these are close to, not equal to, the enrolled voice.
        embedder = ScriptedEmbedder { range in
            range.midpoint > Self.guestAnswers.start && range.midpoint < Self.guestAnswers.end
                ? SpeakerEmbedding([0.1, 0.95, 0.05])
                : SpeakerEmbedding([0.95, 0.1, 0.05])
        }
        var registry = SpeakerRegistry()
        registry.enroll(SpeakerID("sara"), name: "Sara", embedding: Self.saraVoice)
        self.registry = registry
    }

    public var models: PipelineModels {
        let vad = ScriptedVAD(regions: speechRegions)
        let diarizer: any Diarizer = useSpeakerModels
            ? SegmentAndClusterDiarizer(vad: vad, speakers: SpeakerModels(
                segmenter: ScriptedSpeakerSegmenter(turns: [Self.saraOpens, Self.guestAnswers, Self.codeSwitch]),
                embedder: embedder,
                overlap: overlapRegions.isEmpty ? nil : ScriptedOverlapDetector(regions: overlapRegions)))
            : VADOnlyDiarizer(vad: vad)
        return PipelineModels(
            diarizer: diarizer,
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
