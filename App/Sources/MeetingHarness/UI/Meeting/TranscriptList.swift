import HarnessCore
import SwiftUI

/// The transcript as a conversation: a speaker header when the speaker changes,
/// each line in its own reading direction, tap a line to hear it.
struct TranscriptList: View {
    var transcript: Transcript
    var speakers: [Meeting.SpeakerSummary]
    var currentTime: TimeInterval?
    var play: (TimeInterval) -> Void
    var selectSpeaker: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item.kind {
                case .segment(let segment, let showsHeader, let previousLanguage):
                    SegmentRow(
                        segment: segment,
                        speakerIndex: speakers.firstIndex { $0.id == segment.speaker?.rawValue },
                        showsHeader: showsHeader,
                        showsLanguage: segment.language?.rawValue != previousLanguage,
                        isCurrent: isCurrent(segment),
                        play: { play(segment.start) },
                        selectSpeaker: { if let id = segment.speaker?.rawValue { selectSpeaker(id) } })
                        .id(segment.id)
                case .gap(let gap):
                    GapRow(gap: gap)
                }
            }
        }
    }

    private func isCurrent(_ segment: Segment) -> Bool {
        guard let t = currentTime else { return false }
        return segment.start <= t && t < segment.end
    }

    private struct Item: Identifiable {
        enum Kind {
            case segment(Segment, showsHeader: Bool, previousLanguage: String?)
            case gap(Gap)
        }
        var id: String
        var start: Double
        var kind: Kind
    }

    private var items: [Item] {
        var out: [Item] = []
        var previous: Segment?
        for segment in transcript.segments {
            let header = previous == nil || previous?.speaker != segment.speaker || segment.start - (previous?.end ?? 0) > 30
            out.append(Item(id: segment.id, start: segment.start,
                            kind: .segment(segment, showsHeader: header, previousLanguage: header ? nil : previous?.language?.rawValue)))
            previous = segment
        }
        out += transcript.gaps.enumerated().map { Item(id: "gap\($0.offset)", start: $0.element.start, kind: .gap($0.element)) }
        return out.sorted { $0.start < $1.start }
    }
}

struct SegmentRow: View {
    var segment: Segment
    var speakerIndex: Int?
    var showsHeader: Bool
    var showsLanguage: Bool
    var isCurrent: Bool
    var play: () -> Void
    var selectSpeaker: () -> Void

    private var name: String { segment.speakerName ?? segment.speaker?.rawValue ?? "Speaker" }
    private var color: Color { Theme.color(forSpeakerAt: speakerIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(spacing: 10) {
                    Button(action: selectSpeaker) {
                        HStack(spacing: 8) {
                            SpeakerAvatar(name: name, color: color, size: 28)
                            Text(name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(color)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(segment.speaker == nil)
                    Text(clockString(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 14)
            }
            Button(action: play) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(segment.text)
                            .font(segment.language == .arabic ? .system(size: 19) : .body)
                            .lineSpacing(segment.language == .arabic ? 6 : 3)
                            .foregroundStyle(segment.uncertain ? Theme.ink.opacity(0.6) : Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, layoutDirection(for: segment.language?.rawValue))
                        if showsLanguage, let language = segment.language?.rawValue {
                            LanguageTag(code: language)
                        }
                    }
                    if segment.uncertain || segment.overlap {
                        HStack(spacing: 10) {
                            if segment.uncertain {
                                StatusLabel(text: "Unsure", systemImage: "questionmark.circle", color: Theme.warn)
                            }
                            if segment.overlap {
                                StatusLabel(text: "People talking at once", systemImage: "person.2.wave.2", color: Theme.warn)
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, 38)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays from \(clockString(segment.start))")
        }
        .padding(.horizontal, 16)
        .background(isCurrent ? color.opacity(0.08) : .clear)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}

struct GapRow: View {
    var gap: Gap

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            Text("Not transcribed \(clockString(gap.start))–\(clockString(gap.end))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityLabel("Not transcribed from \(clockString(gap.start)) to \(clockString(gap.end)): \(gap.reason)")
    }
}

/// Play, scrub, and change speed.
struct PlayerBar: View {
    @Bindable var player: Player

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 1))
            HStack {
                Text(clockString(player.currentTime)).monospacedDigit()
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Spacer()
                Menu {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in
                        Button("\(rate.formatted())×") { player.rate = rate }
                    }
                } label: {
                    Text("\(player.rate.formatted())×").font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Playback speed")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.bar)
    }
}
