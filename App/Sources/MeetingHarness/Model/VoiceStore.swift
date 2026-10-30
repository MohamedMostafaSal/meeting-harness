import Foundation
import HarnessCore
import Observation

/// Enrolled voices (the speaker registry), saved in Application Support.
/// Fingerprints never leave the phone.
@MainActor
@Observable
final class VoiceStore {
    private(set) var registry = SpeakerRegistry()
    private let url: URL

    init(directory: URL? = nil) {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("voices.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SpeakerRegistry.self, from: data) {
            registry = saved
        }
    }

    var voices: [SpeakerRegistry.Enrolled] { registry.enrolled }

    func enroll(name: String, embedding: SpeakerEmbedding) {
        let id = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        registry.enroll(SpeakerID(id.isEmpty ? "voice-\(UUID().uuidString.prefix(6))" : id), name: name, embedding: embedding)
        save()
    }

    func remove(_ id: SpeakerID) {
        var updated = SpeakerRegistry()
        for voice in registry.enrolled where voice.id != id {
            updated.enroll(voice.id, name: voice.name, embedding: voice.embedding)
        }
        registry = updated
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(registry) { try? data.write(to: url, options: .atomic) }
    }
}
