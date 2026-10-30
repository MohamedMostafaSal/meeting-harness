import Foundation
import HarnessCore

/// A meeting's metadata, saved as `meeting.json` next to its audio and transcript.
struct Meeting: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// Audio saved; waiting to be transcribed.
        case recorded
        case transcribing
        case ready
        /// Some model packs aren't downloaded yet.
        case needsModels
        case failed
    }

    var id: String
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var status: Status
    /// Languages heard, in order of first appearance ("en", "ar").
    var languages: [String] = []
    /// Speakers in order of first appearance, with the user's renames applied.
    var speakers: [SpeakerSummary] = []
    var preview: String = ""
    var failure: String?
    /// File name of the audio inside the meeting folder.
    var audioFile: String = "audio.m4a"

    struct SpeakerSummary: Codable, Hashable, Identifiable {
        var id: String
        var name: String?
        var seconds: Double

        var displayName: String { name ?? id }
    }

    static func newID(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "m_\(f.string(from: date))"
    }

    static func defaultTitle(for date: Date) -> String {
        "Meeting · " + date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

extension Transcript {
    /// Speakers in order of first appearance with their talk time.
    var speakerSummaries: [Meeting.SpeakerSummary] {
        var order: [String] = []
        var seconds: [String: Double] = [:]
        var names: [String: String] = [:]
        for s in segments {
            guard let id = s.speaker?.rawValue else { continue }
            if seconds[id] == nil { order.append(id) }
            seconds[id, default: 0] += s.end - s.start
            if let name = s.speakerName { names[id] = name }
        }
        return order.map { Meeting.SpeakerSummary(id: $0, name: names[$0], seconds: seconds[$0] ?? 0) }
    }

    var languagesInOrder: [String] {
        var out: [String] = []
        for case let l? in segments.map(\.language?.rawValue) where !out.contains(l) { out.append(l) }
        return out
    }
}
