import HarnessCore
import SwiftUI

/// Full-screen recording: a clock, a live level meter, live captions, and three clear actions.
struct RecordingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onFinish: (String) -> Void

    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var started = false
    @State private var captioner: LiveCaptioner?
    @State private var captionsDeferred = false

    private var recorder: Recorder { app.recorder }
    private var demo: Bool { LaunchOptions.demo }
    private var isRecording: Bool { demo || recorder.state == .recording }

    var body: some View {
        VStack(spacing: 0) {
            header
            Text(clockString(demo ? 754 : recorder.elapsed))
                .font(.system(size: 64, weight: .thin, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .padding(.top, 28)
                .accessibilityLabel("Recorded \(durationString(recorder.elapsed))")
            LevelMeter(levels: demo ? Self.demoLevels : recorder.levels, active: isRecording)
                .frame(height: 72)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            captions
                .padding(.top, 24)
            if recorder.interrupted {
                Text("Paused by a call or another app. Tap resume when you're ready.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
            }
            controls
                .padding(.top, 12)
                .padding(.bottom, 28)
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
                release()
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRecording ? Theme.record : .gray)
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

    /// Live captions, newest at the bottom; the sentence still being spoken is dimmed.
    private var captions: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let captioner, !(captioner.lines.isEmpty && captioner.draft == nil) {
                        ForEach(captioner.lines) { line in
                            CaptionLine(caption: line, isDraft: false)
                        }
                        if let draft = captioner.draft {
                            CaptionLine(caption: draft, isDraft: true).id("draft")
                        }
                    } else {
                        Text(captionHint)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 24)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25)))
            .onChange(of: captioner?.lines.count) { withAnimation { scroller.scrollTo("end") } }
            .onChange(of: captioner?.draft?.text) { withAnimation { scroller.scrollTo("end") } }
        }
        .frame(maxHeight: .infinity)
    }

    private var captionHint: String {
        if captionsDeferred {
            return "Live captions are off while an earlier meeting finishes transcribing. Your recording is unaffected."
        }
        return app.models.isReady(.multilingual)
            ? "Live captions appear as people speak. The full transcript, with speakers, is made when you stop."
            : "Live captions need the Language detection model (Settings › Models). The full transcript is made when you stop."
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
        if demo {
            let demoCaptioner = makeCaptioner()
            demoCaptioner?.showDemo(DemoData.liveCaptions, draft: "طيب، خلينا نشوف الـ")
            captioner = demoCaptioner
            return
        }
        guard await recorder.requestPermission() else {
            error = "Allow microphone access in Settings › Harness › Microphone, then try again."
            return
        }
        do {
            try recorder.start()
            // Hold the queue; if a meeting is already mid-transcription, skip captions
            // rather than load a second model next to it.
            captionsDeferred = app.transcription.isBusy
            app.transcription.held = true
            if !captionsDeferred {
                captioner = makeCaptioner()
                captioner?.start()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Live captions run on the small multilingual model, if it's downloaded.
    private func makeCaptioner() -> LiveCaptioner? {
        let folder = app.models.folder(for: .multilingual)
        if folder == nil && !demo { return nil }
        let model = WhisperModel(folder: folder ?? URL(fileURLWithPath: "/dev/null"))
        return LiveCaptioner(
            buffer: recorder.live,
            languageID: WhisperLanguageID(model: model, allowed: app.settings.languages),
            recognizer: WhisperRecognizer(
                descriptor: RecognizerDescriptor(model: ModelInfo(id: "whisper-base", version: "coreml"), languages: [], isMultilingual: true),
                model: model, forcesLanguage: true))
    }

    private func finish() {
        if demo { dismiss(); return }
        guard let result = recorder.stop() else { release(); dismiss(); return }
        do {
            let meeting = try app.store.add(audioAt: result.url, duration: result.duration, move: true)
            app.transcription.enqueue(meeting)
            release()
            dismiss()
            onFinish(meeting.id)
        } catch {
            release()
            self.error = error.localizedDescription
        }
    }

    /// Frees the caption model, then lets the transcription queue run.
    private func release() {
        let captioner = captioner
        let transcription = app.transcription
        Task {
            await captioner?.stop()
            transcription.held = false
        }
    }

    private static let demoLevels: [Float] = (0..<48).map { i in
        let x = Float(i)
        return max(0.05, 0.45 + 0.35 * sin(x * 0.7) * cos(x * 0.23) + (i > 40 ? 0.2 : 0))
    }
}

/// One caption line, in its language's reading direction.
struct CaptionLine: View {
    var caption: LiveCaptioner.Caption
    var isDraft: Bool

    var body: some View {
        Text(caption.text)
            .font(caption.language == "ar" ? .system(size: 22, weight: .medium) : .system(size: 20, weight: .medium))
            .lineSpacing(caption.language == "ar" ? 6 : 3)
            .foregroundStyle(.white.opacity(isDraft ? 0.5 : 0.95))
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, layoutDirection(for: caption.language))
            .transition(.opacity)
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
