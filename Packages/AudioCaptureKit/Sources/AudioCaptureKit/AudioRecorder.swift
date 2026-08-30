import AVFoundation

public enum AudioRecorderError: Error {
    case microphonePermissionDenied
    case converterInitializationFailed
    case converterFailed
}

/// Captures microphone audio while running and exposes it as accumulated mono 16kHz
/// Float32 samples — the format whisper.cpp expects. Designed for short hold-to-talk
/// utterances: recording is entirely in-memory (no disk buffering).
@MainActor
public final class AudioRecorder {
    public static let whisperSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var accumulatedSamples: [Float] = []
    private var recordingStartedAt: Date?

    public init() {}

    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Starts capturing. Throws if microphone permission has not been granted — call
    /// `requestMicrophonePermission()` (and handle a `false` result in the UI) before
    /// wiring this to a hotkey.
    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.microphonePermissionDenied
        }

        accumulatedSamples.removeAll(keepingCapacity: true)
        recordingStartedAt = Date()

        // macOS has no AVAudioSession — mic routing there is governed purely by TCC
        // authorization (checked above) plus AVAudioEngine's own input node. iOS requires
        // this activation step first, or engine.start() throws.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.whisperSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterInitializationFailed
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
    }

    /// Guard against accidental taps producing near-empty buffers — very short clips can
    /// cause whisper to hallucinate text rather than return nothing.
    private static let minimumDuration: TimeInterval = 0.3

    /// Stops capturing and returns the accumulated samples, or nil if the hold was too
    /// short to be a real utterance.
    public func stopAndCapture() -> [Float]? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        guard duration >= Self.minimumDuration, !accumulatedSamples.isEmpty else {
            accumulatedSamples.removeAll(keepingCapacity: true)
            return nil
        }

        defer { accumulatedSamples.removeAll(keepingCapacity: true) }
        return accumulatedSamples
    }

    private func consume(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var error: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channelData = outputBuffer.floatChannelData else { return }
        let frames = UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
        accumulatedSamples.append(contentsOf: frames)
    }
}
