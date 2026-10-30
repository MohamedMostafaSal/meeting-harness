import HarnessCore
import XCTest
@testable import MeetingHarness

@MainActor
final class LiveCaptionerTests: XCTestCase {
    private let rate = LiveBuffer.sampleRate

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { 0.1 * sin(Float($0) * 0.05) }
    }

    func testDraftsWhileSpeakingThenCommitsInTheDetectedLanguage() async {
        let buffer = LiveBuffer(seconds: 30)
        let recognizer = FakeRecognizer { language in
            language == .arabic ? "خلينا نبدأ الاجتماع" : "let's get started"
        }
        let captioner = LiveCaptioner(
            buffer: buffer,
            languageID: FakeLanguageID(guesses: [LanguageGuess(.arabic, 0.9), LanguageGuess(.english, 0.1)]),
            recognizer: recognizer)

        buffer.append(tone(2.5))
        await captioner.step()
        XCTAssertNotNil(captioner.draft, "speech in progress shows a draft")
        XCTAssertTrue(captioner.lines.isEmpty)

        buffer.append([Float](repeating: 0, count: rate))
        await captioner.step()
        XCTAssertNil(captioner.draft)
        XCTAssertEqual(captioner.lines.map(\.text), ["خلينا نبدأ الاجتماع"])
        XCTAssertEqual(captioner.lines.first?.language, "ar")
        XCTAssertEqual(recognizer.calls.last, .arabic)
    }

    func testSilenceNeverReachesTheModel() async {
        let buffer = LiveBuffer(seconds: 30)
        let recognizer = FakeRecognizer { _ in "Thank you for watching!" }
        let captioner = LiveCaptioner(buffer: buffer, languageID: FakeLanguageID(guesses: []), recognizer: recognizer)

        buffer.append([Float](repeating: 0, count: 5 * rate))
        await captioner.step()
        XCTAssertTrue(recognizer.calls.isEmpty)
        XCTAssertTrue(captioner.lines.isEmpty)
    }
}

private struct FakeLanguageID: LanguageIdentifier {
    var guesses: [LanguageGuess]
    func identify(_ audio: AudioClip) async throws -> [LanguageGuess] { guesses }
}

private final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
    let descriptor = RecognizerDescriptor(model: HarnessCore.ModelInfo(id: "whisper-base", version: "test"), languages: [], isMultilingual: true)
    let text: (LanguageCode?) -> String
    private(set) var calls: [LanguageCode?] = []

    init(_ text: @escaping (LanguageCode?) -> String) { self.text = text }

    func transcribe(_ audio: AudioClip, language: LanguageCode?) async throws -> RecognitionResult {
        calls.append(language)
        return RecognitionResult(text: text(language), confidence: 0.9)
    }
}
