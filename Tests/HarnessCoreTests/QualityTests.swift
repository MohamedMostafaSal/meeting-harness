import XCTest
@testable import HarnessCore

// Same cases as web/test/harness.test.js, so both ports behave alike.
final class QualityTests: XCTestCase {
    func testLoudnessRaisesQuietSpeechWithoutClipping() {
        var samples = [Float](repeating: 0, count: 32_000)
        for i in 0..<16_000 { samples[i] = 0.005 * sin(Float(i) / 5) }
        let quiet = AudioClip(samples: samples, sampleRate: 16_000)
        let before = Loudness.speechLevel(quiet.samples, sampleRate: 16_000).speechDB
        let (louder, gain, _) = Loudness.normalize(quiet)

        XCTAssertLessThan(before, -45)
        XCTAssertEqual(Loudness.speechLevel(louder.samples, sampleRate: 16_000).speechDB, -20, accuracy: 1)
        XCTAssertGreaterThan(gain, 20)
        XCTAssertLessThanOrEqual(gain, 30)
        XCTAssertLessThanOrEqual(louder.samples.map(abs).max() ?? 0, 0.98)

        let loud = AudioClip(samples: (0..<16_000).map { 0.99 * sin(Float($0) / 5) }, sampleRate: 16_000)
        XCTAssertLessThanOrEqual(Loudness.normalize(loud).clip.samples.map(abs).max() ?? 0, 0.98)
        XCTAssertEqual(Loudness.normalize(.silence(duration: 1, sampleRate: 16_000)).gainDB, 0)
    }

    func testHallucinationGuard() {
        XCTAssertEqual(HallucinationGuard.check("  ", duration: 2), .empty)
        XCTAssertEqual(HallucinationGuard.check("...", duration: 2), .empty)
        XCTAssertEqual(HallucinationGuard.check("Thank you for watching!", duration: 2), .suspicious("looks like a known Whisper hallucination"))
        XCTAssertEqual(HallucinationGuard.check("اشتركوا في القناة", duration: 2), .suspicious("looks like a known Whisper hallucination"))
        XCTAssertEqual(HallucinationGuard.check("the the the the the the the the the", duration: 5), .suspicious("repeats itself"))
        XCTAssertEqual(HallucinationGuard.check(String(repeating: "a", count: 100), duration: 1), .suspicious("too much text for the audio length"))
        XCTAssertEqual(HallucinationGuard.check("خلينا نبدأ بالـ quarterly review", duration: 3), .ok)
    }

    func testMergeJoinsSameSpeakerAndLanguageAcrossSmallGapsOnly() {
        func seg(_ start: Double, _ end: Double, _ lang: LanguageCode, _ text: String) -> Segment {
            Segment(id: "x", range: TimeRange(start: start, end: end), speaker: SpeakerID("S1"), language: lang,
                    text: text, confidence: 0.9, producer: "en")
        }
        let merged = SegmentMerger.merge([
            seg(0, 2, .english, "hello"), seg(2.3, 4, .english, "there"), seg(4.1, 5, .arabic, "أهلا"), seg(8, 9, .arabic, "ازيك"),
        ], policy: MergePolicy())
        XCTAssertEqual(merged.map(\.text), ["hello there", "أهلا", "ازيك"])
        XCTAssertEqual(merged.map(\.id), ["s_0001", "s_0002", "s_0003"])
    }

    func testUtterancesJoinTheSameKnownSpeakerOnly() {
        let a = SpeakerLabel(id: SpeakerID("S1")), b = SpeakerLabel(id: SpeakerID("S2"))
        func turn(_ s: Double, _ e: Double, _ speaker: Int?, overlap: Bool = false) -> DiarizedTurn {
            DiarizedTurn(range: TimeRange(start: s, end: e), speaker: speaker, overlap: overlap)
        }
        let out = Utterances.group(
            [turn(0, 2, 0), turn(2.5, 4, 0), turn(4.2, 5, 1), turn(5.1, 6, 0, overlap: true), turn(9, 10, 0), turn(10.5, 11, nil), turn(11.2, 12, nil)],
            labels: [0: a, 1: b], policy: UtterancePolicy())
        XCTAssertEqual(out.map { [$0.range.start, $0.range.end] }, [[0, 4], [4.2, 5], [5.1, 6], [9, 10], [10.5, 11], [11.2, 12]])
        XCTAssertEqual(out.map { $0.label?.id.rawValue }, ["S1", "S2", "S1", "S1", nil, nil])
        XCTAssertEqual(Utterances.group([turn(0, 70, 0)], labels: [0: a], policy: UtterancePolicy()).count, 3, "split to fit Whisper's window")
    }
}
