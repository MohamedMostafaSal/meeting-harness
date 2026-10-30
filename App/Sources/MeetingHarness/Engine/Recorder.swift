import AVFoundation
import Observation

/// Records a meeting with one microphone capture that does two things: writes the
/// audio file, and keeps the last 30 s as 16 kHz samples for live captions.
/// Keeps recording with the screen locked and pauses cleanly on interruptions.
@MainActor
@Observable
final class Recorder {
    enum State: Equatable { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels, 0…1, newest last.
    private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    private(set) var interrupted = false
    private(set) var fileURL: URL?
    /// The live sample feed, for captions.
    let live = LiveBuffer(seconds: 30)

    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let writer = AudioFileWriter()

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.couldNotStart
        }
        try writer.open(url: url, format: target)
        live.reset()

        let writer = self.writer, live = self.live
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            writer.write(out)
            live.append(samples)
        }
        engine.prepare()
        try engine.start()

        self.engine = engine
        fileURL = url
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        state = .recording
        interrupted = false
        startTimer()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.engine?.pause()
                self.state = .paused
                self.interrupted = true
            }
        }
    }

    func pause() {
        engine?.pause()
        state = .paused
    }

    func resume() {
        guard (try? engine?.start()) != nil else { return }
        state = .recording
        interrupted = false
    }

    /// Stops and returns the recording's file and length.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let engine, let fileURL else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.engine = nil
        state = .idle
        return (fileURL, live.totalSeconds)
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
        guard state == .recording else { return }
        elapsed = live.totalSeconds
        // RMS of the last 50 ms, -60…0 dB mapped to 0…1 and eased so speech fills the meter.
        let rms = live.rms(lastSeconds: 0.05)
        let db = max(-60, 20 * log10(max(rms, 1e-6)))
        levels.removeFirst()
        levels.append(min(1, pow(10, db / 40) * 1.4))
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone couldn't start. Close other apps using it and try again." }
    }
}

/// Writes converted buffers to an AAC file from the audio thread.
final class AudioFileWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let lock = NSLock()

    func open(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock { self.file = file }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { try? file?.write(from: buffer) }
    }

    func close() {
        lock.withLock { file = nil }
    }
}

/// The most recent stretch of 16 kHz audio, plus how much has been recorded in total.
/// Written from the audio thread, read by the captioner.
final class LiveBuffer: @unchecked Sendable {
    static let sampleRate = 16_000
    private let capacity: Int
    private var samples: [Float] = []
    private var total = 0
    private let lock = NSLock()

    init(seconds: Int) { capacity = seconds * Self.sampleRate }

    func reset() { lock.withLock { samples = []; total = 0 } }

    func append(_ new: [Float]) {
        lock.withLock {
            samples.append(contentsOf: new)
            total += new.count
            if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        }
    }

    /// Total samples recorded since start.
    var totalSamples: Int { lock.withLock { total } }
    var totalSeconds: TimeInterval { Double(totalSamples) / Double(Self.sampleRate) }

    /// Samples from absolute index `from` to now, if still buffered.
    func samples(from: Int) -> (samples: [Float], start: Int) {
        lock.withLock {
            let bufferStart = total - samples.count
            let begin = max(from, bufferStart)
            return (Array(samples[(begin - bufferStart)...]), begin)
        }
    }

    func rms(lastSeconds: Double) -> Float {
        lock.withLock {
            let n = min(samples.count, Int(lastSeconds * Double(Self.sampleRate)))
            guard n > 0 else { return 0 }
            var sum: Float = 0
            for x in samples[(samples.count - n)...] { sum += x * x }
            return (sum / Float(n)).squareRoot()
        }
    }
}
