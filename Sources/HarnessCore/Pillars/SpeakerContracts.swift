import Foundation

// Contracts for the "who spoke" pillars (M2–M4). Like the other pillars, the
// harness only sees these protocols.

/// A voice fingerprint (M3). Only meaningful when compared with embeddings from the same model.
public struct SpeakerEmbedding: Codable, Equatable, Sendable {
    public var vector: [Float]

    public init(_ vector: [Float]) { self.vector = vector }

    /// Cosine similarity in [-1, 1]; 0 when either vector is empty or all zeros.
    public func similarity(to other: SpeakerEmbedding) -> Double {
        guard vector.count == other.vector.count else { return 0 }
        var dot: Double = 0, a: Double = 0, b: Double = 0
        for i in vector.indices {
            let x = Double(vector[i]), y = Double(other.vector[i])
            dot += x * y
            a += x * x
            b += y * y
        }
        guard a > 0, b > 0 else { return 0 }
        return dot / (a.squareRoot() * b.squareRoot())
    }

    /// Mean direction of several embeddings (each normalized first, so loud turns don't dominate).
    public static func centroid(_ embeddings: [SpeakerEmbedding]) -> SpeakerEmbedding? {
        guard let dimension = embeddings.first?.vector.count else { return nil }
        var sum = [Double](repeating: 0, count: dimension)
        for embedding in embeddings where embedding.vector.count == dimension {
            let norm = embedding.vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm > 0 else { continue }
            for i in 0..<dimension { sum[i] += Double(embedding.vector[i]) / norm }
        }
        return SpeakerEmbedding(sum.map { Float($0 / Double(embeddings.count)) })
    }
}

/// M2: where does the voice change? Returns single-speaker turns in meeting time.
public protocol SpeakerSegmenter {
    func speakerTurns(in audio: AudioClip) async throws -> [TimeRange]
}

/// M3: turns a single-speaker clip into a voice fingerprint.
public protocol SpeakerEmbedder {
    func embed(_ audio: AudioClip) async throws -> SpeakerEmbedding
}

/// M4: where are two or more people talking at once?
public protocol OverlapDetector {
    func overlapRegions(in audio: AudioClip) async throws -> [TimeRange]
}

/// The "who spoke" models. All optional as a group: without them, segments have no speaker.
public struct SpeakerModels {
    public var segmenter: any SpeakerSegmenter
    public var embedder: any SpeakerEmbedder
    public var overlap: (any OverlapDetector)?

    public init(segmenter: any SpeakerSegmenter, embedder: any SpeakerEmbedder, overlap: (any OverlapDetector)? = nil) {
        self.segmenter = segmenter
        self.embedder = embedder
        self.overlap = overlap
    }
}

// MARK: - Diarization (M1–M4 as one pillar)

/// One stretch of speech by one speaker, as a diarizer reports it.
public struct DiarizedTurn: Equatable, Sendable {
    public var range: TimeRange
    /// The diarizer's own speaker number, local to one recording. Nil when unknown.
    public var speaker: Int?
    /// Two or more people were talking at once.
    public var overlap: Bool

    public init(range: TimeRange, speaker: Int?, overlap: Bool = false) {
        self.range = range
        self.speaker = speaker
        self.overlap = overlap
    }
}

/// Who spoke when, plus one voice fingerprint per speaker so enrolled voices can be named.
public struct Diarization: Sendable {
    public var turns: [DiarizedTurn]
    /// Keyed by `DiarizedTurn.speaker`. A speaker without a centroid can't be named.
    public var centroids: [Int: SpeakerEmbedding]

    public init(turns: [DiarizedTurn], centroids: [Int: SpeakerEmbedding] = [:]) {
        self.turns = turns
        self.centroids = centroids
    }
}

/// Finds speech and says who spoke when. On device this is one model package
/// (e.g. pyannote via SpeakerKit); in the core it can also be composed from the
/// separate pillars (`SegmentAndClusterDiarizer`). Silence never becomes a turn.
public protocol Diarizer {
    func diarize(_ audio: AudioClip) async throws -> Diarization
}

// MARK: - Model lifecycle

/// A model that holds memory while loaded. The pipeline unloads each one as soon
/// as its phase is done, so only one large model is resident at a time.
public protocol ModelLifecycle: AnyObject {
    func unload() async
}
