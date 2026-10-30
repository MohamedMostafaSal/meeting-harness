/// Every number the pipeline decides by, in one place (D5, D8, D3, D6).
public struct PipelinePolicy: Sendable {
    public var router: RouterPolicy
    public var speakers: SpeakerPolicy
    public var utterances: UtterancePolicy
    public var merge: MergePolicy
    /// Bring quiet recordings up to a standard level before any model hears them (D1).
    public var normalizeLoudness: Bool

    public init(
        router: RouterPolicy = RouterPolicy(),
        speakers: SpeakerPolicy = SpeakerPolicy(),
        utterances: UtterancePolicy = UtterancePolicy(),
        merge: MergePolicy = MergePolicy(),
        normalizeLoudness: Bool = true
    ) {
        self.router = router
        self.speakers = speakers
        self.utterances = utterances
        self.merge = merge
        self.normalizeLoudness = normalizeLoudness
    }
}

/// How a speaker's consecutive turns are joined into one utterance for transcription.
public struct UtterancePolicy: Sendable {
    /// Turns by the same speaker closer than this are transcribed together.
    public var maxGap: Double
    /// Whisper reads at most 30 s at a time.
    public var maxDuration: Double

    public init(maxGap: Double = 1.5, maxDuration: Double = 28) {
        self.maxGap = maxGap
        self.maxDuration = maxDuration
    }
}

/// How neighbouring transcript segments are joined for reading (D6).
public struct MergePolicy: Sendable {
    public var maxGap: Double
    public var maxDuration: Double

    public init(maxGap: Double = 0.6, maxDuration: Double = 30) {
        self.maxGap = maxGap
        self.maxDuration = maxDuration
    }
}
