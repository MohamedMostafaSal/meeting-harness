import XCTest
import HarnessCore

final class SchemaTests: XCTestCase {
    let segment = Segment(
        id: "s_0042",
        range: TimeRange(start: 12.4, end: 13.9),
        speaker: SpeakerID("S2"),
        speakerName: "Sara",
        language: .arabic,
        text: "خلينا نبدأ",
        confidence: 0.94,
        producer: "asr-ar-eg-small@0.1")

    func testSegmentUsesWireKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(segment), as: UTF8.self)
        XCTAssertTrue(json.contains(#""lang":"ar""#))
        XCTAssertTrue(json.contains(#""conf":0.94"#))
        XCTAssertTrue(json.contains(#""speaker":"S2""#))
        XCTAssertTrue(json.contains(#""speaker_name":"Sara""#))
        XCTAssertTrue(json.contains("خلينا نبدأ"))
    }

    func testEventsRoundTrip() throws {
        let events: [MeetingEvent] = [
            MeetingEvent(meeting: "m1", seq: 0, kind: .meetingStarted),
            MeetingEvent(meeting: "m1", seq: 1, kind: .segmentDraft(segment)),
            MeetingEvent(meeting: "m1", seq: 2, kind: .segmentFinal(segment)),
            MeetingEvent(meeting: "m1", seq: 3, kind: .segmentRevised(segment)),
            MeetingEvent(meeting: "m1", seq: 4, kind: .speakerRenamed(SpeakerID("S2"), name: "Sara")),
            MeetingEvent(meeting: "m1", seq: 5, kind: .meetingEnded),
        ]
        for event in events {
            let decoded = try JSONDecoder().decode(MeetingEvent.self, from: JSONEncoder().encode(event))
            XCTAssertEqual(decoded, event)
        }
    }

    func testJSONLineKeepsArabicReadable() throws {
        let line = try EventEncoding.jsonLine(MeetingEvent(meeting: "m1", seq: 2, kind: .segmentFinal(segment)))
        XCTAssertTrue(line.contains("\"type\":\"segment.final\""))
        XCTAssertTrue(line.contains("خلينا نبدأ"))
        XCTAssertFalse(line.contains("\n"))
    }

    func testUnknownEventTypeIsRejected() {
        let json = Data(#"{"meeting":"m1","seq":0,"type":"segment.exploded"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingEvent.self, from: json))
    }

    func testMarkdownExport() {
        let transcript = Transcript(
            meetingID: "m1",
            segments: [segment],
            gaps: [Gap(range: TimeRange(start: 3700, end: 3702), reason: "language uncertain")])
        let markdown = MarkdownExporter.render(transcript)
        XCTAssertTrue(markdown.contains("**Sara** `00:12 · ar`"))
        XCTAssertTrue(markdown.contains("خلينا نبدأ"))
        XCTAssertTrue(markdown.contains("`1:01:40–1:01:42`: language uncertain"))
    }
}
