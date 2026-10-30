import HarnessCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var enrolling = false

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    ForEach(AppSettings.supportedLanguages, id: \.code) { language in
                        Toggle(language.name, isOn: Binding(
                            get: { settings.languages.contains(language.code) },
                            set: { on in
                                if on { settings.languages.append(language.code) }
                                else if settings.languages.count > 1 { settings.languages.removeAll { $0 == language.code } }
                            }))
                    }
                } header: {
                    Text("Meeting languages")
                } footer: {
                    Text("Language detection only chooses between these, which makes it much more reliable. English and Arabic have their own models; German and French use the multilingual one.")
                }

                Section {
                    NavigationLink {
                        ModelsView()
                    } label: {
                        LabeledContent("Models", value: modelSummary)
                    }
                } footer: {
                    Text("Every model runs on this iPhone. Download once over Wi-Fi.")
                }

                Section {
                    ForEach(app.voices.voices, id: \.id) { voice in
                        Label(voice.name, systemImage: "person.wave.2")
                    }
                    .onDelete { offsets in
                        for i in offsets { app.voices.remove(app.voices.voices[i].id) }
                    }
                    Button { enrolling = true } label: { Label("Add a voice", systemImage: "plus") }
                } header: {
                    Text("Known voices")
                } footer: {
                    Text("Known voices get their names in every transcript. Add yours here, or tap any speaker in a transcript and choose Remember this voice.")
                }

                Section {
                    Toggle("Boost quiet recordings", isOn: $settings.normalizeLoudness)
                    NavigationLink("Routing thresholds") { ThresholdsView() }
                } header: {
                    Text("Transcription")
                }

                Section {
                    Label("Audio and transcripts never leave this iPhone unless you share them.", systemImage: "lock")
                    Label("Transcripts are saved as files in Files › On My iPhone › Harness, so other apps and AI tools can read them.", systemImage: "folder")
                } header: {
                    Text("Privacy")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/MohamedMostafaSal/meeting-harness")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $enrolling) { VoiceEnrollView() }
        }
    }

    private var modelSummary: String {
        let missing = app.models.missing(for: app.settings.languages)
        return missing.isEmpty ? "Ready" : "\(missing.count) to download"
    }
}

/// The router's and naming's numbers, for people tuning on their own meetings.
struct ThresholdsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                slider("Trust a language guess from", value: $settings.languageConfidence, range: 0.5...0.95, format: "%.2f")
            } footer: {
                Text("Below this, speech is re-checked in short windows to catch Arabic and English mixed in one sentence.")
            }
            Section {
                slider("Re-check mixed speech every", value: $settings.splitWindow, range: 1...5, format: "%.1f s")
            }
            Section {
                slider("Name a known voice from", value: $settings.voiceMatch, range: 0.3...0.95, format: "%.2f")
            } footer: {
                Text("Higher means fewer wrong names but more unnamed speakers.")
            }
        }
        .navigationTitle("Routing thresholds")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: format, value.wrappedValue))
            Slider(value: value, in: range)
        }
    }
}

/// Download, check and delete the model packs.
struct ModelsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let needed = ModelPack.required(for: app.settings.languages)
        let missing = app.models.missing(for: app.settings.languages)
        List {
            if !missing.isEmpty {
                Section {
                    Button {
                        Task {
                            await app.models.downloadAll(missing)
                            app.transcribeWaiting()
                        }
                    } label: {
                        Label("Download what your languages need", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                    }
                } footer: {
                    Text("Use Wi-Fi. Sizes show once downloaded.")
                }
            }
            Section("Packs") {
                ForEach(ModelPack.allCases) { pack in
                    ModelPackRow(pack: pack, needed: needed.contains(pack))
                }
            }
        }
        .navigationTitle("Models")
        .onAppear { app.models.refresh() }
    }
}

struct ModelPackRow: View {
    @Environment(AppModel.self) private var app
    var pack: ModelPack
    var needed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: pack.systemImage)
                .font(.title3)
                .foregroundStyle(Theme.signal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(pack.title).font(.headline)
                    if !needed { Text("optional").font(.caption).foregroundStyle(.secondary) }
                }
                Text(pack.purpose).font(.subheadline).foregroundStyle(.secondary)
                stateView
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .swipeActions {
            if app.models.isReady(pack) {
                Button(role: .destructive) { app.models.delete(pack) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder private var stateView: some View {
        switch app.models.states[pack] ?? .missing {
        case .missing:
            Button("Download") { Task { await app.models.download(pack); app.transcribeWaiting() } }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction) { Text("Downloading \(Int(fraction * 100))%").font(.caption) }
            } else {
                ProgressView { Text("Downloading…").font(.caption) }.progressViewStyle(.linear)
            }
        case .ready(let bytes):
            StatusLabel(text: "Ready · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "checkmark.circle.fill", color: Theme.signal)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                StatusLabel(text: "Download failed", systemImage: "exclamationmark.triangle", color: Theme.record)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try again") { Task { await app.models.download(pack) } }.buttonStyle(.bordered)
            }
        }
    }
}
