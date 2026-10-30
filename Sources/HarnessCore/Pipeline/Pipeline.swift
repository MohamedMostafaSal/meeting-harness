import Foundation

/// The AI pillars a pipeline runs with. Each is only a contract; see `Contracts.swift`.
public struct PipelineModels {
    public var vad: any VoiceActivityDetector
    public var languageID: any LanguageIdentifier
    public var recognizers: [any SpeechRecognizer]
    public var punctuation: (any PunctuationRestorer)?

    public init(
        vad: any VoiceActivityDetector,
        languageID: any LanguageIdentifier,
        recognizers: [any SpeechRecognizer],
        punctuation: (any PunctuationRestorer)? = nil
    ) {
        self.vad = vad
        self.languageID = languageID
        self.recognizers = recognizers
        self.punctuation = punctuation
    }
}

/// Recording-mode pipeline (v1): VAD → language ID → router → speech-to-text →
/// punctuation → confidence gating → events.
///
/// Speaker diarization (M2–M4) is not wired in yet; segments have no speaker.
public final class Pipeline {
    public let models: PipelineModels
    public let router: Router

    public init(models: PipelineModels, policy: RouterPolicy = RouterPolicy()) {
        self.models = models
        self.router = Router(policy: policy, installed: models.recognizers.map { $0.descriptor })
    }

    /// Transcribes a whole recording and emits one `segment.final` per segment.
    public func transcribe(_ audio: AudioClip, meetingID: String, sink: (any EventSink)? = nil) async throws -> Transcript {
        let events = EventEmitter(meetingID: meetingID, sink: sink)
        try await events.emit(.meetingStarted)

        var transcript = Transcript(meetingID: meetingID)
        let regions = try await models.vad.speechRegions(in: audio).sorted { $0.start < $1.start }
        for region in regions {
            for piece in try await plan(audio.slice(region)) {
                let outcome = try await recognize(piece, in: audio, index: transcript.segments.count + 1)
                switch outcome {
                case .segment(let segment):
                    transcript.segments.append(segment)
                    try await events.emit(.segmentFinal(segment))
                case .gap(let gap):
                    transcript.gaps.append(gap)
                case .silent:
                    break
                }
            }
        }

        try await events.emit(.meetingEnded)
        return transcript
    }

    // MARK: - Planning

    struct Piece {
        var range: TimeRange
        var decision: RouteDecision
    }

    /// Routes one speech region. If its language is ambiguous, re-identifies it in
    /// short windows and joins neighbouring windows that agree (code-switching).
    func plan(_ clip: AudioClip) async throws -> [Piece] {
        let guesses = try await models.languageID.identify(clip)
        let decision = router.route(guesses, duration: clip.duration)
        guard case .split(let window) = decision else {
            return [Piece(range: clip.timeRange, decision: decision)]
        }

        var groups: [(range: TimeRange, guesses: [LanguageGuess])] = []
        for w in Router.windows(clip.timeRange, size: window) {
            let windowGuesses = try await models.languageID.identify(clip.slice(w))
            if let last = groups.last, last.guesses.top?.language == windowGuesses.top?.language {
                // Keep the least confident window's guesses: a group is only as sure as its weakest part.
                let weaker = (windowGuesses.top?.confidence ?? 0) < (last.guesses.top?.confidence ?? 0)
                groups[groups.count - 1] = (
                    TimeRange(start: last.range.start, end: w.end),
                    weaker ? windowGuesses : last.guesses
                )
            } else {
                groups.append((w, windowGuesses))
            }
        }
        return groups.map { group in
            Piece(range: group.range, decision: router.route(group.guesses, duration: group.range.duration, allowSplit: false))
        }
    }

    // MARK: - Recognition

    enum Outcome {
        case segment(Segment)
        case gap(Gap)
        case silent
    }

    func recognize(_ piece: Piece, in audio: AudioClip, index: Int) async throws -> Outcome {
        let model: ModelInfo
        let language: LanguageCode?
        switch piece.decision {
        case .specialist(let m, let l):
            model = m
            language = l
        case .fallback(let m, let hint):
            model = m
            language = hint
        case .unroutable(let reason):
            return .gap(Gap(range: piece.range, reason: reason))
        case .split:
            // `plan` never returns a split; treat it as a routing bug, not as speech.
            return .gap(Gap(range: piece.range, reason: "internal: unresolved split"))
        }
        guard let recognizer = models.recognizers.first(where: { $0.descriptor.model == model }) else {
            return .gap(Gap(range: piece.range, reason: "recognizer \(model.producer) not loaded"))
        }

        let result = try await recognizer.transcribe(audio.slice(piece.range), language: language)
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .silent }
        if let punctuation = models.punctuation {
            text = try await punctuation.restore(text, language: language ?? result.detectedLanguage)
        }

        return .segment(Segment(
            id: Self.segmentID(index),
            range: piece.range,
            language: language ?? result.detectedLanguage,
            text: text,
            words: result.words,
            confidence: result.confidence,
            producer: model.producer,
            uncertain: result.confidence < router.policy.recognitionConfidenceThreshold
        ))
    }

    /// "s_0042"
    static func segmentID(_ index: Int) -> String {
        let digits = String(index)
        return "s_" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

private final class EventEmitter {
    let meetingID: String
    let sink: (any EventSink)?
    var seq = 0

    init(meetingID: String, sink: (any EventSink)?) {
        self.meetingID = meetingID
        self.sink = sink
    }

    func emit(_ kind: MeetingEvent.Kind) async throws {
        let event = MeetingEvent(meeting: meetingID, seq: seq, kind: kind)
        seq += 1
        try await sink?.receive(event)
    }
}
