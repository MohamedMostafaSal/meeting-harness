import XCTest
import HarnessCore
import HarnessTesting

final class PipelineTests: XCTestCase {
    func testCodeSwitchedSentenceIsSplitAndRoutedPerLanguage() async throws {
        let meeting = DemoMeeting()
        let transcript = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.map(\.text), ["let's get started", "sounds good", "خلينا نبدأ بالـ", "quarterly review"])
        XCTAssertEqual(transcript.segments.map(\.language), [.english, .english, .arabic, .english])
        XCTAssertEqual(transcript.segments.map(\.producer), [
            "asr-en-small@0.1", "asr-en-small@0.1", "asr-ar-eg-small@0.1", "asr-en-small@0.1",
        ])
        XCTAssertEqual(transcript.segments.map(\.id), ["s_0001", "s_0002", "s_0003", "s_0004"])

        // The Arabic part covers the first window; English covers the rest of the turn.
        XCTAssertEqual(transcript.segments[2].start, 12.4)
        XCTAssertEqual(transcript.segments[2].end, 13.4)
        XCTAssertEqual(transcript.segments[3].end, 15.1, "times are rounded to the millisecond")

        XCTAssertTrue(meeting.msa.calls.isEmpty, "Egyptian is preferred over MSA")
        XCTAssertTrue(meeting.multilingual.calls.isEmpty, "every part had a confident specialist")
        XCTAssertTrue(transcript.gaps.isEmpty)
    }

    func testEventsFollowTheConnectorContract() async throws {
        let meeting = DemoMeeting()
        let sink = InMemoryEventSink()
        _ = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1", sink: sink)

        XCTAssertEqual(sink.events.map(\.type), [
            "meeting.started", "segment.final", "segment.final", "segment.final", "segment.final", "meeting.ended",
        ])
        XCTAssertEqual(sink.events.map(\.seq), Array(0..<6))
        XCTAssertTrue(sink.events.allSatisfy { $0.meeting == "m1" })
    }

    func testSilenceNeverReachesSpeechToText() async throws {
        var meeting = DemoMeeting()
        meeting.speechRegions = []
        let transcript = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1")

        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertTrue(meeting.english.calls.isEmpty)
        XCTAssertTrue(meeting.egyptian.calls.isEmpty)
    }

    func testLowConfidenceIsKeptButMarkedUncertain() async throws {
        let meeting = DemoMeeting()
        meeting.english.script = { _, _ in RecognitionResult(text: "mumbled", confidence: 0.3) }
        let transcript = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.first?.text, "mumbled")
        XCTAssertEqual(transcript.segments.first?.uncertain, true)
        XCTAssertEqual(transcript.segments[2].uncertain, false, "the Egyptian specialist was confident")
    }

    func testSpeakersAreClusteredAndEnrolledVoiceIsNamed() async throws {
        let meeting = DemoMeeting()
        let transcript = try await Pipeline(models: meeting.models, registry: meeting.registry)
            .transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.map(\.speaker), [SpeakerID("sara"), SpeakerID("S1"), SpeakerID("sara"), SpeakerID("sara")])
        XCTAssertEqual(transcript.segments.map(\.speakerName), ["Sara", nil, "Sara", "Sara"])
        // One fingerprint per turn, not per language piece.
        XCTAssertEqual(meeting.embedder.calls.count, 3)
    }

    func testWithoutEnrollmentSpeakersAreNumberedInOrderOfAppearance() async throws {
        let meeting = DemoMeeting()
        let transcript = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.map(\.speaker), [SpeakerID("S1"), SpeakerID("S2"), SpeakerID("S1"), SpeakerID("S1")])
    }

    func testOverlappedTurnIsFlaggedAndDoesNotCreateASpeaker() async throws {
        var meeting = DemoMeeting()
        // The guest's turn overlaps someone else; its fingerprint matches nobody well.
        meeting.overlapRegions = [TimeRange(start: 4.0, end: 4.5)]
        let transcript = try await Pipeline(models: meeting.models, registry: meeting.registry)
            .transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.map(\.overlap), [false, true, false, false])
        XCTAssertNil(transcript.segments[1].speaker, "an overlapped turn must not invent a new speaker")
        XCTAssertEqual(transcript.segments[0].speaker, SpeakerID("sara"))
    }

    func testWithoutSpeakerModelsSegmentsHaveNoSpeaker() async throws {
        var meeting = DemoMeeting()
        meeting.useSpeakerModels = false
        let transcript = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.count, 3, "without turns, the opening is one segment")
        XCTAssertTrue(transcript.segments.allSatisfy { $0.speaker == nil })
    }

    func testUnroutableSpeechBecomesAGapNotSilence() async throws {
        let english = ScriptedRecognizer(
            RecognizerDescriptor(model: ModelInfo(id: "asr-en", version: "1"), languages: [.english])
        ) { _, _ in RecognitionResult(text: "unused", confidence: 1) }
        let models = PipelineModels(
            diarizer: VADOnlyDiarizer(vad: ScriptedVAD(regions: [TimeRange(start: 1, end: 3)])),
            languageID: ScriptedLanguageID { _ in [LanguageGuess(.german, 0.99)] },
            recognizers: [english])
        let transcript = try await Pipeline(models: models).transcribe(.silence(duration: 5, sampleRate: 1_000), meetingID: "m1")

        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertEqual(transcript.gaps.count, 1)
        XCTAssertEqual(transcript.gaps.first?.start, 1)
        XCTAssertTrue(english.calls.isEmpty)
    }

    func testTranscriptionRunsOneModelAtATime() async throws {
        let meeting = DemoMeeting()
        let log = ModelLog()
        for recognizer in [meeting.english, meeting.egyptian, meeting.msa, meeting.multilingual] { recognizer.log = log }
        _ = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1")

        // All English pieces, then free it, then all Arabic pieces: never two models interleaved.
        XCTAssertEqual(log.entries, [
            "transcribe asr-en-small", "transcribe asr-en-small", "transcribe asr-en-small", "unload asr-en-small",
            "transcribe asr-ar-eg-small", "unload asr-ar-eg-small",
        ])
    }

    func testDiarizerCentroidsAreNamedAndItsModelFreed() async throws {
        // A SpeakerKit-style diarizer: its own speaker numbers (not in order of appearance) and one centroid each.
        let meeting = DemoMeeting()
        let diarizer = ScriptedDiarizer(Diarization(
            turns: [
                DiarizedTurn(range: DemoMeeting.saraOpens, speaker: 7),
                DiarizedTurn(range: DemoMeeting.guestAnswers, speaker: 3),
                DiarizedTurn(range: DemoMeeting.codeSwitch, speaker: 7),
            ],
            centroids: [7: SpeakerEmbedding([0.9, 0.2, 0]), 3: SpeakerEmbedding([0, 1, 0.1])]))
        var models = meeting.models
        models.diarizer = diarizer
        let pipeline = Pipeline(models: models, registry: meeting.registry)
        let transcript = try await pipeline.transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.map(\.speakerName), ["Sara", nil, "Sara", "Sara"])
        XCTAssertEqual(transcript.segments[1].speaker, SpeakerID("S1"))
        XCTAssertEqual(diarizer.unloads, 1)
        // The guest's voice is kept so the user can name it and have it recognized next time.
        XCTAssertEqual(pipeline.speakerVoices[SpeakerID("S1")], SpeakerEmbedding([0, 1, 0.1]))
    }

    func testSameSpeakerTurnsAreTranscribedTogether() async throws {
        let meeting = DemoMeeting()
        // Sara speaks twice with a 1 s pause: one utterance, one call to speech-to-text.
        let diarizer = ScriptedDiarizer(Diarization(
            turns: [
                DiarizedTurn(range: TimeRange(start: 2.0, end: 3.0), speaker: 0),
                DiarizedTurn(range: TimeRange(start: 4.0, end: 5.5), speaker: 0),
            ],
            centroids: [0: DemoMeeting.saraVoice]))
        var models = meeting.models
        models.diarizer = diarizer
        let transcript = try await Pipeline(models: models).transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(meeting.english.calls.count, 1)
        XCTAssertEqual(transcript.segments.first?.start, 2.0)
        XCTAssertEqual(transcript.segments.first?.end, 5.5)
    }

    func testHallucinatedTextIsFlaggedAndEmptyTextDropped() async throws {
        let meeting = DemoMeeting()
        meeting.english.script = { _, _ in RecognitionResult(text: "Thank you for watching!", confidence: 0.95) }
        meeting.egyptian.script = { _, _ in RecognitionResult(text: " ... ", confidence: 0.95) }
        let pipeline = Pipeline(models: meeting.models)
        let transcript = try await pipeline.transcribe(meeting.audio, meetingID: "m1")

        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.uncertain && $0.language == .english })
        XCTAssertTrue(pipeline.report.log.contains { $0.contains("hallucination") })
    }

    func testReportRecordsRoutingAndTimings() async throws {
        let meeting = DemoMeeting()
        let pipeline = Pipeline(models: meeting.models)
        var stages: [PipelineProgress.Stage] = []
        _ = try await pipeline.transcribe(meeting.audio, meetingID: "m1") { stages.append($0.stage) }

        XCTAssertTrue(pipeline.report.log.contains { $0.contains("ambiguous") })
        XCTAssertNotNil(pipeline.report.timings["transcription"])
        XCTAssertEqual(stages.first, .speakers)
        XCTAssertEqual(stages.last, .transcription)
    }
}

