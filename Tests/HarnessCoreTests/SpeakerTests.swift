import XCTest
import HarnessCore

final class SpeakerTests: XCTestCase {
    let policy = SpeakerPolicy()
    let voiceA = SpeakerEmbedding([1, 0, 0])
    let voiceANoisy = SpeakerEmbedding([0.95, 0.1, 0.05])
    let voiceB = SpeakerEmbedding([0, 1, 0])
    let voiceBNoisy = SpeakerEmbedding([0.1, 0.95, 0])

    func testSimilarity() {
        XCTAssertEqual(SpeakerEmbedding([1, 0]).similarity(to: SpeakerEmbedding([3, 0])), 1, accuracy: 1e-9)
        XCTAssertEqual(SpeakerEmbedding([1, 0]).similarity(to: SpeakerEmbedding([0, 2])), 0, accuracy: 1e-9)
        XCTAssertEqual(SpeakerEmbedding([0, 0]).similarity(to: SpeakerEmbedding([1, 0])), 0)
        XCTAssertEqual(SpeakerEmbedding([1, 0]).similarity(to: SpeakerEmbedding([1, 0, 0])), 0, "different models")
    }

    func testClusteringGroupsSimilarVoicesInOrderOfAppearance() {
        let clusters = SpeakerClustering.agglomerate([voiceB, voiceA, voiceBNoisy, voiceANoisy], threshold: 0.7)
        XCTAssertEqual(clusters, [0, 1, 0, 1])
    }

    func testClusteringThresholdDecidesWhatCountsAsOneVoice() {
        // cos(53°) ≈ 0.6
        let near = SpeakerEmbedding([0.6, 0.8, 0])
        XCTAssertEqual(SpeakerClustering.agglomerate([voiceA, near], threshold: 0.7), [0, 1])
        XCTAssertEqual(SpeakerClustering.agglomerate([voiceA, near], threshold: 0.5), [0, 0])
        XCTAssertEqual(SpeakerClustering.agglomerate([], threshold: 0.7), [])
    }

    func testUnknownVoicesAreNumberedInOrderOfAppearance() {
        let labels = SpeakerAssignment.assign(
            [voiceB, voiceA, voiceBNoisy], reliable: [true, true, true], registry: SpeakerRegistry(), policy: policy)
        XCTAssertEqual(labels.map { $0?.id }, [SpeakerID("S1"), SpeakerID("S2"), SpeakerID("S1")])
    }

    func testEnrolledVoiceIsMatchedOneToOne() {
        // Two different voices (similarity ≈ 0.63) that both resemble the enrolled one.
        // Only the closer one may take the name.
        let closer = SpeakerEmbedding([0.819152, 0.573576, 0])  // 35° from enrolled
        let further = SpeakerEmbedding([0.766044, 0, 0.642788]) // 40° from enrolled
        var registry = SpeakerRegistry()
        registry.enroll(SpeakerID("sara"), name: "Sara", embedding: voiceA)

        let labels = SpeakerAssignment.assign([further, closer], reliable: [true, true], registry: registry, policy: policy)
        XCTAssertEqual(labels, [SpeakerLabel(id: SpeakerID("S1")), SpeakerLabel(id: SpeakerID("sara"), name: "Sara")])
    }

    func testTooShortTurnGetsNoLabel() {
        let labels = SpeakerAssignment.assign([voiceA, nil, voiceANoisy], reliable: [true, true, true], registry: SpeakerRegistry(), policy: policy)
        XCTAssertEqual(labels.map { $0?.id }, [SpeakerID("S1"), nil, SpeakerID("S1")])
    }

    func testOverlappedTurnJoinsClosestClusterButNeverCreatesOne() {
        let joined = SpeakerAssignment.assign(
            [voiceA, voiceB, voiceANoisy], reliable: [true, true, false], registry: SpeakerRegistry(), policy: policy)
        XCTAssertEqual(joined.map { $0?.id }, [SpeakerID("S1"), SpeakerID("S2"), SpeakerID("S1")])

        let alone = SpeakerAssignment.assign([voiceA, voiceB], reliable: [true, false], registry: SpeakerRegistry(), policy: policy)
        XCTAssertEqual(alone.map { $0?.id }, [SpeakerID("S1"), nil])
    }

    func testGeneratedIDsSkipEnrolledIDs() {
        var registry = SpeakerRegistry()
        registry.enroll(SpeakerID("S1"), name: "Owner", embedding: voiceB)
        let labels = SpeakerAssignment.assign([voiceA], reliable: [true], registry: registry, policy: policy)
        XCTAssertEqual(labels.first??.id, SpeakerID("S2"))
    }

    func testReEnrollingReplacesTheVoice() {
        var registry = SpeakerRegistry()
        registry.enroll(SpeakerID("sara"), name: "Sara", embedding: voiceA)
        registry.enroll(SpeakerID("sara"), name: "Sara M.", embedding: voiceB)
        XCTAssertEqual(registry.enrolled.count, 1)
        XCTAssertEqual(registry.enrolled.first?.name, "Sara M.")
    }

    func testRenameSpeaker() {
        let s1 = Segment(id: "s_0001", range: TimeRange(start: 0, end: 1), speaker: SpeakerID("S1"), language: .english,
                         text: "hi", confidence: 1, producer: "x@1")
        let s2 = Segment(id: "s_0002", range: TimeRange(start: 1, end: 2), speaker: SpeakerID("S2"), language: .english,
                         text: "hello", confidence: 1, producer: "x@1")
        var transcript = Transcript(meetingID: "m1", segments: [s1, s2])
        transcript.renameSpeaker(SpeakerID("S1"), to: "Omar")
        XCTAssertEqual(transcript.segments.map(\.speakerName), ["Omar", nil])
    }
}
