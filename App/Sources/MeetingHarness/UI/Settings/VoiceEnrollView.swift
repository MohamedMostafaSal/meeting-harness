import SwiftUI

/// Records about ten seconds of someone talking and saves their voice fingerprint.
struct VoiceEnrollView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phase: Phase = .ready
    @State private var recorder = Recorder()

    enum Phase: Equatable {
        case ready, recording(Int), saving, done, failed(String)
    }

    private let seconds = 10

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Read this aloud, at your normal pace:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Good morning everyone. Let's go through the plan for this week and agree on next steps.")
                        .font(.body)
                    Text("صباح الخير يا جماعة، خلينا نراجع خطة الأسبوع ونتفق على الخطوات الجاية.")
                        .font(.system(size: 19))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                .card()

                Spacer()
                status
                Spacer()
                actionButton
            }
            .padding(20)
            .background(Theme.paper)
            .navigationTitle("Add a voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { recorder.discard(); dismiss() } } }
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .ready:
            if !app.models.isReady(.speakers) {
                Text("Download the Speakers model in Settings › Models first.")
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            } else {
                LogoMark(size: 72)
            }
        case .recording(let left):
            VStack(spacing: 12) {
                LevelMeter(levels: recorder.levels, active: true).frame(height: 60)
                Text("\(left)").font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
            }
        case .saving:
            ProgressView("Learning the voice…")
        case .done:
            StatusLabel(text: "Saved. \(name) will be named in new transcripts.", systemImage: "checkmark.circle.fill", color: Theme.signal)
        case .failed(let message):
            StatusLabel(text: message, systemImage: "exclamationmark.triangle", color: Theme.record)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch phase {
        case .done:
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
        case .recording, .saving:
            EmptyView()
        default:
            Button {
                Task { await record() }
            } label: {
                Label("Record \(seconds) seconds", systemImage: "mic.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !app.models.isReady(.speakers))
        }
    }

    private func record() async {
        guard await recorder.requestPermission() else {
            phase = .failed("Allow microphone access in Settings › Harness.")
            return
        }
        do {
            try recorder.start()
            for left in stride(from: seconds, to: 0, by: -1) {
                phase = .recording(left)
                try await Task.sleep(for: .seconds(1))
            }
            guard let result = recorder.stop() else { throw CocoaError(.fileNoSuchFile) }
            phase = .saving
            defer { try? FileManager.default.removeItem(at: result.url) }
            guard let voice = try await app.transcription.fingerprint(ofAudioAt: result.url) else {
                phase = .failed("No voice was heard. Try again closer to the phone.")
                return
            }
            app.voices.enroll(name: name.trimmingCharacters(in: .whitespaces), embedding: voice)
            phase = .done
        } catch {
            recorder.discard()
            phase = .failed(error.localizedDescription)
        }
    }
}
