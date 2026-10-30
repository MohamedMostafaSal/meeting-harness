import Foundation

/// A language code such as "en" or "ar". A struct rather than an enum so that
/// installing a new language pack never requires a code change.
public struct LanguageCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let english = LanguageCode("en")
    public static let arabic = LanguageCode("ar")
    public static let german = LanguageCode("de")
    public static let french = LanguageCode("fr")
}

/// A stable speaker identity from the speaker registry (D3), e.g. "S1".
public struct SpeakerID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// A span of meeting time, in seconds from the start of the recording.
public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        precondition(end >= start, "TimeRange end (\(end)) is before start (\(start))")
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
    public var midpoint: Double { (start + end) / 2 }
}

/// Which model produced a piece of output, recorded on every segment (provenance).
public struct ModelInfo: Hashable, Codable, Sendable {
    public var id: String
    public var version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }

    /// "asr-ar-eg-small@1.2"
    public var producer: String { "\(id)@\(version)" }
}

public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double

    public init(text: String, start: Double, end: Double, confidence: Double) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case text, start, end
        case confidence = "conf"
    }
}

/// One contiguous stretch of speech by one speaker in one language.
public struct Segment: Codable, Equatable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speaker: SpeakerID?
    public var speakerName: String?
    public var language: LanguageCode?
    public var text: String
    public var words: [Word]
    public var confidence: Double
    /// `ModelInfo.producer` of the speech-to-text model that wrote `text`.
    public var producer: String
    /// Set when two or more people spoke at once (M4).
    public var overlap: Bool
    /// Set by confidence gating (D8): shown to the user, but flagged.
    public var uncertain: Bool

    public init(
        id: String,
        range: TimeRange,
        speaker: SpeakerID? = nil,
        speakerName: String? = nil,
        language: LanguageCode?,
        text: String,
        words: [Word] = [],
        confidence: Double,
        producer: String,
        overlap: Bool = false,
        uncertain: Bool = false
    ) {
        self.id = id
        self.start = roundedToMillisecond(range.start)
        self.end = roundedToMillisecond(range.end)
        self.speaker = speaker
        self.speakerName = speakerName
        self.language = language
        self.text = text
        self.words = words
        self.confidence = confidence
        self.producer = producer
        self.overlap = overlap
        self.uncertain = uncertain
    }

    public var range: TimeRange { TimeRange(start: start, end: end) }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, speaker, text, words, producer, overlap, uncertain
        case speakerName = "speaker_name"
        case language = "lang"
        case confidence = "conf"
    }
}

/// Speech the harness detected but could not transcribe. Kept so that nothing
/// is ever dropped silently.
public struct Gap: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var reason: String

    public init(range: TimeRange, reason: String) {
        self.start = roundedToMillisecond(range.start)
        self.end = roundedToMillisecond(range.end)
        self.reason = reason
    }
}

/// Keeps stored times free of float noise like 15.100000000000001.
func roundedToMillisecond(_ seconds: Double) -> Double {
    (seconds * 1000).rounded() / 1000
}

/// The canonical transcript (D9). Every exporter renders from this.
public struct Transcript: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var meetingID: String
    public var segments: [Segment]
    public var gaps: [Gap]

    public init(meetingID: String, segments: [Segment] = [], gaps: [Gap] = []) {
        self.schemaVersion = Transcript.currentSchemaVersion
        self.meetingID = meetingID
        self.segments = segments
        self.gaps = gaps
    }

    private enum CodingKeys: String, CodingKey {
        case segments, gaps
        case schemaVersion = "schema_version"
        case meetingID = "meeting"
    }
}
