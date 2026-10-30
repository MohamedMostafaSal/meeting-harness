import SwiftUI

@main
struct MeetingHarnessApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.signal)
        }
    }
}

/// Everything the screens share, created once.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let store = MeetingStore()
    let models = ModelManager()
    let voices = VoiceStore()
    let player = Player()
    let recorder = Recorder()
    let transcription: TranscriptionService

    init() {
        transcription = TranscriptionService(store: store, models: models, settings: settings, voices: voices)
        if LaunchOptions.demo {
            DemoData.seed(store)
            settings.onboarded = LaunchOptions.screen != "onboarding"
        }
    }

    /// Transcribes everything that was waiting for models once they're downloaded.
    func transcribeWaiting() {
        for meeting in store.meetings where meeting.status == .needsModels || meeting.status == .recorded {
            transcription.enqueue(meeting)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        LibraryView()
            .fullScreenCover(isPresented: Binding(
                get: { !app.settings.onboarded },
                set: { if !$0 { app.settings.onboarded = true } })
            ) {
                OnboardingView()
            }
    }
}
