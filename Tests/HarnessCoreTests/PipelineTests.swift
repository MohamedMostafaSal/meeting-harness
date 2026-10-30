import XCTest
import HarnessCore
import HarnessTesting

final class PipelineTests: XCTestCase {
    func testCodeSwitchedSentenceIsSplitAndRoutedPerLanguage() async throws {
        let meeting = DemoMeeting()
        let transcript = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1")

        XCTAssertEqual(transcript.segments.map(\.text), ["let's get started", "خلينا نبدأ بالـ", "quarterly review"])
        XCTAssertEqual(transcript.segments.map(\.language), [.english, .arabic, .english])
        XCTAssertEqual(transcript.segments.map(\.producer), ["asr-en-small@0.1", "asr-ar-eg-small@0.1", "asr-en-small@0.1"])
        XCTAssertEqual(transcript.segments.map(\.id), ["s_0001", "s_0002", "s_0003"])

        // The Arabic part covers the first window; English covers the rest of the region.
        XCTAssertEqual(transcript.segments[1].start, 12.4, accuracy: 0.01)
        XCTAssertEqual(transcript.segments[1].end, 13.4, accuracy: 0.01)
        XCTAssertEqual(transcript.segments[2].end, 15.1, accuracy: 0.01)

        XCTAssertTrue(meeting.msa.calls.isEmpty, "Egyptian is preferred over MSA")
        XCTAssertTrue(meeting.multilingual.calls.isEmpty, "every part had a confident specialist")
        XCTAssertTrue(transcript.gaps.isEmpty)
    }

    func testEventsFollowTheConnectorContract() async throws {
        let meeting = DemoMeeting()
        let sink = InMemoryEventSink()
        _ = try await Pipeline(models: meeting.models).transcribe(meeting.audio, meetingID: "m1", sink: sink)

        XCTAssertEqual(sink.events.map(\.type), [
            "meeting.started", "segment.final", "segment.final", "segment.final", "meeting.ended",
        ])
        XCTAssertEqual(sink.events.map(\.seq), Array(0..<5))
        XCTAssertTrue(sink.events.allSatisfy { $0.meeting == "m1" })
    }

    func testSilenceNeverReachesSpeechToText() async throws {
        let meeting = DemoMeeting()
        var models = meeting.models
        models.vad = ScriptedVAD(regions: [])
        let transcript = try await Pipeline(models: models).transcribe(meeting.audio, meetingID: "m1")

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
        XCTAssertEqual(transcript.segments[1].uncertain, false)
    }

    func testUnroutableSpeechBecomesAGapNotSilence() async throws {
        let english = ScriptedRecognizer(
            RecognizerDescriptor(model: ModelInfo(id: "asr-en", version: "1"), languages: [.english])
        ) { _, _ in RecognitionResult(text: "unused", confidence: 1) }
        let models = PipelineModels(
            vad: ScriptedVAD(regions: [TimeRange(start: 1, end: 3)]),
            languageID: ScriptedLanguageID { _ in [LanguageGuess(.german, 0.99)] },
            recognizers: [english])
        let transcript = try await Pipeline(models: models).transcribe(.silence(duration: 5, sampleRate: 1_000), meetingID: "m1")

        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertEqual(transcript.gaps.count, 1)
        XCTAssertEqual(transcript.gaps.first?.start, 1)
        XCTAssertTrue(english.calls.isEmpty)
    }
}
