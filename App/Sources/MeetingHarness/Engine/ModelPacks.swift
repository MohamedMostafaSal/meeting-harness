import Foundation
import Observation
import SpeakerKit
import WhisperKit

/// Downloadable model packs. Each is one job, so users only fetch what their meetings need.
enum ModelPack: String, CaseIterable, Identifiable, Codable {
    /// Who spoke when: pyannote segmentation + speaker fingerprints (SpeakerKit).
    case speakers
    /// Language ID, and the fallback for languages without a specialist.
    case multilingual
    case english
    case arabic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speakers: return "Speakers"
        case .multilingual: return "Language detection"
        case .english: return "English"
        case .arabic: return "Arabic"
        }
    }

    var purpose: String {
        switch self {
        case .speakers: return "Finds speech and tells voices apart."
        case .multilingual: return "Hears which language each sentence is in. Also transcribes German and French."
        case .english: return "Transcribes English."
        case .arabic: return "Transcribes Arabic. A general model until the Egyptian one is ready."
        }
    }

    var systemImage: String {
        switch self {
        case .speakers: return "person.2.wave.2"
        case .multilingual: return "globe"
        case .english: return "textformat.abc"
        case .arabic: return "character.book.closed.ar"
        }
    }

    /// WhisperKit variant in argmaxinc/whisperkit-coreml; nil for SpeakerKit.
    var whisperVariant: String? {
        switch self {
        case .speakers: return nil
        case .multilingual: return "openai_whisper-base"
        case .english: return "openai_whisper-small.en"
        case .arabic: return "openai_whisper-small"
        }
    }

    /// Packs a meeting in these languages can't be transcribed without.
    static func required(for languages: [String]) -> [ModelPack] {
        var packs: [ModelPack] = [.speakers, .multilingual]
        if languages.contains("en") { packs.append(.english) }
        if languages.contains("ar") { packs.append(.arabic) }
        return packs
    }
}

/// Downloads, tracks and deletes model packs under Application Support/Models.
@MainActor
@Observable
final class ModelManager {
    enum State: Equatable {
        case missing
        case downloading(Double?)
        case ready(bytes: Int64)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    private(set) var states: [ModelPack: State] = [:]
    let root: URL
    private let defaults: UserDefaults

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("Models", isDirectory: true)
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        refresh()
    }

    /// Where a ready pack lives on disk.
    func folder(for pack: ModelPack) -> URL? {
        guard let relative = defaults.string(forKey: "model.\(pack.rawValue)") else { return nil }
        let url = root.appendingPathComponent(relative, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isReady(_ pack: ModelPack) -> Bool { states[pack]?.isReady ?? false }

    func missing(for languages: [String]) -> [ModelPack] {
        ModelPack.required(for: languages).filter { !isReady($0) }
    }

    func refresh() {
        for pack in ModelPack.allCases {
            if case .downloading = states[pack] { continue }
            if let folder = folder(for: pack) {
                states[pack] = .ready(bytes: Self.size(of: folder))
            } else {
                states[pack] = .missing
            }
        }
    }

    func download(_ pack: ModelPack) async {
        if case .downloading = states[pack] { return }
        states[pack] = .downloading(nil)
        do {
            let folder: URL
            if let variant = pack.whisperVariant {
                folder = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: root,
                    from: "argmaxinc/whisperkit-coreml",
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in self.states[pack] = .downloading(fraction) }
                    })
            } else {
                // SpeakerKit downloads on init; find the repo folder it wrote so later
                // runs load it offline.
                let base = root.appendingPathComponent("speakers", isDirectory: true)
                _ = try await SpeakerKit(PyannoteConfig(downloadBase: base.path, download: true, load: false, verbose: false))
                guard let repo = Self.findFolder(named: "speakerkit-coreml", under: base) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                folder = repo
            }
            let relative = folder.path.replacingOccurrences(of: root.path + "/", with: "")
            defaults.set(relative, forKey: "model.\(pack.rawValue)")
            states[pack] = .ready(bytes: Self.size(of: folder))
        } catch {
            states[pack] = .failed(error.localizedDescription)
        }
    }

    func downloadAll(_ packs: [ModelPack]) async {
        for pack in packs where !isReady(pack) { await download(pack) }
    }

    func delete(_ pack: ModelPack) {
        if let folder = folder(for: pack) { try? FileManager.default.removeItem(at: folder) }
        defaults.removeObject(forKey: "model.\(pack.rawValue)")
        states[pack] = .missing
    }

    static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .isRegularFileKey]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileAllocatedSize ?? 0) }
        }
        return total
    }

    static func findFolder(named name: String, under base: URL) -> URL? {
        let items = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = items?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }
}
