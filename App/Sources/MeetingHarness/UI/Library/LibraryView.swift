import SwiftUI
import UniformTypeIdentifiers

/// The list of meetings, newest first, with recording one tap away.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [String] = []
    @State private var recording = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var pendingDelete: Meeting?
    @State private var importError: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.store.meetings.isEmpty {
                    EmptyLibrary(record: { recording = true })
                } else {
                    meetingList
                }
            }
            .background(Theme.paper)
            .navigationTitle("Meetings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("Import a recording")
                }
            }
            .navigationDestination(for: String.self) { MeetingView(meetingID: $0) }
            .safeAreaInset(edge: .bottom) {
                if !app.store.meetings.isEmpty { RecordBar { recording = true } }
            }
            .fullScreenCover(isPresented: $recording) {
                RecordingView { id in path = [id] }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav]) { result in
                importAudio(result)
            }
            .confirmationDialog(
                "Delete this meeting?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { meeting in
                Button("Delete recording and transcript", role: .destructive) { app.store.delete(meeting) }
            } message: { _ in
                Text("This can't be undone.")
            }
            .alert("Couldn't import that file", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var meetingList: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.meetings) { meeting in
                        NavigationLink(value: meeting.id) { MeetingRow(meeting: meeting) }
                            .listRowBackground(Theme.card)
                            .swipeActions {
                                Button(role: .destructive) { pendingDelete = meeting } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var sections: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: app.store.meetings) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            return (title, grouped[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private func importAudio(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let duration = AudioDuration.of(url)
            let meeting = try app.store.add(audioAt: url, duration: duration,
                                            title: url.deletingPathExtension().lastPathComponent, move: false)
            app.transcription.enqueue(meeting)
            path = [meeting.id]
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// One meeting in the library: title, length, status or preview, speakers, languages.
struct MeetingRow: View {
    @Environment(AppModel.self) private var app
    var meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(clockString(meeting.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            status
            if !meeting.speakers.isEmpty || !meeting.languages.isEmpty {
                HStack(spacing: 8) {
                    SpeakerStack(speakers: meeting.speakers, size: 22)
                    Spacer()
                    ForEach(meeting.languages, id: \.self) { LanguageTag(code: $0) }
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var status: some View {
        switch meeting.status {
        case .ready:
            if !meeting.preview.isEmpty {
                Text(meeting.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .environment(\.layoutDirection, layoutDirection(for: meeting.languages.first))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .transcribing:
            ProgressRow(run: app.transcription.runs[meeting.id])
        case .recorded:
            StatusLabel(text: "Waiting to be transcribed", systemImage: "clock", color: .secondary)
        case .needsModels:
            StatusLabel(text: "Download models to transcribe", systemImage: "arrow.down.circle", color: Theme.warn)
        case .failed:
            StatusLabel(text: "Transcription failed", systemImage: "exclamationmark.triangle", color: Theme.record)
        }
    }
}

/// A compact progress line for a meeting being transcribed.
struct ProgressRow: View {
    var run: TranscriptionService.Run?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.signal)
            if let fraction = run?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private var label: String {
        switch run?.stage {
        case .speakers: return "Working out who spoke…"
        case .languages: return "Detecting languages…"
        case .transcription: return "Transcribing…"
        case nil: return "Queued"
        }
    }
}

/// The record button, floating over the list.
struct RecordBar: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.record)
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).padding(4)
            }
            .frame(width: 72, height: 72)
            .shadow(color: Theme.record.opacity(0.35), radius: 12, y: 4)
        }
        .accessibilityLabel("Record a meeting")
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(.bar)
    }
}

/// The first screen before any meeting exists.
struct EmptyLibrary: View {
    var record: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            LogoMark(size: 120)
            VStack(spacing: 8) {
                Text("Record your first meeting")
                    .font(.title2.weight(.semibold))
                Text("English, Egyptian Arabic, or both in one sentence. Every speaker gets their own name. Nothing leaves this iPhone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button(action: record) {
                Label("Start recording", systemImage: "record.circle")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(Theme.record, in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
            Text("You can also import a Voice Memo with the button above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}
