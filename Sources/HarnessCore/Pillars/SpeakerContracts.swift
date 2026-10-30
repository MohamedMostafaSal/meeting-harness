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
