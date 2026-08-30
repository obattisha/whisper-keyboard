@preconcurrency import AVFoundation

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
    // The *output* format is fixed — this is what whisper.cpp requires, not a guess about
    // the microphone. What must never be hardcoded is the *input* side (see start()).
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.whisperSampleRate,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var configChangeObserver: NSObjectProtocol?
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

        converter = nil
        converterInputFormat = nil
        installTap()

        // Bluetooth headphones commonly switch profile the instant the mic is engaged —
        // from A2DP (~44.1/48kHz, output-only) to HFP "headset" mode (often 8kHz or
        // 16kHz, mono) so they can carry input too. That switch is asynchronous and can
        // still be mid-flight when start() reaches installTap() above, or can land after
        // recording has already begun. Either way the actual hardware format changes out
        // from under us; this notification is how the engine tells us that happened so we
        // can rebuild against whatever the new real format is, instead of crashing on a
        // stale one asserted up front.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.installTap()
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// (Re)installs the tap against the input node's *current* native format. Deliberately
    /// does not assert a specific sample rate/channel count here (the old code passed a
    /// format captured once at start()) — on a Bluetooth headset that format can already be
    /// stale by the time the engine actually starts, or go stale mid-recording, and
    /// asserting a mismatched one crashes. Passing `nil` makes the engine always hand back
    /// buffers in whatever the hardware is actually doing right now; `consume(buffer:)`
    /// builds the converter from that live format rather than a cached one.
    private func installTap() {
        let inputNode = engine.inputNode
        if engine.isRunning {
            inputNode.removeTap(onBus: 0)
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.consume(buffer: buffer)
        }
    }

    /// Guard against accidental taps producing near-empty buffers — very short clips can
    /// cause whisper to hallucinate text rather than return nothing.
    private static let minimumDuration: TimeInterval = 0.3

    /// Stops capturing and returns the accumulated samples, or nil if the hold was too
    /// short to be a real utterance.
    public func stopAndCapture() -> [Float]? {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        converterInputFormat = nil

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

    private func consume(buffer: AVAudioPCMBuffer) {
        // Rebuild the converter whenever the incoming format actually changes: the first
        // buffer of a recording, or any buffer after a mid-recording headset mode switch
        // (belt-and-suspenders alongside the configuration-change notification above, in
        // case a format shift shows up in the buffers before that notification fires).
        if converter == nil || !(converterInputFormat?.isEqual(to: buffer.format) ?? false) {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return }

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
