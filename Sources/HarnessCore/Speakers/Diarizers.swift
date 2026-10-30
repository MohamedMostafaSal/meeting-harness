import Foundation

/// A diarizer composed from the separate pillars: VAD (M1), speaker turns (M2),
/// fingerprints (M3), overlap (M4), clustered by the deterministic harness (D3).
public struct SegmentAndClusterDiarizer: Diarizer {
    public var vad: any VoiceActivityDetector
    public var speakers: SpeakerModels
    public var policy: SpeakerPolicy

    public init(vad: any VoiceActivityDetector, speakers: SpeakerModels, policy: SpeakerPolicy = SpeakerPolicy()) {
        self.vad = vad
        self.speakers = speakers
        self.policy = policy
    }

    public func diarize(_ audio: AudioClip) async throws -> Diarization {
        var turns: [DiarizedTurn] = []
        for region in try await vad.speechRegions(in: audio).sorted(by: { $0.start < $1.start }) {
            let clip = audio.slice(region)
            let ranges = try await speakers.segmenter.speakerTurns(in: clip)
                .compactMap { r -> TimeRange? in
                    let start = max(r.start, region.start), end = min(r.end, region.end)
                    return end > start ? TimeRange(start: start, end: end) : nil
                }
                .sorted { $0.start < $1.start }
            let overlaps = try await speakers.overlap?.overlapRegions(in: clip) ?? []
            for range in ranges.isEmpty ? [region] : ranges {
                let overlap = overlaps.contains { $0.start < range.end && range.start < $0.end }
                turns.append(DiarizedTurn(range: range, speaker: nil, overlap: overlap))
            }
        }

        var embeddings: [SpeakerEmbedding?] = []
        for turn in turns {
            embeddings.append(turn.range.duration >= policy.minEmbeddingDuration
                ? try await speakers.embedder.embed(audio.slice(turn.range))
                : nil)
        }
        let clustering = SpeakerAssignment.cluster(embeddings, reliable: turns.map { !$0.overlap }, policy: policy)
        for i in turns.indices { turns[i].speaker = clustering.speakers[i] }
        let centroids = Dictionary(uniqueKeysWithValues: clustering.centroids.enumerated().map { ($0.offset, $0.element) })
        return Diarization(turns: turns, centroids: centroids)
    }
}

/// Speech regions only, no speakers: for when no speaker models are installed.
public struct VADOnlyDiarizer: Diarizer {
    public var vad: any VoiceActivityDetector

    public init(vad: any VoiceActivityDetector) { self.vad = vad }

    public func diarize(_ audio: AudioClip) async throws -> Diarization {
        let regions = try await vad.speechRegions(in: audio).sorted { $0.start < $1.start }
        return Diarization(turns: regions.map { DiarizedTurn(range: $0, speaker: nil) })
    }
}
