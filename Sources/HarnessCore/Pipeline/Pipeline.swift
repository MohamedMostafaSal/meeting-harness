import Foundation

/// The AI pillars a pipeline runs with. Each is only a contract; see `Pillars/`.
public struct PipelineModels {
    /// Speech, speaker turns and voice fingerprints (M1–M4).
    public var diarizer: any Diarizer
    public var languageID: any LanguageIdentifier
    public var recognizers: [any SpeechRecognizer]
    public var punctuation: (any PunctuationRestorer)?

    public init(
        diarizer: any Diarizer,
        languageID: any LanguageIdentifier,
        recognizers: [any SpeechRecognizer],
        punctuation: (any PunctuationRestorer)? = nil
    ) {
        self.diarizer = diarizer
        self.languageID = languageID
        self.recognizers = recognizers
        self.punctuation = punctuation
    }
}

/// Where a run is, for progress UI.
public struct PipelineProgress: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case speakers, languages, transcription
    }

    public var stage: Stage
    public var completed: Int
    public var total: Int

    public init(stage: Stage, completed: Int = 0, total: Int = 0) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }
}

/// How a transcript was made: every routing decision and the time each pillar took.
public struct PipelineReport: Codable, Equatable, Sendable {
    public var log: [String] = []
    /// Seconds per pillar: "speakers", "languageID", "transcription".
    public var timings: [String: Double] = [:]
    /// Gain applied by loudness normalization, in dB.
    public var gainDB: Double = 0

    public init() {}
}

/// Recording-mode pipeline (v1), in the order the web prototype's real-model runs settled on:
///
/// 1. normalize loudness (D1)
/// 2. diarize: who spoke when, one fingerprint per speaker (M1–M4); then free that model
/// 3. name speakers against enrolled voices (D3)
/// 4. group each speaker's turns into utterances
/// 5. identify each utterance's language and route it, splitting mixed ones (M6, D5); free the model
/// 6. transcribe grouped by model, freeing each before the next loads (M7)
/// 7. gate, merge and emit events (D8, D6, D16)
public final class Pipeline {
    public let models: PipelineModels
    public let policy: PipelinePolicy
    public let router: Router
    public var registry: SpeakerRegistry
    public private(set) var report = PipelineReport()
    /// Each named speaker's voice fingerprint from the last run, so a user can say
    /// "this is me" about a speaker and have the voice recognized next time.
    public private(set) var speakerVoices: [SpeakerID: SpeakerEmbedding] = [:]

    public init(models: PipelineModels, policy: PipelinePolicy = PipelinePolicy(), registry: SpeakerRegistry = SpeakerRegistry()) {
        self.models = models
        self.policy = policy
        self.router = Router(policy: policy.router, installed: models.recognizers.map { $0.descriptor })
        self.registry = registry
    }

    /// Transcribes a whole recording and emits one `segment.final` per segment.
    public func transcribe(
        _ input: AudioClip,
        meetingID: String,
        sink: (any EventSink)? = nil,
        progress: ((PipelineProgress) -> Void)? = nil
    ) async throws -> Transcript {
        report = PipelineReport()
        var audio = input
        if policy.normalizeLoudness {
            let normalized = Loudness.normalize(input)
            audio = normalized.clip
            report.gainDB = normalized.gainDB
        }

        // 2–4. Who spoke.
        progress?(PipelineProgress(stage: .speakers))
        let diarization = try await timed("speakers") { try await models.diarizer.diarize(audio) }
        await Self.unload(models.diarizer)
        let turns = diarization.turns.sorted { $0.range.start < $1.range.start }
        var order: [Int] = []
        for case let speaker? in turns.map(\.speaker) where !order.contains(speaker) { order.append(speaker) }
        let labels = SpeakerAssignment.name(centroids: diarization.centroids, speakers: order, registry: registry, policy: policy.speakers)
        speakerVoices = [:]
        for (speaker, label) in labels {
            if let centroid = diarization.centroids[speaker] { speakerVoices[label.id] = centroid }
        }
        let utterances = Utterances.group(turns, labels: labels, policy: policy.utterances)
        report.log.append("Speakers: \(order.count) found in \(turns.count) turns, \(turns.filter(\.overlap).count) overlapped; \(utterances.count) utterances")

        // 5. Which language, which model.
        var pieces: [Piece] = []
        for (u, utterance) in utterances.enumerated() {
            progress?(PipelineProgress(stage: .languages, completed: u, total: utterances.count))
            pieces += try await plan(utterance, index: u, in: audio)
        }
        await Self.unload(models.languageID)

        // 6. What was said, one model at a time.
        var transcriptGaps: [Gap] = []
        var results: [Int: RecognitionResult] = [:]
        var modelOrder: [ModelInfo] = []
        var piecesByModel: [ModelInfo: [Int]] = [:]
        for (i, piece) in pieces.enumerated() {
            guard let model = piece.model else { continue }
            if piecesByModel[model] == nil { modelOrder.append(model) }
            piecesByModel[model, default: []].append(i)
        }
        let routable = piecesByModel.values.reduce(0) { $0 + $1.count }
        var done = 0
        for model in modelOrder {
            let indexes = piecesByModel[model] ?? []
            guard let recognizer = models.recognizers.first(where: { $0.descriptor.model == model }) else {
                transcriptGaps += indexes.map { Gap(range: pieces[$0].range, reason: "recognizer \(model.producer) not loaded") }
                continue
            }
            for i in indexes {
                progress?(PipelineProgress(stage: .transcription, completed: done, total: routable))
                results[i] = try await timed("transcription") {
                    try await recognizer.transcribe(audio.slice(pieces[i].range), language: pieces[i].language)
                }
                done += 1
            }
            await Self.unload(recognizer)
        }

        // 7. Assemble.
        var segments: [Segment] = []
        for (i, piece) in pieces.enumerated() {
            switch piece.decision {
            case .unroutable(let reason):
                transcriptGaps.append(Gap(range: piece.range, reason: reason))
                continue
            case .split:
                transcriptGaps.append(Gap(range: piece.range, reason: "internal: unresolved split"))
                continue
            case .specialist, .fallback:
                break
            }
            guard let result = results[i] else { continue }
            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let verdict = HallucinationGuard.check(text, duration: piece.range.duration)
            if verdict == .empty { continue }
            if case .suspicious(let reason) = verdict { report.log.append("  \(Self.span(piece.range)) flagged: \(reason)") }
            let language = piece.language ?? result.detectedLanguage
            if let punctuation = models.punctuation {
                text = try await punctuation.restore(text, language: language)
            }
            let utterance = utterances[piece.utterance]
            segments.append(Segment(
                id: Self.segmentID(segments.count + 1),
                range: piece.range,
                speaker: utterance.label?.id,
                speakerName: utterance.label?.name,
                language: language,
                text: text,
                words: result.words,
                confidence: result.confidence,
                producer: piece.model?.producer ?? "",
                overlap: utterance.overlap,
                uncertain: result.confidence < policy.router.recognitionConfidenceThreshold || verdict != .ok
            ))
        }

        let transcript = Transcript(
            meetingID: meetingID,
            segments: SegmentMerger.merge(segments, policy: policy.merge),
            gaps: transcriptGaps.sorted { $0.start < $1.start })

        let events = EventEmitter(meetingID: meetingID, sink: sink)
        try await events.emit(.meetingStarted)
        for segment in transcript.segments {
            try await events.emit(.segmentFinal(segment))
        }
        try await events.emit(.meetingEnded)
        return transcript
    }

