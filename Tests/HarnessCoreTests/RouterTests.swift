import XCTest
import HarnessCore

final class RouterTests: XCTestCase {
    let english = RecognizerDescriptor(model: ModelInfo(id: "asr-en", version: "1"), languages: [.english])
    let msa = RecognizerDescriptor(model: ModelInfo(id: "asr-ar-msa", version: "1"), languages: [.arabic], variant: "msa")
    let egyptian = RecognizerDescriptor(model: ModelInfo(id: "asr-ar-eg", version: "1"), languages: [.arabic], variant: "egyptian")
    let multilingual = RecognizerDescriptor(model: ModelInfo(id: "asr-multi", version: "1"), languages: [], isMultilingual: true)

    func router(_ installed: [RecognizerDescriptor]) -> Router {
        Router(policy: RouterPolicy(), installed: installed)
    }

    func testConfidentLanguageGoesToItsSpecialist() {
        let decision = router([english, egyptian, multilingual]).route([LanguageGuess(.english, 0.95)], duration: 3)
        XCTAssertEqual(decision, .specialist(english.model, language: .english))
    }

    func testArabicPrefersEgyptianVariantRegardlessOfOrder() {
        let decision = router([msa, egyptian]).route([LanguageGuess(.arabic, 0.9)], duration: 3)
        XCTAssertEqual(decision, .specialist(egyptian.model, language: .arabic))
    }

    func testArabicFallsBackToOtherVariantWhenPreferredIsMissing() {
        let decision = router([msa]).route([LanguageGuess(.arabic, 0.9)], duration: 3)
        XCTAssertEqual(decision, .specialist(msa.model, language: .arabic))
    }

    func testAmbiguousLongSegmentIsSplit() {
        let guesses = [LanguageGuess(.arabic, 0.62), LanguageGuess(.english, 0.35)]
        XCTAssertEqual(router([english, egyptian]).route(guesses, duration: 2.7), .split(window: 1.0))
    }

    func testAmbiguousShortSegmentGoesToFallbackWithoutHint() {
        let guesses = [LanguageGuess(.arabic, 0.6)]
        XCTAssertEqual(
            router([english, egyptian, multilingual]).route(guesses, duration: 1.5),
            .fallback(multilingual.model, languageHint: nil))
    }

    func testSplitCanBeDisallowed() {
        let guesses = [LanguageGuess(.arabic, 0.6)]
        XCTAssertEqual(
            router([egyptian, multilingual]).route(guesses, duration: 10, allowSplit: false),
            .fallback(multilingual.model, languageHint: nil))
    }

    func testLanguageWithoutSpecialistGoesToFallbackWithHint() {
        XCTAssertEqual(
            router([english, multilingual]).route([LanguageGuess(.german, 0.99)], duration: 3),
            .fallback(multilingual.model, languageHint: .german))
    }

    func testNothingSuitableIsUnroutable() {
        guard case .unroutable = router([english]).route([LanguageGuess(.german, 0.99)], duration: 3) else {
            return XCTFail("expected unroutable")
        }
    }

    func testWindowsFoldTrailingSliver() {
        let windows = Router.windows(TimeRange(start: 0, end: 2.3), size: 1)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.last?.end, 2.3)
    }
}
