import HarnessCore
import SwiftUI

/// One meeting: its state while being transcribed, then the transcript with playback.
struct MeetingView: View {
    @Environment(AppModel.self) private var app
    var meetingID: String

    @State private var transcript: Transcript?
    @State private var selectedSpeaker: Meeting.SpeakerSummary?
    @State private var showReport = false
    @State private var showModels = false
    @State private var renaming = false
    @State private var newTitle = ""

    private var meeting: Meeting? { app.store.meeting(meetingID) }

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                ContentUnavailableView("Meeting not found", systemImage: "questionmark.folder")
            }
        }
        .background(Theme.paper)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: meeting?.status) { load() }
        .onDisappear { app.player.stop() }
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MeetingHeader(meeting: meeting) { selectedSpeaker = $0 }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    stateCard(meeting)
                        .padding(.horizontal, 16)
                    if let transcript {
                        TranscriptList(
                            transcript: transcript,
                            speakers: meeting.speakers,
                            currentTime: app.player.isPlaying || app.player.currentTime > 0 ? app.player.currentTime : nil,
                            play: { app.player.play(from: $0) },
                            selectSpeaker: { id in selectedSpeaker = meeting.speakers.first { $0.id == id } })
                        .padding(.top, 8)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: currentSegmentID) { _, id in
                guard let id, app.player.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.3)) { scroller.scrollTo(id, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if meeting.status == .ready { PlayerBar(player: app.player) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(meeting.title).font(.headline).lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) { menu(meeting) }
        }
        .sheet(item: $selectedSpeaker) { speaker in
            SpeakerSheet(meeting: meeting, speaker: speaker, colorIndex: meeting.speakers.firstIndex(of: speaker)) { load() }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(report: app.store.report(for: meeting), transcript: transcript)
        }
        .sheet(isPresented: $showModels) { NavigationStack { ModelsView() } }
        .alert("Rename meeting", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                var updated = meeting
                updated.title = newTitle.trimmingCharacters(in: .whitespaces).isEmpty ? meeting.title : newTitle
                app.store.update(updated)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func stateCard(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .ready:
            EmptyView()
        case .transcribing:
            ProcessingCard(run: app.transcription.runs[meeting.id])
        case .recorded:
            ActionCard(
                title: "Not transcribed yet",
                message: "Transcribe it now. It runs on this iPhone and takes a little while for long meetings.",
                systemImage: "waveform",
                tint: Theme.signal,
                action: ("Transcribe", { app.transcription.enqueue(meeting) }))
        case .needsModels:
            ActionCard(
                title: "Models needed",
                message: "Download the \(app.models.missing(for: app.settings.languages).map(\.title).joined(separator: ", ")) models once, then this meeting is transcribed on your iPhone.",
                systemImage: "arrow.down.circle",
                tint: Theme.warn,
                action: ("Download models", { showModels = true }))
        case .failed:
            ActionCard(
                title: "Transcription stopped",
                message: meeting.failure ?? "Something went wrong.",
                systemImage: "exclamationmark.triangle",
                tint: Theme.record,
                action: ("Try again", { app.transcription.enqueue(meeting) }))
        }
    }

    private func menu(_ meeting: Meeting) -> some View {
        Menu {
            if meeting.status == .ready {
                let folder = app.store.folder(for: meeting.id)
                ShareLink(item: folder.appendingPathComponent("transcript.md")) {
                    Label("Share transcript", systemImage: "doc.text")
                }
                ShareLink(item: folder.appendingPathComponent("events.jsonl")) {
                    Label("Share for AI tools (JSON Lines)", systemImage: "curlybraces")
                }
            }
            ShareLink(item: app.store.audioURL(for: meeting)) {
                Label("Share audio", systemImage: "waveform")
            }
            Divider()
            Button { newTitle = meeting.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            if meeting.status == .ready {
                Button { showReport = true } label: { Label("How this was transcribed", systemImage: "point.3.connected.trianglepath.dotted") }
                Button { app.transcription.enqueue(meeting) } label: { Label("Transcribe again", systemImage: "arrow.clockwise") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    private var currentSegmentID: String? {
        guard let transcript, app.player.isPlaying else { return nil }
        let t = app.player.currentTime
        return transcript.segments.last { $0.start <= t }?.id
    }

    private func load() {
        guard let meeting else { return }
        transcript = app.store.transcript(for: meeting)
        if meeting.status == .ready, app.player.duration == 0 {
            app.player.load(app.store.audioURL(for: meeting))
        }
    }
}

/// Date, length and the speakers, each tappable.
struct MeetingHeader: View {
    var meeting: Meeting
    var selectSpeaker: (Meeting.SpeakerSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(meeting.createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                Text("·")
                Text(durationString(meeting.duration))
                ForEach(meeting.languages, id: \.self) { LanguageTag(code: $0) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !meeting.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(meeting.speakers.enumerated()), id: \.element.id) { index, speaker in
                            Button { selectSpeaker(speaker) } label: {
                                HStack(spacing: 6) {
                                    SpeakerAvatar(name: speaker.displayName, color: Theme.color(forSpeakerAt: index), size: 24)
                                    Text(speaker.displayName).font(.subheadline.weight(.medium))
                                    Text(talkShare(speaker)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.leading, 4)
                                .padding(.trailing, 10)
                                .padding(.vertical, 4)
                                .background(Theme.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.rule))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Rename or remember this voice")
                        }
                    }
                }
            }
        }
    }

    private func talkShare(_ speaker: Meeting.SpeakerSummary) -> String {
        let total = meeting.speakers.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return "" }
        return "\(Int((speaker.seconds / total * 100).rounded()))%"
    }
}

/// The three phases of a run, so a long wait reads as progress.
struct ProcessingCard: View {
    var run: TranscriptionService.Run?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribing on this iPhone")
                .font(.headline)
            step("Who spoke", stage: .speakers, systemImage: "person.2")
            step("Which language", stage: .languages, systemImage: "globe")
            step("What was said", stage: .transcription, systemImage: "text.bubble")
            Text("Keep Harness open until it finishes. Your phone stays awake while it works.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func step(_ title: String, stage: PipelineProgress.Stage, systemImage: String) -> some View {
        let order: [PipelineProgress.Stage] = [.speakers, .languages, .transcription]
        let current = run.map { order.firstIndex(of: $0.stage) ?? 0 } ?? -1
        let mine = order.firstIndex(of: stage) ?? 0
        let state: (icon: String, color: Color) = mine < current
            ? ("checkmark.circle.fill", Theme.signal)
            : mine == current ? (systemImage, Theme.signal) : (systemImage, Color.secondary.opacity(0.5))

        return HStack(spacing: 12) {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(mine == current ? .semibold : .regular))
                    .foregroundStyle(mine <= current ? Theme.ink : .secondary)
                if mine == current {
                    if let fraction = run?.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
        }
    }
}

/// A state the user can act on: not transcribed, models missing, failed.
struct ActionCard: View {
    var title: String
    var message: String
    var systemImage: String
    var tint: Color
    var action: (label: String, run: () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action.label, action: action.run)
                .buttonStyle(.borderedProminent)
                .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
