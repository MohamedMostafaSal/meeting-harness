import Foundation

/// Thresholds for deciding who spoke (D3). Plain values, like `RouterPolicy`.
public struct SpeakerPolicy: Sendable {
    /// Two clusters with at least this average similarity are the same voice.
    public var clusterThreshold: Double
    /// A cluster must be at least this similar to an enrolled voice to take its name.
    public var enrollmentThreshold: Double
    /// Turns shorter than this are too short for a trustworthy voice fingerprint.
    public var minEmbeddingDuration: Double

    public init(clusterThreshold: Double = 0.7, enrollmentThreshold: Double = 0.75, minEmbeddingDuration: Double = 0.5) {
        self.clusterThreshold = clusterThreshold
        self.enrollmentThreshold = enrollmentThreshold
        self.minEmbeddingDuration = minEmbeddingDuration
    }
}

public struct SpeakerLabel: Equatable, Sendable {
    public var id: SpeakerID
    public var name: String?

    public init(id: SpeakerID, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// Voices the user has enrolled, e.g. the phone owner during onboarding.
/// Enrolled voices anchor speaker identity across meetings.
public struct SpeakerRegistry: Codable, Equatable, Sendable {
    public struct Enrolled: Codable, Equatable, Sendable {
        public var id: SpeakerID
        public var name: String
        public var embedding: SpeakerEmbedding
    }

    public private(set) var enrolled: [Enrolled] = []

    public init() {}

    /// Adds a voice, replacing any earlier enrollment with the same id.
    public mutating func enroll(_ id: SpeakerID, name: String, embedding: SpeakerEmbedding) {
        enrolled.removeAll { $0.id == id }
        enrolled.append(Enrolled(id: id, name: name, embedding: embedding))
    }
}

public enum SpeakerClustering {
    /// Average-linkage agglomerative clustering on cosine similarity. Returns a
    /// cluster number per input, numbered in order of first appearance.
    public static func agglomerate(_ embeddings: [SpeakerEmbedding], threshold: Double) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        var similarity = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in i..<n {
                let s = embeddings[i].similarity(to: embeddings[j])
                similarity[i][j] = s
                similarity[j][i] = s
            }
        }

        var clusters: [[Int]] = (0..<n).map { [$0] }
        while clusters.count > 1 {
            var best = (a: 0, b: 0, score: -Double.infinity)
            for a in 0..<clusters.count {
                for b in (a + 1)..<clusters.count {
                    var total: Double = 0
                    for i in clusters[a] { for j in clusters[b] { total += similarity[i][j] } }
                    let score = total / Double(clusters[a].count * clusters[b].count)
                    if score > best.score { best = (a, b, score) }
                }
            }
            guard best.score >= threshold else { break }
            clusters[best.a] += clusters[best.b]
            clusters.remove(at: best.b)
        }

        var result = [Int](repeating: 0, count: n)
        for (number, members) in clusters.sorted(by: { $0.min()! < $1.min()! }).enumerated() {
            for i in members { result[i] = number }
        }
        return result
    }
}

public enum SpeakerAssignment {
    /// Decides who spoke each turn.
    ///
    /// - `embeddings[i]` is nil when turn `i` has no usable fingerprint (too short): it gets no label.
    /// - `reliable[i]` is false for overlapped turns: they never shape the clusters, and only
    ///   join one if their fingerprint is clearly close to it.
    ///
    /// Clusters that match an enrolled voice take its id and name. The rest are
    /// numbered S1, S2… in order of first appearance.
    public static func assign(
        _ embeddings: [SpeakerEmbedding?],
        reliable: [Bool],
        registry: SpeakerRegistry,
        policy: SpeakerPolicy
    ) -> [SpeakerLabel?] {
        precondition(embeddings.count == reliable.count, "one reliability flag per embedding")

        let anchors = embeddings.indices.filter { embeddings[$0] != nil && reliable[$0] }
        let numbers = SpeakerClustering.agglomerate(anchors.map { embeddings[$0]! }, threshold: policy.clusterThreshold)
        let clusterCount = (numbers.max() ?? -1) + 1
        let centroids: [SpeakerEmbedding] = (0..<clusterCount).map { c in
            SpeakerEmbedding.centroid(anchors.indices.filter { numbers[$0] == c }.map { embeddings[anchors[$0]]! })!
        }

        let labels = label(centroids, registry: registry, policy: policy)

        var result = [SpeakerLabel?](repeating: nil, count: embeddings.count)
        for (k, i) in anchors.enumerated() { result[i] = labels[numbers[k]] }
        for i in embeddings.indices where !reliable[i] {
            guard let embedding = embeddings[i] else { continue }
            let scored = centroids.indices.map { (cluster: $0, score: embedding.similarity(to: centroids[$0])) }
            if let best = scored.max(by: { $0.score < $1.score }), best.score >= policy.clusterThreshold {
                result[i] = labels[best.cluster]
            }
        }
        return result
    }

    /// Names clusters: one-to-one with enrolled voices (most similar pairs first), then S1, S2…
    static func label(_ centroids: [SpeakerEmbedding], registry: SpeakerRegistry, policy: SpeakerPolicy) -> [SpeakerLabel] {
        var pairs: [(cluster: Int, enrolled: Int, score: Double)] = []
        for c in centroids.indices {
            for e in registry.enrolled.indices {
                let score = centroids[c].similarity(to: registry.enrolled[e].embedding)
                if score >= policy.enrollmentThreshold { pairs.append((c, e, score)) }
            }
        }
        var matched: [Int: Int] = [:]
        var usedEnrolled = Set<Int>()
        for pair in pairs.sorted(by: { $0.score > $1.score }) where matched[pair.cluster] == nil && !usedEnrolled.contains(pair.enrolled) {
            matched[pair.cluster] = pair.enrolled
            usedEnrolled.insert(pair.enrolled)
        }

        let taken = Set(registry.enrolled.map { $0.id })
        var next = 1
        return centroids.indices.map { c in
            if let e = matched[c] {
                return SpeakerLabel(id: registry.enrolled[e].id, name: registry.enrolled[e].name)
            }
            var id = SpeakerID("S\(next)")
            while taken.contains(id) { next += 1; id = SpeakerID("S\(next)") }
            next += 1
            return SpeakerLabel(id: id)
        }
    }
}

extension Transcript {
    /// Applies a user rename to every segment by that speaker.
    public mutating func renameSpeaker(_ id: SpeakerID, to name: String) {
        for i in segments.indices where segments[i].speaker == id {
            segments[i].speakerName = name
        }
    }
}
