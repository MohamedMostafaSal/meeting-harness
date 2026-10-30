/// The sentence rules behind live captions (the draft pass of "draft live, refine
/// later"), shared by the iPhone app and mirrored by web/harness.js `liveStep`.
///
/// Pauses cut speech into sentences. While someone talks, the sentence is
/// re-transcribed every couple of seconds as a draft; at a pause (or after a long
/// monologue) it is committed.
public struct LiveSentences: Sendable {
    public struct Policy: Sendable {
        public var pauseSeconds = 0.6
        public var maxSentenceSeconds = 18.0
        public var draftEverySeconds = 2.0
        public var silenceRMS: Float = 0.008
        public var minSeconds = 1.0
        public init() {}
    }

    public enum Action: Equatable, Sendable {
        case wait
        /// Only silence so far; nothing to transcribe.
        case skip
        /// Re-transcribe the sentence in progress, from this absolute sample.
        case draft(from: Int)
        /// The sentence ended: transcribe it for good, from this absolute sample.
        case commit(from: Int)
    }

    public var policy: Policy
    public let sampleRate: Int
    /// Absolute sample where the current sentence starts.
    public private(set) var sentenceStart = 0
    private var lastDraftAt = 0

    public init(sampleRate: Int = 16_000, policy: Policy = Policy()) {
        self.sampleRate = sampleRate
        self.policy = policy
    }

    /// Decides the next step. `samples` are the buffered audio starting at absolute
    /// index `start` and running to `total`.
    public mutating func step(total: Int, samples: ArraySlice<Float>, start: Int) -> Action {
        sentenceStart = max(sentenceStart, start)
        let length = Double(total - sentenceStart) / Double(sampleRate)
        guard length >= policy.minSeconds else { return .wait }
        let sentence = samples.suffix(total - sentenceStart)
        let pauseSamples = Int(policy.pauseSeconds * Double(sampleRate))
        guard Self.rms(sentence) >= policy.silenceRMS else {
            sentenceStart = max(sentenceStart, total - pauseSamples)
            return .skip
        }
        if Self.rms(sentence.suffix(pauseSamples)) < policy.silenceRMS || length >= policy.maxSentenceSeconds {
            let from = sentenceStart
            sentenceStart = total
            lastDraftAt = total
            return .commit(from: from)
        }
        if Double(total - lastDraftAt) / Double(sampleRate) >= policy.draftEverySeconds {
            lastDraftAt = total
            return .draft(from: sentenceStart)
        }
        return .wait
    }

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        return (sum / Float(samples.count)).squareRoot()
    }
}
