import Foundation

/// One entry in a meeting's append-only event stream: the connector contract (D16).
///
/// Recording mode emits these once the transcript is final; live mode emits the
/// same events as they happen. Consumers never need to know which mode produced them.
public struct MeetingEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case meetingStarted
        case segmentDraft(Segment)
        case segmentFinal(Segment)
        case segmentRevised(Segment)
        case speakerRenamed(SpeakerID, name: String)
        case meetingEnded
    }

    public var meeting: String
    /// Strictly increasing per meeting, starting at 0.
    public var seq: Int
    public var kind: Kind

    public init(meeting: String, seq: Int, kind: Kind) {
        self.meeting = meeting
        self.seq = seq
        self.kind = kind
    }

    /// The wire name, e.g. "segment.final".
    public var type: String {
        switch kind {
        case .meetingStarted: return "meeting.started"
        case .segmentDraft: return "segment.draft"
        case .segmentFinal: return "segment.final"
        case .segmentRevised: return "segment.revised"
        case .speakerRenamed: return "speaker.renamed"
        case .meetingEnded: return "meeting.ended"
        }
    }
}

extension MeetingEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case meeting, seq, type, segment, speaker, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meeting = try c.decode(String.self, forKey: .meeting)
        seq = try c.decode(Int.self, forKey: .seq)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "meeting.started": kind = .meetingStarted
        case "segment.draft": kind = .segmentDraft(try c.decode(Segment.self, forKey: .segment))
        case "segment.final": kind = .segmentFinal(try c.decode(Segment.self, forKey: .segment))
        case "segment.revised": kind = .segmentRevised(try c.decode(Segment.self, forKey: .segment))
        case "speaker.renamed":
            kind = .speakerRenamed(
                try c.decode(SpeakerID.self, forKey: .speaker),
                name: try c.decode(String.self, forKey: .name)
            )
        case "meeting.ended": kind = .meetingEnded
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown event type \"\(type)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(meeting, forKey: .meeting)
        try c.encode(seq, forKey: .seq)
        try c.encode(type, forKey: .type)
        switch kind {
        case .meetingStarted, .meetingEnded:
            break
        case .segmentDraft(let segment), .segmentFinal(let segment), .segmentRevised(let segment):
            try c.encode(segment, forKey: .segment)
        case .speakerRenamed(let speaker, let name):
            try c.encode(speaker, forKey: .speaker)
            try c.encode(name, forKey: .name)
        }
    }
}
