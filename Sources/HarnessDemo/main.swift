import HarnessCore
import HarnessTesting

// Runs the README's example meeting through the real harness with scripted
// models, and prints what the connector would publish.

let meeting = DemoMeeting()
let sink = InMemoryEventSink()
let transcript = try await Pipeline(models: meeting.models, registry: meeting.registry)
    .transcribe(meeting.audio, meetingID: "demo", sink: sink)

print(MarkdownExporter.render(transcript))
print("--- events (JSON Lines) ---")
print(try EventEncoding.jsonLines(sink.events), terminator: "")
