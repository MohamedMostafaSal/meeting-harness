import Foundation

// Deterministic quality steps around the models: ingest level (D1), confidence
// and hallucination gating (D8), and joining segments for reading (D6). Same
// rules as the web prototype (web/harness.js).

public enum Loudness {
    /// Speech loudness: the 90th-percentile 100 ms RMS in dBFS, so silence doesn't drag it down.
    public static func speechLevel(_ samples: [Float], sampleRate: Int) -> (speechDB: Double, peak: Float) {
        let frame = max(1, sampleRate / 10)
        var levels: [Double] = []
        var peak: Float = 0
        var i = 0
        while i + frame <= samples.count {
            var energy: Double = 0
            for j in i..<(i + frame) {
                let x = samples[j]
                energy += Double(x * x)
                peak = max(peak, abs(x))
            }
            levels.append((energy / Double(frame)).squareRoot())
            i += frame
        }
        guard !levels.isEmpty else { return (-.infinity, 0) }
        levels.sort()
        let p90 = levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))]
        return (p90 > 0 ? 20 * log10(p90) : -.infinity, peak)
    }

    /// Brings speech to about −20 dBFS without clipping, boosting by at most 30 dB.
    /// Quiet phone recordings otherwise read as silence to the speech detector.
    public static func normalize(_ clip: AudioClip, targetDB: Double = -20, maxGainDB: Double = 30, ceiling: Float = 0.98) -> (clip: AudioClip, gainDB: Double, speechDB: Double) {
        let (speechDB, peak) = speechLevel(clip.samples, sampleRate: clip.sampleRate)
        guard peak > 0, speechDB.isFinite else { return (clip, 0, speechDB) }
        let gainDB = min(targetDB - speechDB, maxGainDB, 20 * log10(Double(ceiling / peak)))
        let gain = Float(pow(10, gainDB / 20))
        var out = clip
        out.samples = clip.samples.map { $0 * gain }
        return (out, gainDB, speechDB)
    }
}

public enum HallucinationGuard {
    /// Phrases small Whisper models are known to invent over silence or music.
    static let knownPhrases: [String] = [
        "thank you for watching", "thanks for watching", "please subscribe", "like and subscribe",
        "اشتركوا في القناة", "نانسي قنقر", "شكرا على المشاهدة", "شكرا لكم على المشاهدة",
        "[music]", "[موسيقى]", "♪",
    ]

    public enum Verdict: Equatable, Sendable {
        case ok
        /// No words at all: drop it.
        case empty
        /// Keep it, but flag it as uncertain with this reason.
        case suspicious(String)
    }

    public static func check(_ text: String, duration: Double) -> Verdict {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return .empty }
        let lower = clean.lowercased()
        if knownPhrases.contains(where: { lower.contains($0) }) { return .suspicious("looks like a known Whisper hallucination") }
        let words = clean.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 8 && Double(Set(words).count) / Double(words.count) < 0.3 { return .suspicious("repeats itself") }
        let letters = clean.filter { !$0.isWhitespace }.count
        if duration > 0 && Double(letters) / duration > 30 { return .suspicious("too much text for the audio length") }
        return .ok
    }
}

public enum SegmentMerger {
    /// Joins consecutive segments by the same speaker in the same language across
    /// small gaps, then numbers them s_0001, s_0002…
    public static func merge(_ segments: [Segment], policy: MergePolicy) -> [Segment] {
        var out: [Segment] = []
        for s in segments {
            if var last = out.last,
               last.speaker == s.speaker, last.language == s.language,
               !last.overlap, !s.overlap,
               s.start - last.end <= policy.maxGap,
               s.end - last.start <= policy.maxDuration {
                last.end = s.end
                last.text += " " + s.text
                last.words += s.words
                last.confidence = min(last.confidence, s.confidence)
                last.uncertain = last.uncertain || s.uncertain
                if !last.producer.split(separator: "+").contains(Substring(s.producer)) { last.producer += "+" + s.producer }
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        for i in out.indices { out[i].id = Pipeline.segmentID(i + 1) }
        return out
    }
}
