import Foundation

/// Anything that consumes the meeting event stream: a file, a local-network
/// server for Claude, a test.
public protocol EventSink: AnyObject {
    func receive(_ event: MeetingEvent) async throws
}

public final class InMemoryEventSink: EventSink {
    public private(set) var events: [MeetingEvent] = []

    public init() {}

    public func receive(_ event: MeetingEvent) async throws {
        events.append(event)
    }
}

public enum EventEncoding {
    /// One event as a single JSON line (JSON Lines), keys sorted for stable diffs.
    public static func jsonLine(_ event: MeetingEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    public static func jsonLines(_ events: [MeetingEvent]) throws -> String {
        try events.map(jsonLine).joined(separator: "\n") + "\n"
    }
}

/// Renders a transcript as Markdown, one paragraph per segment so that mixed
/// Arabic/English lines get their own text direction.
public enum MarkdownExporter {
    public static func render(_ transcript: Transcript) -> String {
        var lines = ["# Meeting \(transcript.meetingID)", ""]
        for segment in transcript.segments {
            let who = segment.speakerName ?? segment.speaker?.rawValue ?? "Speaker"
            let lang = segment.language.map { " · \($0)" } ?? ""
            let flag = segment.uncertain ? " _(uncertain)_" : ""
            lines.append("**\(who)** `\(timestamp(segment.start))\(lang)`  ")
            lines.append(segment.text + flag)
            lines.append("")
        }
        if !transcript.gaps.isEmpty {
            lines.append("---")
            lines.append("")
            for gap in transcript.gaps {
                lines.append("- Not transcribed `\(timestamp(gap.start))–\(timestamp(gap.end))`: \(gap.reason)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// "04:07", or "1:04:07" past the first hour.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(two(m)):\(two(s))"
    }
}