    // MARK: - Planning

    struct Piece {
        var utterance: Int
        var range: TimeRange
        var decision: RouteDecision
        var guesses: [LanguageGuess]

        var model: ModelInfo? {
            switch decision {
            case .specialist(let m, _), .fallback(let m, _): return m
            case .split, .unroutable: return nil
            }
        }

        /// The language to force on the recognizer; nil lets it decide.
        var language: LanguageCode? {
            switch decision {
            case .specialist(_, let l): return l
            case .fallback(_, let hint): return hint
            case .split, .unroutable: return nil
            }
        }
    }

    /// Routes one utterance. If its language is ambiguous, re-identifies it in short
    /// windows and joins neighbouring windows that agree (code-switching).
    func plan(_ utterance: Utterance, index: Int, in audio: AudioClip) async throws -> [Piece] {
        let guesses = try await identify(utterance.range, in: audio)
        let decision = router.route(guesses, duration: utterance.range.duration)
        guard case .split(let window) = decision else {
            report.log.append("\(Self.span(utterance.range)) LID \(Self.describe(guesses)) → \(describe(decision))")
            return [Piece(utterance: index, range: utterance.range, decision: decision, guesses: guesses)]
        }
        report.log.append("\(Self.span(utterance.range)) LID \(Self.describe(guesses)) → ambiguous, re-checking in \(window) s windows")

        var groups: [(range: TimeRange, guesses: [LanguageGuess])] = []
        for w in Router.windows(utterance.range, size: window) {
            let windowGuesses = try await identify(w, in: audio)
            if let last = groups.last, last.guesses.top?.language == windowGuesses.top?.language {
                // A group is only as sure as its weakest window.
                let weaker = (windowGuesses.top?.confidence ?? 0) < (last.guesses.top?.confidence ?? 0)
                groups[groups.count - 1] = (TimeRange(start: last.range.start, end: w.end), weaker ? windowGuesses : last.guesses)
            } else {
                groups.append((w, windowGuesses))
            }
        }
        return groups.map { group in
            let d = router.route(group.guesses, duration: group.range.duration, allowSplit: false)
            report.log.append("  \(Self.span(group.range)) LID \(Self.describe(group.guesses)) → \(describe(d))")
            return Piece(utterance: index, range: group.range, decision: d, guesses: group.guesses)
        }
    }

    private func identify(_ range: TimeRange, in audio: AudioClip) async throws -> [LanguageGuess] {
        try await timed("languageID") { try await models.languageID.identify(audio.slice(range)) }
    }

    func describe(_ decision: RouteDecision) -> String {
        switch decision {
        case .specialist(let m, let l): return "\(m.producer) [\(l)]"
        case .fallback(let m, let hint): return "\(m.producer) [\(hint?.rawValue ?? "auto")] (fallback)"
        case .split(let w): return "split \(w) s"
        case .unroutable(let reason): return "not transcribed (\(reason))"
        }
    }

    static func describe(_ guesses: [LanguageGuess]) -> String {
        guesses.sorted { $0.confidence > $1.confidence }.prefix(2)
            .map { "\($0.language) \(String(format: "%.2f", $0.confidence))" }
            .joined(separator: " / ")
    }

    static func span(_ r: TimeRange) -> String {
        String(format: "%.1f–%.1fs", r.start, r.end)
    }

    // MARK: - Helpers

    private func timed<T>(_ pillar: String, _ work: () async throws -> T) async rethrows -> T {
        let start = Date()
        defer { report.timings[pillar, default: 0] += Date().timeIntervalSince(start) }
        return try await work()
    }

    static func unload(_ model: Any) async {
        if let model = model as? ModelLifecycle { await model.unload() }
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
