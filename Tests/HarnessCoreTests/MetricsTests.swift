import XCTest
import HarnessCore

final class MetricsTests: XCTestCase {
    func testEditDistance() {
        XCTAssertEqual(Metrics.editDistance(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(Metrics.editDistance([Int](), [1, 2]), 2)
    }

    func testWordErrorRate() {
        let wer = Metrics.wordErrorRate(reference: "Let's start the review.", hypothesis: "lets start review")
        // "let's"→"lets" (apostrophe stripped, same word) and one deletion.
        XCTAssertEqual(wer, ErrorRate(errors: 1, referenceLength: 4))
        XCTAssertEqual(wer.rate, 0.25)
    }

    func testArabicSpellingVariantsAreNotErrors() {
        // Hamza on alef, taa marbuta vs haa, diacritics, tatweel.
        let wer = Metrics.wordErrorRate(reference: "أحمد في الجامعة", hypothesis: "احمد فِي الجامعـه")
        XCTAssertEqual(wer.errors, 0)
    }

    func testArabicIndicDigitsMatchWesternDigits() {
        XCTAssertEqual(TextNormalizer().normalize("الساعة ٣ و٤٥"), TextNormalizer().normalize("الساعه 3 و45"))
    }

    func testMixedScriptCharacterErrorRate() {
        let cer = Metrics.characterErrorRate(reference: "هنعمل الـ meeting بكرة", hypothesis: "هنعمل ال meting بكره")
        // Tatweel and taa marbuta fold away; only the missing "e" counts.
        XCTAssertEqual(cer.errors, 1)
    }

    func testEmptyReference() {
        XCTAssertEqual(Metrics.wordErrorRate(reference: "", hypothesis: "").rate, 0)
        XCTAssertEqual(Metrics.wordErrorRate(reference: "", hypothesis: "hello").rate, 1)
    }
}
