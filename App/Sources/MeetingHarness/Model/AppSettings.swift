import Foundation
import HarnessCore
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    /// The languages meetings are in. Language ID only chooses among these.
    var languages: [String] { didSet { save() } }
    var normalizeLoudness: Bool { didSet { save() } }
    /// Trust a language guess from this confidence.
    var languageConfidence: Double { didSet { save() } }
    /// Re-check mixed speech in windows of this length, seconds.
    var splitWindow: Double { didSet { save() } }
    /// Name an enrolled voice from this similarity.
    var voiceMatch: Double { didSet { save() } }
    var onboarded: Bool { didSet { save() } }

    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("ar", "Arabic (Egyptian)"), ("de", "German"), ("fr", "French"),
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        languages = defaults.stringArray(forKey: "languages") ?? ["en", "ar"]
        normalizeLoudness = defaults.object(forKey: "normalizeLoudness") as? Bool ?? true
        languageConfidence = defaults.object(forKey: "languageConfidence") as? Double ?? 0.75
        splitWindow = defaults.object(forKey: "splitWindow") as? Double ?? 2.0
        voiceMatch = defaults.object(forKey: "voiceMatch") as? Double ?? 0.6
        onboarded = defaults.bool(forKey: "onboarded")
    }

    var policy: PipelinePolicy {
        PipelinePolicy(
            router: RouterPolicy(languageConfidenceThreshold: languageConfidence, splitWindow: splitWindow),
            // SpeakerKit clusters voices itself; this threshold only names enrolled ones.
            speakers: SpeakerPolicy(enrollmentThreshold: voiceMatch),
            normalizeLoudness: normalizeLoudness)
    }

    private func save() {
        defaults.set(languages, forKey: "languages")
        defaults.set(normalizeLoudness, forKey: "normalizeLoudness")
        defaults.set(languageConfidence, forKey: "languageConfidence")
        defaults.set(splitWindow, forKey: "splitWindow")
        defaults.set(voiceMatch, forKey: "voiceMatch")
        defaults.set(onboarded, forKey: "onboarded")
    }
}
