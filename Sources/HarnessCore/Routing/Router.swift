/// The tunable conditions the router decides by. Plain values, so every
/// decision can be logged, reproduced and unit-tested.
public struct RouterPolicy: Sendable {
    /// Below this, a language guess is not trusted.
    public var languageConfidenceThreshold: Double
    /// Window length used to re-identify an ambiguous segment (code-switching).
    public var splitWindow: Double
    /// Below this, a transcribed segment is kept but marked uncertain.
    public var recognitionConfidenceThreshold: Double
    /// Which specialist variant to prefer per language, e.g. Egyptian for Arabic.
    public var preferredVariants: [LanguageCode: String]

    public init(
        languageConfidenceThreshold: Double = 0.75,
        splitWindow: Double = 1.0,
        recognitionConfidenceThreshold: Double = 0.5,
        preferredVariants: [LanguageCode: String] = [.arabic: "egyptian"]
    ) {
        self.languageConfidenceThreshold = languageConfidenceThreshold
        self.splitWindow = splitWindow
        self.recognitionConfidenceThreshold = recognitionConfidenceThreshold
        self.preferredVariants = preferredVariants
    }
}

public enum RouteDecision: Equatable, Sendable {
    /// Confident language and a specialist is installed for it.
    case specialist(ModelInfo, language: LanguageCode)
    /// Use the multilingual model. The hint is nil when no guess is trusted.
    case fallback(ModelInfo, languageHint: LanguageCode?)
    /// Language is ambiguous: re-identify in windows of this length, then route each part.
    case split(window: Double)
    /// Nothing installed can handle this. Becomes a `Gap`, never silently dropped.
    case unroutable(reason: String)
}

/// D5: decides which speech-to-text model handles a segment. Deterministic, no models.
public struct Router: Sendable {
    public var policy: RouterPolicy
    public var installed: [RecognizerDescriptor]

    public init(policy: RouterPolicy, installed: [RecognizerDescriptor]) {
        self.policy = policy
        self.installed = installed
    }

    public func route(_ guesses: [LanguageGuess], duration: Double, allowSplit: Bool = true) -> RouteDecision {
        if let top = guesses.top, top.confidence >= policy.languageConfidenceThreshold {
            if let specialist = specialist(for: top.language) {
                return .specialist(specialist.model, language: top.language)
            }
            return fallback(hint: top.language, reason: "no specialist installed for \(top.language)")
        }
        if allowSplit && duration >= 2 * policy.splitWindow {
            return .split(window: policy.splitWindow)
        }
        return fallback(hint: nil, reason: "language uncertain")
    }

    /// The installed specialist for `language`, preferring the policy's variant.
    public func specialist(for language: LanguageCode) -> RecognizerDescriptor? {
        let candidates = installed.filter { !$0.isMultilingual && $0.languages.contains(language) }
        if let wanted = policy.preferredVariants[language],
           let match = candidates.first(where: { $0.variant == wanted }) {
            return match
        }
        return candidates.first
    }

    private func fallback(hint: LanguageCode?, reason: String) -> RouteDecision {
        guard let multilingual = installed.first(where: { $0.isMultilingual }) else {
            return .unroutable(reason: "\(reason); no multilingual fallback installed")
        }
        return .fallback(multilingual.model, languageHint: hint)
    }

    /// Cuts `range` into windows of `size`, folding a trailing sliver into the last window.
    public static func windows(_ range: TimeRange, size: Double) -> [TimeRange] {
        precondition(size > 0, "window size must be positive")
        var result: [TimeRange] = []
        var t = range.start
        while t < range.end {
            var end = min(t + size, range.end)
            if range.end - end < size / 2 { end = range.end }
            result.append(TimeRange(start: t, end: end))
            t = end
        }
        return result
    }
}
