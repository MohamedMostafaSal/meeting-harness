import SwiftUI

/// First launch: what the app does, the models it needs, and the microphone.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var micGranted: Bool?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                models.tag(1)
                microphone.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // The system page dots are white and vanish on the light background.
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Theme.signal : Theme.rule)
                        .frame(width: i == page ? 20 : 8, height: 8)
                }
            }
            .animation(.snappy, value: page)
            .padding(.bottom, 20)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of 3")

            Button(page < 2 ? "Continue" : "Start") {
                if page < 2 { withAnimation { page += 1 } } else { app.settings.onboarded = true }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if page < 2 {
                Button("Skip") { app.settings.onboarded = true }
                    .font(.subheadline)
                    .padding(.bottom, 16)
            } else {
                Color.clear.frame(height: 36)
            }
        }
        .background(Theme.paper)
    }

    private var welcome: some View {
        featurePage(
            visual: AnyView(LogoMark(size: 140)),
            title: "Meetings, transcribed on your iPhone",
            points: [
                ("globe", "English and Egyptian Arabic, even both in one sentence. Each sentence goes to a model for its language."),
                ("person.2", "Every speaker gets a name, and known voices are recognized next time."),
                ("lock", "Nothing leaves your phone. Transcripts are files your AI tools can read."),
            ])
    }

    private var models: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 56))
                .foregroundStyle(Theme.signal)
            Text("Download the models")
                .font(.title2.weight(.semibold))
            Text("Small models, each good at one job. They download once and then work offline.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            VStack(spacing: 0) {
                ForEach(ModelPack.required(for: app.settings.languages)) { pack in
                    ModelPackRow(pack: pack, needed: true)
                        .padding(.vertical, 8)
                    Divider()
                }
            }
            .card()
            .padding(.horizontal, 20)
            Spacer()
        }
    }

    private var microphone: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: micGranted == true ? "mic.circle.fill" : "mic.circle")
                .font(.system(size: 72))
                .foregroundStyle(micGranted == false ? Theme.warn : Theme.signal)
            Text("Allow the microphone")
                .font(.title2.weight(.semibold))
            Text(micGranted == false
                 ? "Microphone access is off. You can turn it on later in Settings › Harness."
                 : "Harness records only when you tap record, and the audio stays on this iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if micGranted == nil {
                Button("Allow microphone") {
                    Task { micGranted = await app.recorder.requestPermission() }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    private func featurePage(visual: AnyView, title: String, points: [(String, String)]) -> some View {
        VStack(spacing: 28) {
            Spacer()
            visual
            Text(title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(points, id: \.1) { icon, text in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundStyle(Theme.signal)
                            .frame(width: 28)
                        Text(text).font(.body)
                    }
                }
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }
}
