import XCTest
import HarnessCore

// Same cases as web/test/harness.test.js "liveStep".
final class LiveSentencesTests: XCTestCase {
    let rate = 16_000
    func speech(_ s: Double) -> [Float] { (0..<Int(s * 16_000)).map { 0.1 * sin(Float($0) / 7) } }
    func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16_000)) }

    func testWaitsDraftsCommitsAndSkips() {
        var live = LiveSentences()
        XCTAssertEqual(live.step(total: rate / 2, samples: speech(0.5)[...], start: 0), .wait)

        live = LiveSentences()
        let talking = speech(3)
        XCTAssertEqual(live.step(total: talking.count, samples: talking[...], start: 0), .draft(from: 0))

        let pause = speech(3) + silence(1)
        XCTAssertEqual(live.step(total: pause.count, samples: pause[...], start: 0), .commit(from: 0))
        XCTAssertEqual(live.sentenceStart, pause.count, "the next sentence starts after the pause")

        var quiet = LiveSentences()
        let nothing = silence(3)
        XCTAssertEqual(quiet.step(total: nothing.count, samples: nothing[...], start: 0), .skip)

        // A 20 s monologue is cut even without a pause.
        var monologue = LiveSentences()
        let long = speech(20)
        XCTAssertEqual(monologue.step(total: long.count, samples: long[...], start: 0), .commit(from: 0))
    }
}
