import AVFoundation

enum AudioDuration {
    /// Length of an audio file in seconds, or 0 if it can't be read.
    static func of(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
