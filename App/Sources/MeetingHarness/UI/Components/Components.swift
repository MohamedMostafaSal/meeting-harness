import SwiftUI

/// The logo, drawn as vectors: three voice strands joining one transcript line.
struct LogoMark: View {
    var size: CGFloat = 64
    var colors: [Color] = [Theme.speakerColors[0], Theme.speakerColors[1], Theme.speakerColors[2]]
    var ink: Color = Theme.ink

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 120
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let style = StrokeStyle(lineWidth: 6 * s, lineCap: .round, lineJoin: .round)

            var top = Path()
            top.move(to: p(16, 34))
            top.addQuadCurve(to: p(26, 34), control: p(21, 25))
            top.addQuadCurve(to: p(36, 34), control: p(31, 43))
            top.addQuadCurve(to: p(46, 34), control: p(41, 25))
            top.addCurve(to: p(76, 60), control1: p(58, 34), control2: p(62, 60))

            var middle = Path()
            middle.move(to: p(16, 60))
            middle.addQuadCurve(to: p(26, 60), control: p(21, 49))
            middle.addQuadCurve(to: p(36, 60), control: p(31, 71))
            middle.addQuadCurve(to: p(46, 60), control: p(41, 49))
            middle.addQuadCurve(to: p(56, 60), control: p(51, 71))
            middle.addLine(to: p(76, 60))

            var bottom = Path()
            bottom.move(to: p(16, 86))
            bottom.addQuadCurve(to: p(26, 86), control: p(21, 77))
            bottom.addQuadCurve(to: p(36, 86), control: p(31, 95))
            bottom.addQuadCurve(to: p(46, 86), control: p(41, 77))
            bottom.addCurve(to: p(76, 60), control1: p(58, 86), control2: p(62, 60))

            var line = Path()
            line.move(to: p(84, 60))
            line.addLine(to: p(104, 60))

            context.stroke(top, with: .color(colors[0]), style: style)
            context.stroke(middle, with: .color(colors[1]), style: style)
            context.stroke(bottom, with: .color(colors[2]), style: style)
            context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 7 * s, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 70 * s, y: 52 * s, width: 16 * s, height: 16 * s)), with: .color(ink))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A speaker's initials on their colour.
struct SpeakerAvatar: View {
    var name: String
    var color: Color
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(color.opacity(0.16))
            .overlay(Circle().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ")
        if name.hasPrefix("S"), name.dropFirst().allSatisfy(\.isNumber) { return name }
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// "EN", "AR": the language a stretch of speech was routed as.
struct LanguageTag: View {
    var code: String

    var body: some View {
        Text(code.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.rule, lineWidth: 1))
            .accessibilityLabel(languageName(code))
    }
}

/// A short status line with an icon, in a semantic colour.
struct StatusLabel: View {
    var text: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

/// Overlapping avatars for a meeting's speakers.
struct SpeakerStack: View {
    var speakers: [Meeting.SpeakerSummary]
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(speakers.prefix(4).enumerated()), id: \.element.id) { index, speaker in
                SpeakerAvatar(name: speaker.displayName, color: Theme.color(forSpeakerAt: index), size: size)
                    .background(Circle().fill(Theme.card))
            }
            if speakers.count > 4 {
                Text("+\(speakers.count - 4)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, size * 0.4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(speakers.count) speakers")
    }
}

/// A rounded surface for cards on the paper background.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
