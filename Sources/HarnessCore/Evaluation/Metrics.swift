import Foundation

/// Normalizes text before scoring (D11), so spelling variants don't count as errors.
///
/// Arabic folding: drops diacritics and tatweel, unifies alef forms (أ إ آ ٱ → ا),
/// taa marbuta (ة → ه) and alef maqsura (ى → ي), and maps Arabic-Indic digits to 0–9.
public struct TextNormalizer: Sendable {
    public var lowercase: Bool
    public var stripPunctuation: Bool
    public var foldArabic: Bool

    public init(lowercase: Bool = true, stripPunctuation: Bool = true, foldArabic: Bool = true) {
        self.lowercase = lowercase
        self.stripPunctuation = stripPunctuation
        self.foldArabic = foldArabic
    }

    public func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in (lowercase ? text.lowercased() : text).unicodeScalars {
            let v = scalar.value
            if foldArabic {
                if (0x064B...0x065F).contains(v) || v == 0x0670 || v == 0x0640 { continue }
                if let folded = Self.arabicFolds[v] { out.append(folded); continue }
                if (0x0660...0x0669).contains(v) { out.append(Unicode.Scalar(UInt8(0x30 + v - 0x0660))); continue }
                if (0x06F0...0x06F9).contains(v) { out.append(Unicode.Scalar(UInt8(0x30 + v - 0x06F0))); continue }
            }
            if stripPunctuation && CharacterSet.punctuationCharacters.contains(scalar) { continue }
            out.append(scalar)
        }
        return String(out).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let arabicFolds: [UInt32: Unicode.Scalar] = [
        0x0623: "\u{0627}", 0x0625: "\u{0627}", 0x0622: "\u{0627}", 0x0671: "\u{0627}",
        0x0629: "\u{0647}",
        0x0649: "\u{064A}",
    ]
}

public struct ErrorRate: Equatable, Sendable {
    public var errors: Int
    public var referenceLength: Int

    public init(errors: Int, referenceLength: Int) {
        self.errors = errors
        self.referenceLength = referenceLength
    }

    public var rate: Double {
        guard referenceLength > 0 else { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceLength)
    }
}

public enum Metrics {
    /// Levenshtein distance: substitutions + insertions + deletions.
    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// WER: word-level edit distance over normalized text.
    public static func wordErrorRate(reference: String, hypothesis: String, normalizer: TextNormalizer = TextNormalizer()) -> ErrorRate {
        let ref = normalizer.normalize(reference).split(separator: " ").map(String.init)
        let hyp = normalizer.normalize(hypothesis).split(separator: " ").map(String.init)
        return ErrorRate(errors: editDistance(ref, hyp), referenceLength: ref.count)
    }

    /// CER: character-level edit distance over normalized text, ignoring spaces.
    /// The primary metric for Arabic, where word boundaries vary between spellings.
    public static func characterErrorRate(reference: String, hypothesis: String, normalizer: TextNormalizer = TextNormalizer()) -> ErrorRate {
        let ref = Array(normalizer.normalize(reference).filter { $0 != " " })
        let hyp = Array(normalizer.normalize(hypothesis).filter { $0 != " " })
        return ErrorRate(errors: editDistance(ref, hyp), referenceLength: ref.count)
    }
}
