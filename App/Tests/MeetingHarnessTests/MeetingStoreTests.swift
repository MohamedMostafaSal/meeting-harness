import HarnessCore
import XCTest
@testable import MeetingHarness

@MainActor
final class MeetingStoreTests: XCTestCase {
    func testSavesTranscriptOutputsAndAppliesRenames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(root: root)
        let audio = root.appendingPathComponent("in.m4a")
        try Data([0]).write(to: audio)
        let meeting = try store.add(audioAt: audio, duration: 12, move: true)

        let segment = Segment(id: "s_0001", range: TimeRange(start: 0, end: 3), speaker: SpeakerID("S1"), language: .arabic,
                              text: "خلينا نبدأ", confidence: 0.9, producer: "whisper-small@coreml")
        let transcript = Transcript(meetingID: meeting.id, segments: [segment])
        try store.save(transcript: transcript, events: [MeetingEvent(meeting: meeting.id, seq: 0, kind: .segmentFinal(segment))],
                       report: PipelineReport(), voices: [SpeakerID("S1"): SpeakerEmbedding([1, 0])], for: meeting)

        let saved = try XCTUnwrap(store.meeting(meeting.id))
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.languages, ["ar"])
        XCTAssertEqual(saved.speakers.map(\.id), ["S1"])
        XCTAssertEqual(store.voices(for: saved)["S1"], SpeakerEmbedding([1, 0]))

        store.renameSpeaker("S1", to: "Omar", in: saved)
        XCTAssertEqual(store.transcript(for: saved)?.segments.first?.speakerName, "Omar")
        let events = try String(contentsOf: store.folder(for: meeting.id).appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertTrue(events.contains("speaker.renamed"))
        XCTAssertEqual(store.meeting(meeting.id)?.speakers.first?.displayName, "Omar")
    }
}
