import AVFoundation
import Observation

/// Records a meeting to AAC/m4a with live level metering. Keeps recording with the
/// screen locked (background audio) and pauses cleanly on interruptions like calls.
@MainActor
@Observable
final class Recorder: NSObject {
    enum State: Equatable { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels, 0…1, newest last.
    private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    private(set) var interrupted = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }
        self.recorder = recorder
        fileURL = url
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        state = .recording
        interrupted = false
        startTimer()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: session)
    }

    func pause() {
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard recorder?.record() == true else { return }
        state = .recording
        interrupted = false
    }

    /// Stops and returns the recording's file and length.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let fileURL else { return nil }
        let duration = recorder.currentTime > 0 ? recorder.currentTime : elapsed
        recorder.stop()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.recorder = nil
        state = .idle
        return (fileURL, duration)
    }

    /// Stops and deletes the recording.
    func discard() {
        if let result = stop() { try? FileManager.default.removeItem(at: result.url) }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // -60 dB…0 dB to 0…1, eased so speech fills the meter.
        let power = max(-60, recorder.averagePower(forChannel: 0))
        let level = pow(Float(10), power / 40)
        levels.removeFirst()
        levels.append(min(1, level * 1.4))
    }

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                if self.state == .recording { self.state = .paused; self.interrupted = true }
            case .ended:
                break
            @unknown default:
                break
            }
        }
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone couldn't start. Close other apps using it and try again." }
    }
}
