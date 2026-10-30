import Foundation
import HarnessCore
import Observation

/// Meetings on disk: `Documents/Meetings/<id>/`, visible in the Files app.
///
/// Each folder holds `audio.m4a`, `meeting.json`, and once transcribed
/// `transcript.json` (the canonical schema), `transcript.md`, `events.jsonl`
/// (the connector stream) and `report.json` (how it was transcribed).
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []
    let root: URL

    init(root: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? documents.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
    }

    func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func audioURL(for meeting: Meeting) -> URL { folder(for: meeting.id).appendingPathComponent(meeting.audioFile) }

    func reload() {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        meetings = ids.compactMap { id in
            guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("meeting.json")) else { return nil }
            return try? Self.decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
        // A run can't survive the app being killed; show it as needing a retry.
        for i in meetings.indices where meetings[i].status == .transcribing {
            meetings[i].status = .recorded
            try? write(meetings[i])
        }
    }

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    /// Creates a meeting from an audio file, moving or copying it into the meeting's folder.
    @discardableResult
    func add(audioAt source: URL, duration: TimeInterval, createdAt: Date = Date(), title: String? = nil, move: Bool) throws -> Meeting {
        var meeting = Meeting(
            id: Meeting.newID(at: createdAt),
            title: title ?? Meeting.defaultTitle(for: createdAt),
            createdAt: createdAt,
            duration: duration,
            status: .recorded)
        meeting.audioFile = "audio." + (source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased())
        let folder = folder(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(meeting.audioFile)
        if move {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try write(meeting)
        meetings.insert(meeting, at: 0)
        return meeting
    }

    func update(_ meeting: Meeting) {
        try? write(meeting)
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[i] = meeting }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: folder(for: meeting.id))
        meetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Transcript files

    func transcript(for meeting: Meeting) -> Transcript? {
        guard let data = try? Data(contentsOf: folder(for: meeting.id).appendingPathComponent("transcript.json")) else { return nil }
        return try? Self.decoder.decode(Transcript.self, from: data)
    }

    func report(for meeting: Meeting) -> PipelineReport? {
        guard let data = try? Data(contentsOf: folder(for: meeting.id).appendingPathComponent("report.json")) else { return nil }
        return try? Self.decoder.decode(PipelineReport.self, from: data)
    }

    func voices(for meeting: Meeting) -> [String: SpeakerEmbedding] {
        guard let data = try? Data(contentsOf: folder(for: meeting.id).appendingPathComponent("voices.json")) else { return [:] }
        return (try? Self.decoder.decode([String: SpeakerEmbedding].self, from: data)) ?? [:]
    }

    /// Saves every output of a run and refreshes the meeting's summary.
    func save(transcript: Transcript, events: [MeetingEvent], report: PipelineReport, voices: [SpeakerID: SpeakerEmbedding], for meeting: Meeting) throws {
        let folder = folder(for: meeting.id)
        try Self.encoder.encode(transcript).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try Self.encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        try Self.encoder.encode(Dictionary(uniqueKeysWithValues: voices.map { ($0.key.rawValue, $0.value) }))
            .write(to: folder.appendingPathComponent("voices.json"), options: .atomic)
        try Data(EventEncoding.jsonLines(events).utf8).write(to: folder.appendingPathComponent("events.jsonl"), options: .atomic)
        try Data(MarkdownExporter.render(transcript).utf8).write(to: folder.appendingPathComponent("transcript.md"), options: .atomic)

        var updated = meeting
        updated.status = .ready
        updated.failure = nil
        updated.languages = transcript.languagesInOrder
        updated.speakers = transcript.speakerSummaries
        updated.preview = String(transcript.segments.first?.text.prefix(140) ?? "")
        update(updated)
    }

    /// Applies a speaker rename to the saved transcript and its exports (`speaker.renamed`).
    func renameSpeaker(_ id: String, to name: String, in meeting: Meeting) {
        guard var transcript = transcript(for: meeting) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in transcript.segments.indices where transcript.segments[i].speaker?.rawValue == id {
            transcript.segments[i].speakerName = trimmed.isEmpty ? nil : trimmed
        }
        let folder = folder(for: meeting.id)
        try? Self.encoder.encode(transcript).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try? Data(MarkdownExporter.render(transcript).utf8).write(to: folder.appendingPathComponent("transcript.md"), options: .atomic)
        // Append to the event stream rather than rewriting it: it's append-only.
        let eventsURL = folder.appendingPathComponent("events.jsonl")
        if let existing = try? String(contentsOf: eventsURL, encoding: .utf8) {
            let seq = existing.split(separator: "\n").count
            let event = MeetingEvent(meeting: meeting.id, seq: seq, kind: .speakerRenamed(SpeakerID(id), name: trimmed))
            if let line = try? EventEncoding.jsonLine(event) {
                try? Data((existing + line + "\n").utf8).write(to: eventsURL, options: .atomic)
            }
        }
        var updated = meeting
        updated.speakers = transcript.speakerSummaries
        update(updated)
    }

    private func write(_ meeting: Meeting) throws {
        try FileManager.default.createDirectory(at: folder(for: meeting.id), withIntermediateDirectories: true)
        try Self.encoder.encode(meeting).write(to: folder(for: meeting.id).appendingPathComponent("meeting.json"), options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
