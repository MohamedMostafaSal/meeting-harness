/// A stretch of speech transcribed in one go: consecutive turns by one known speaker.
public struct Utterance: Equatable, Sendable {
    public var range: TimeRange
    public var label: SpeakerLabel?
    public var overlap: Bool

    public init(range: TimeRange, label: SpeakerLabel?, overlap: Bool) {
        self.range = range
        self.label = label
        self.overlap = overlap
    }
}

public enum Utterances {
    /// Joins consecutive turns by the same known speaker, so speech is transcribed in
    /// whole sentences instead of pause-to-pause scraps. Unknown speakers and overlapped
    /// turns are never joined; long stretches are split evenly to fit Whisper's window.
    public static func group(_ turns: [DiarizedTurn], labels: [Int: SpeakerLabel], policy: UtterancePolicy) -> [Utterance] {
        var out: [Utterance] = []
        for turn in turns.sorted(by: { $0.range.start < $1.range.start }) {
            let label = turn.speaker.flatMap { labels[$0] }
            if let last = out.last, let label, last.label?.id == label.id,
               !last.overlap, !turn.overlap,
               turn.range.start - last.range.end <= policy.maxGap,
               turn.range.end - last.range.start <= policy.maxDuration {
                out[out.count - 1].range = TimeRange(start: last.range.start, end: turn.range.end)
            } else {
                for piece in evenSplit(turn.range, maxLength: policy.maxDuration) {
                    out.append(Utterance(range: piece, label: label, overlap: turn.overlap))
                }
            }
        }
        return out
    }

    /// Splits `range` into equal parts no longer than `maxLength`.
    public static func evenSplit(_ range: TimeRange, maxLength: Double) -> [TimeRange] {
        let n = max(1, Int((range.duration / maxLength - 1e-9).rounded(.up)))
        let step = range.duration / Double(n)
        return (0..<n).map { i in
            TimeRange(start: range.start + Double(i) * step, end: i == n - 1 ? range.end : range.start + Double(i + 1) * step)
        }
    }
}
