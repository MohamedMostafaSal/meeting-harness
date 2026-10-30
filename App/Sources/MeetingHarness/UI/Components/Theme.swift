import SwiftUI
import UIKit

/// The app's palette, taken from the logo: an ink neutral with a slight green
/// bias, a signal green for actions, and the strand colours for speakers.
enum Theme {
    static let ink = dynamic(light: 0x17201C, dark: 0xE6ECE9)
    static let paper = dynamic(light: 0xF4F5F2, dark: 0x0E1311)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x171E1B)
    static let rule = dynamic(light: 0xE1E5E1, dark: 0x26302B)
    static let signal = dynamic(light: 0x0F6B5C, dark: 0x3FB59E)
    static let record = dynamic(light: 0xC4322B, dark: 0xFF6B5F)
    static let warn = dynamic(light: 0x9A5B00, dark: 0xF0B45A)
    /// The recording screen is always dark, whatever the system theme.
    static let night = Color(hex: 0x0B100E)

    static let speakerColors: [Color] = [
        dynamic(light: 0x0F6B5C, dark: 0x3FB59E),
        dynamic(light: 0x7A3DB8, dark: 0xB18CF0),
        dynamic(light: 0xB5541C, dark: 0xF09A62),
        dynamic(light: 0x2F62B8, dark: 0x7AA6F5),
        dynamic(light: 0x8A7A12, dark: 0xD8C552),
        dynamic(light: 0xB83A76, dark: 0xF08CBA),
    ]

    /// A stable colour per speaker within a meeting (by order of appearance).
    static func color(forSpeakerAt index: Int?) -> Color {
        guard let index else { return .secondary }
        return speakerColors[index % speakerColors.count]
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

/// "04:07", or "1:04:07" past the first hour.
func clockString(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

/// "12 min", "1 h 05 min", "45 s".
func durationString(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "\(Int(seconds)) s" }
    let minutes = Int(seconds / 60)
    return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
}

func languageName(_ code: String) -> String {
    AppSettings.supportedLanguages.first { $0.code == code }?.name
        ?? Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
}

/// Arabic reads right to left; everything else here left to right.
func layoutDirection(for language: String?) -> LayoutDirection {
    ["ar", "fa", "he", "ur"].contains(language ?? "") ? .rightToLeft : .leftToRight
}
