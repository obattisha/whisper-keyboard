// AVAudioConverter's input-supply closure is annotated @Sendable in the SDK but runs
// synchronously inside convert(to:error:), so capturing the non-Sendable input buffer
// there is safe. That, and only that, is what this @preconcurrency import covers. The tap
// block in installTap(feeding:) is deliberately not such a case: it runs on a realtime
// audio thread, so nothing inside it touches main-actor state. See UtteranceBuffer.
@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: "com.omar.whisperkeyboard", category: "audio")

public enum AudioRecorderError: Error, LocalizedError {
    case microphonePermissionDenied
    case inputUnavailable(underlying: Error)

    /// Deliberately short and human-readable: this string goes straight into the menu bar,
    /// which used to show a raw CoreAudio dump ("Error Domain=com.apple.coreaudio.avfaudio
    /// Code=-10868 (null) ... AUGraphParser::InitializeActiveNodesInInputChain").
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .inputUnavailable(let underlying):
            // -10868 is kAudioUnitErr_FormatNotSupported: the engine and the audio hardware
            // disagree about sample rate. start() already rebuilds and retries once, so
            // reaching here means the input is genuinely unusable rather than just stale.
            let isFormatMismatch = (underlying as NSError).code == -10868
            return isFormatMismatch
                ? "Mic format not supported. Try reselecting your input device."
                : "Microphone unavailable"
        }
    }
}

/// Collects one utterance's worth of converted samples.
///
/// A fresh instance is created per recording, and the tap block is its only writer, which
/// is what keeps this safe: the converter fields below are touched exclusively from the
/// audio thread, and `samples` is the single hand-off point back to the main thread.
///
/// This exists as a separate, non-isolated type because `AudioRecorder` is `@MainActor`
/// and the tap block is not. Calling a main-actor method from there compiles (the module
/// is imported `@preconcurrency`) but does not hop threads: it runs the body on the audio
/// thread, racing the main thread's reads of the same array. That race silently dropped
/// whole utterances, because an array that read as empty at stop time looked exactly like
/// "the user did not say anything".
private final class UtteranceBuffer: @unchecked Sendable {
    /// Reserved up front so the steady state appends into existing capacity rather than
    /// reallocating while the lock is held. 60 seconds at 16kHz, about 3.8MB.
    private static let reservedFrames = Int(AudioRecorder.whisperSampleRate) * 60

    private let samples = OSAllocatedUnfairLock<[Float]>(initialState: [])
    private let targetFormat: AVAudioFormat

    // Audio thread only. No synchronization needed: one buffer per recording means the tap
    // block is the sole writer for this instance's whole lifetime.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
        samples.withLock { $0.reserveCapacity(Self.reservedFrames) }
    }

    /// Takes everything captured so far. Called once, from the main thread, after the tap
    /// has been removed.
    func drain() -> [Float] {
        samples.withLock { current in
            let captured = current
            current = []
            return captured
        }
    }

    func consume(buffer: AVAudioPCMBuffer) {
        // Rebuild the converter whenever the incoming format actually changes: the first
        // buffer of a recording, or any buffer after a mid-recording headset mode switch
        // (belt-and-suspenders alongside the configuration-change notification in
        // AudioRecorder, in case a format shift shows up in the buffers before that
        // notification fires).
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

        // Resampling above is the expensive part and is deliberately outside the lock, so
        // the audio thread holds it for nothing more than a memcpy-append.
        //
        // `withLockUnchecked` rather than `withLock` because the latter's closure is
        // @Sendable, which `frames` (an UnsafeBufferPointer into `outputBuffer`) cannot
        // satisfy. Copying it into an Array first just to satisfy that would add a heap
        // allocation per audio buffer on the realtime thread. The pointer is valid for the
        // whole of this call and never escapes the closure, which is the condition the
        // unchecked variant exists for.
        samples.withLockUnchecked { $0.append(contentsOf: frames) }
    }
}

/// Captures microphone audio while running and exposes it as accumulated mono 16kHz
/// Float32 samples, the format whisper.cpp expects. Designed for short hold-to-talk
/// utterances: recording is entirely in-memory (no disk buffering).
@MainActor
public final class AudioRecorder {
    // nonisolated because UtteranceBuffer reads this from the audio thread. It is an
    // immutable Double, so there is nothing for the main actor to protect.
    public nonisolated static let whisperSampleRate: Double = 16_000

    /// Guard against accidental taps producing near-empty buffers: very short clips can
    /// cause whisper to hallucinate text rather than return nothing.
    private static let minimumDuration: TimeInterval = 0.3

