import HarnessCore
import SwiftUI

/// Rename a speaker, and remember their voice so future meetings name them.
struct SpeakerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var meeting: Meeting
    var speaker: Meeting.SpeakerSummary
    var colorIndex: Int?
    var onChange: () -> Void

    @State private var name = ""
    @State private var remember = false

    private var voice: SpeakerEmbedding? { app.store.voices(for: meeting)[speaker.id] }
    private var alreadyKnown: Bool { app.voices.voices.contains { $0.id.rawValue == speaker.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        SpeakerAvatar(name: name.isEmpty ? speaker.displayName : name, color: Theme.color(forSpeakerAt: colorIndex), size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spoke for \(durationString(speaker.seconds))")
                            if alreadyKnown { Text("Recognized from your saved voices").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }
                if voice != nil && !alreadyKnown {
                    Section {
                        Toggle("Remember this voice", isOn: $remember)
                    } footer: {
                        Text("Future meetings will name this voice automatically. The voice fingerprint stays on this iPhone.")
                    }
                }
            }
            .navigationTitle("Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(remember && name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = speaker.name ?? "" }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (speaker.name ?? "") {
            app.store.renameSpeaker(speaker.id, to: trimmed, in: meeting)
        }
        if remember, let voice, !trimmed.isEmpty {
            app.voices.enroll(name: trimmed, embedding: voice)
        }
        onChange()
        dismiss()
    }
}

/// How a transcript was made: time per pillar and every routing decision.
struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var report: PipelineReport?
    var transcript: Transcript?

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    Section("Time per step") {
                        ForEach(pillars(report), id: \.name) { pillar in
                            HStack {
                                Text(pillar.name)
                                Spacer()
                                Text(String(format: "%.1f s", pillar.seconds)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        if report.gainDB > 1 {
                            LabeledContent("Quiet audio raised by", value: String(format: "%.0f dB", report.gainDB))
                        }
                    }
                    Section {
                        ForEach(Array(report.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("Routing decisions")
                    } footer: {
                        Text("Each line shows the language detected for a stretch of speech and the model it was sent to.")
                    }
                }
                if let transcript {
                    Section("Models used") {
                        ForEach(Array(Set(transcript.segments.map(\.producer))).sorted(), id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle("How this was transcribed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func pillars(_ report: PipelineReport) -> [(name: String, seconds: Double)] {
        [("Who spoke", report.timings["speakers"] ?? 0),
         ("Which language", report.timings["languageID"] ?? 0),
         ("What was said", report.timings["transcription"] ?? 0)]
    }
}
