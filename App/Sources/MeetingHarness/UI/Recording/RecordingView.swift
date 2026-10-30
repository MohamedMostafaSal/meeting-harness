import SwiftUI

/// Full-screen recording: a big clock, a live level meter, and three clear actions.
struct RecordingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onFinish: (String) -> Void

    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var started = false

    private var recorder: Recorder { app.recorder }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            Text(clockString(recorder.elapsed))
                .font(.system(size: 76, weight: .thin, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .accessibilityLabel("Recorded \(durationString(recorder.elapsed))")
            LevelMeter(levels: recorder.levels, active: recorder.state == .recording)
                .frame(height: 96)
                .padding(.horizontal, 24)
                .padding(.top, 28)
            if recorder.interrupted {
                Text("Paused by a call or another app. Tap resume when you're ready.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .padding(.horizontal, 32)
            }
            Spacer()
            controls
                .padding(.bottom, 32)
        }
        .background(Theme.night.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await begin() }
        .alert("Can't record", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil; dismiss() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                recorder.discard()
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorder.state == .recording ? Theme.record : .gray)
                .frame(width: 10, height: 10)
            Text(recorder.state == .paused ? "Paused" : "Recording")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Label("Stays on this iPhone", systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private var controls: some View {
        HStack(alignment: .center) {
            RoundControl(systemImage: "xmark", label: "Discard", size: 56) { confirmDiscard = true }
            Spacer()
            Button(action: finish) {
                ZStack {
                    Circle().fill(Theme.record)
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 26, height: 26)
                }
                .frame(width: 84, height: 84)
            }
            .accessibilityLabel("Stop and transcribe")
            Spacer()
            RoundControl(
                systemImage: recorder.state == .paused ? "play.fill" : "pause.fill",
                label: recorder.state == .paused ? "Resume" : "Pause",
                size: 56
            ) {
                recorder.state == .paused ? recorder.resume() : recorder.pause()
            }
        }
        .padding(.horizontal, 40)
    }

    private func begin() async {
        guard !started else { return }
        started = true
        guard await recorder.requestPermission() else {
            error = "Allow microphone access in Settings › Harness › Microphone, then try again."
            return
        }
        do {
            try recorder.start()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish() {
        guard let result = recorder.stop() else { dismiss(); return }
        do {
            let meeting = try app.store.add(audioAt: result.url, duration: result.duration, move: true)
            app.transcription.enqueue(meeting)
            dismiss()
            onFinish(meeting.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A circular secondary control with a caption.
struct RoundControl: View {
    var systemImage: String
    var label: String
    var size: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.12), in: Circle())
                Text(label).font(.caption)
            }
            .foregroundStyle(.white)
        }
        .accessibilityLabel(label)
    }
}

/// Recent input levels as mirrored bars, newest on the right.
struct LevelMeter: View {
    var levels: [Float]
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 3
            let width = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(active ? Theme.speakerColors[0].opacity(0.35 + 0.65 * Double(index) / Double(count)) : .gray.opacity(0.4))
                        .frame(width: width, height: max(4, CGFloat(level) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.05), value: levels)
        }
        .accessibilityHidden(true)
    }
}