    // The *output* format is fixed: this is what whisper.cpp requires, not a guess about
    // the microphone. What must never be hardcoded is the *input* side (see start()).
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.whisperSampleRate,
        channels: 1,
        interleaved: false
    )!

    // Not a `let`: a device switch that happens while idle can only be picked up by
    // building a new engine. See start().
    private var engine = AVAudioEngine()
    private var utterance: UtteranceBuffer?
    private var configChangeObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    public init() {}

    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Starts capturing. Throws if microphone permission has not been granted: call
    /// `requestMicrophonePermission()` (and handle a `false` result in the UI) before
    /// wiring this to a hotkey.
    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.microphonePermissionDenied
        }

        // macOS has no AVAudioSession: mic routing there is governed purely by TCC
        // authorization (checked above) plus AVAudioEngine's own input node. iOS requires
        // this activation step first, or engine.start() throws.
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioRecorderError.inputUnavailable(underlying: error)
        }
        #endif

        restartTask?.cancel()
        restartTask = nil

        let buffer = UtteranceBuffer(targetFormat: targetFormat)
        utterance = buffer

        // An AVAudioEngine caches the input hardware's format the first time `inputNode` is
        // touched, and only re-resolves it while the engine is running (that is what
        // AVAudioEngineConfigurationChange reports). A single long-lived engine therefore
        // stayed pinned to whichever device was default at app launch, so connecting
        // Bluetooth headphones *between* utterances (the common case, since you put them on
        // while the app is idle) left the engine asserting the built-in mic's 48kHz against
        // headphones running at 24kHz. Every start() after that failed with -10868, and
        // stayed failing until the app was relaunched. Standing up a fresh engine per
        // utterance costs a few milliseconds, is negligible next to model inference, and
        // always resolves against the device that is actually current.
        do {
            try startEngine(feeding: buffer)
        } catch {
            // The default device can also change in the window between building the engine
            // and starting it. One rebuild-and-retry covers that race without spinning on
            // an input that is genuinely unusable.
            do {
                try startEngine(feeding: buffer)
            } catch {
                utterance = nil
                throw AudioRecorderError.inputUnavailable(underlying: error)
            }
        }

        recordingStartedAt = Date()
    }

    private func startEngine(feeding buffer: UtteranceBuffer) throws {
        removeConfigChangeObserver()
        engine.stop()
        engine = AVAudioEngine()

        installTap(feeding: buffer)

        // Bluetooth headphones switch profile the instant the mic is engaged, from A2DP
        // (output-only) to a headset mode that can carry input too, at a different rate
        // (8kHz, 16kHz or 24kHz, mono). That switch lands a couple of hundred milliseconds
        // into the hold, and this notification is how the engine reports it.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// AVAudioEngine does not merely report a hardware format change, it *stops itself* in
    /// response to one. Reinstalling the tap is therefore not enough on its own: without an
    /// explicit restart the engine sat stopped for the remainder of every hold, which is
    /// what made dictation through Bluetooth headphones capture nothing at all.
    ///
    ///     Engine@0x...: start, was running 0      <- hold begins
    ///     Engine@0x...: stop,  was running 1      <- 215ms later, the profile switch
    ///     (silence for the rest of the hold)
    private func handleConfigurationChange() {
        guard let buffer = utterance else { return } // not recording; nothing to preserve
        if engine.isRunning {
            // Format moved but the engine survived it. The tap still has to be reinstalled
            // so that `format: nil` re-resolves against what the hardware is now doing.
            logger.notice("configuration changed while running, reinstalling tap")
            installTap(feeding: buffer)
            return
        }
        logger.notice("configuration changed and engine stopped, restarting")
        scheduleRestart(feeding: buffer)
    }

    /// Brings the engine back up against the device's new format, retrying briefly.
    ///
    /// The device is still renegotiating when the notification arrives (CoreAudio logs a
    /// burst of -10877 "channel layout" errors right through the switch), so an immediate
    /// start() can legitimately fail. Backing off and retrying recovers the rest of the
    /// hold instead of abandoning it. The samples already captured are kept: `buffer`
    /// outlives the engine, so audio from before and after the switch both land in the
    /// same utterance.
    private func scheduleRestart(feeding buffer: UtteranceBuffer) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            for delayMilliseconds in [0, 120, 300, 600] {
                if delayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * NSEC_PER_MSEC)
                }
                // Bail out if the hold ended, or a later utterance already took over.
                guard !Task.isCancelled, let self, self.utterance === buffer else { return }
                if self.engine.isRunning { return }
                do {
                    try self.startEngine(feeding: buffer)
                    logger.notice("engine restarted after configuration change")
                    return
                } catch {
                    logger.error("restart attempt failed: \(String(describing: error), privacy: .public)")
                }
            }
            logger.error("gave up restarting the engine after a configuration change")
        }
    }

    /// (Re)installs the tap against the input node's *current* native format. Deliberately
    /// does not assert a specific sample rate or channel count: passing `nil` makes the
    /// engine hand back buffers in whatever the hardware is doing, and
    /// `UtteranceBuffer.consume(buffer:)` builds its converter from that live format rather
    /// than a cached one. Note that `nil` is resolved against the *engine's* view of the
    /// input node, which is why the engine itself has to be current (see start()).
    private func installTap(feeding buffer: UtteranceBuffer) {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcmBuffer, _ in
            buffer.consume(buffer: pcmBuffer)
        }
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// Stops capturing and returns the accumulated samples, or nil if the hold was too
    /// short to be a real utterance or produced no audio at all.
    public func stopAndCapture() -> [Float]? {
        restartTask?.cancel()
        restartTask = nil
        removeConfigChangeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        let finished = utterance
        utterance = nil

        guard let finished else { return nil }
        let samples = finished.drain()
        guard duration >= Self.minimumDuration, !samples.isEmpty else { return nil }
        return samples
    }
}
