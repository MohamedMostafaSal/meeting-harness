import Foundation
import HarnessCore

/// Launch arguments for screenshots and demos:
/// `-demo` fills the library with sample meetings; `-screen <name>` opens a screen
/// (library, meeting, recording, settings, models, onboarding).
enum LaunchOptions {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var demo: Bool { arguments.contains("-demo") }
    static var screen: String? {
        guard let i = arguments.firstIndex(of: "-screen"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

/// Sample meetings with realistic Egyptian Arabic / English transcripts, so the
/// app can be shown without models or a microphone.
@MainActor
enum DemoData {
    static let standupID = "m_demo_standup"

    static func seed(_ store: MeetingStore) {
        guard store.meeting(standupID) == nil else { return }
        let now = Date()
        add(store, id: standupID, title: "Product standup", createdAt: now.addingTimeInterval(-3_600), duration: 754, segments: standup)
        add(store, id: "m_demo_review", title: "Design review with Sara", createdAt: now.addingTimeInterval(-26 * 3_600), duration: 1_912, segments: review)
        add(store, id: "m_demo_call", title: "Supplier call", createdAt: now.addingTimeInterval(-4 * 24 * 3_600), duration: 421, segments: call)
    }

    private typealias Line = (start: Double, end: Double, speaker: String, name: String?, lang: LanguageCode, text: String, conf: Double)

    private static let standup: [Line] = [
        (2.1, 7.8, "omar", "Omar", .english, "Morning everyone. Let's keep it short today, we have the release on Thursday.", 0.94),
        (8.4, 15.2, "S1", "Mona", .arabic, "تمام، أنا خلصت الـ onboarding screens امبارح وفاضل بس الـ dark mode.", 0.86),
        (15.9, 21.0, "S1", "Mona", .english, "I'll push it for review before lunch.", 0.91),
        (21.8, 30.4, "S2", nil, .arabic, "طيب والـ crash اللي كان بيحصل على الأيفون القديم؟ اتحل ولا لسه؟", 0.82),
        (31.0, 39.7, "omar", "Omar", .arabic, "اتحل، كانت مشكلة في الـ memory لما بنحمّل الموديلات كلها مرة واحدة.", 0.88),
        (40.2, 47.5, "omar", "Omar", .english, "Now we load one model at a time and it's stable on every device we tested.", 0.93),
        (48.1, 53.9, "S2", nil, .arabic, "حلو جداً. يبقى نقفل الـ sprint النهاردة.", 0.79),
        (54.3, 58.0, "S1", "Mona", .english, "Sounds good to me.", 0.66),
    ]

    private static let review: [Line] = [
        (1.0, 9.2, "sara", "Sara", .english, "I want the transcript to feel like a conversation, not a log file.", 0.95),
        (9.8, 17.1, "omar", "Omar", .arabic, "متفق. كل متكلم ليه لون، والجملة العربي تتقري من اليمين.", 0.87),
        (17.6, 24.0, "sara", "Sara", .english, "And tapping a line should play it. That's the moment people trust it.", 0.93),
    ]

    private static let call: [Line] = [
        (0.8, 8.5, "S1", nil, .arabic, "أهلاً يا فندم، الشحنة هتوصل يوم الحد إن شاء الله.", 0.84),
        (9.0, 13.4, "omar", "Omar", .english, "Great, can you send the invoice today?", 0.92),
    ]

    private static func add(_ store: MeetingStore, id: String, title: String, createdAt: Date, duration: TimeInterval, segments lines: [Line]) {
        let folder = store.folder(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("audio.wav")
        try? silentWAV(seconds: 2).write(to: audio)

        let segments = lines.enumerated().map { i, line in
            Segment(id: String(format: "s_%04d", i + 1), range: TimeRange(start: line.start, end: line.end),
                    speaker: SpeakerID(line.speaker), speakerName: line.name, language: line.lang, text: line.text,
                    confidence: line.conf, producer: line.lang == .arabic ? "whisper-small-eg@coreml" : "whisper-small.en@coreml",
                    uncertain: line.conf < 0.7)
        }
        let transcript = Transcript(meetingID: id, segments: segments)
        var report = PipelineReport()
        report.timings = ["speakers": 6.2, "languageID": 3.1, "transcription": 41.7]
        report.log = [
            "Speakers: 3 found in 9 turns, 0 overlapped; 8 utterances",
            "2.1–7.8s LID en 0.99 / ar 0.01 → whisper-small.en@coreml [en]",
            "8.4–21.0s LID ar 0.58 / en 0.42 → ambiguous, re-checking in 2.0 s windows",
            "  8.4–15.2s LID ar 0.93 / en 0.07 → whisper-small-eg@coreml [ar]",
            "  15.2–21.0s LID en 0.96 / ar 0.04 → whisper-small.en@coreml [en]",
        ]
        let meeting = Meeting(id: id, title: title, createdAt: createdAt, duration: duration, status: .ready, audioFile: "audio.wav")
        let events = segments.enumerated().map { MeetingEvent(meeting: id, seq: $0.offset + 1, kind: .segmentFinal($0.element)) }
        // Write meeting.json first so the store knows the meeting, then the outputs.
        store.update(meeting)
        try? MeetingStore.encoder.encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
        store.reload()
        try? store.save(transcript: transcript, events: events, report: report, voices: [:], for: meeting)
    }

    /// A short silent 16 kHz WAV so playback controls have something to load.
    static func silentWAV(seconds: Double) -> Data {
        let samples = Int(16_000 * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    /// Captions shown on the recording screen in demo mode.
    static let liveCaptions: [(lang: String, text: String)] = [
        ("en", "Okay, let's start with the numbers from last week."),
        ("ar", "الأرقام كانت أحسن من المتوقع، خصوصاً في الـ retention."),
        ("en", "That's great. What changed?"),
    ]
}
