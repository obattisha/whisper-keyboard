// AVAudioConverter's input-supply closure is annotated @Sendable in the SDK but runs
// synchronously inside convert(to:error:), so capturing the non-Sendable input buffer there
// is safe. That, and only that, is what this @preconcurrency import covers. The tap block
// in installTap() is deliberately not such a case: it runs on a realtime audio thread, so
// nothing inside it touches main-actor state. See SampleStore.
@preconcurrency import AVFoundation
import CoreAudio
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
            let isFormatMismatch = (underlying as NSError).code == -10868
            return isFormatMismatch
                ? "Mic format not supported. Try reselecting your input device."
                : "Microphone unavailable"
        }
    }
}

/// Sample storage shared between the audio thread and the main actor.
///
/// A separate, non-isolated type because `AudioRecorder` is `@MainActor` and the tap block
/// is not. Calling a main-actor method from the tap compiles (the module is imported
/// `@preconcurrency`) but does not hop threads: it runs the body on the audio thread, racing
/// the main thread's reads. That race silently dropped whole utterances.
private final class SampleStore: @unchecked Sendable {
    private struct Storage {
        var samples: [Float] = []
        /// Set by the audio thread the first time real audio lands. The UI waits for this
        /// rather than for `engine.start()` returning, which is not the same moment.
        var hasReceivedAudio = false
    }

    private let storage = OSAllocatedUnfairLock<Storage>(initialState: Storage())

    /// Audio thread.
    func append(_ frames: UnsafeBufferPointer<Float>) {
        guard !frames.isEmpty else { return }
        storage.withLockUnchecked { state in
            state.hasReceivedAudio = true
            state.samples.append(contentsOf: frames)
        }
    }

    var hasReceivedAudio: Bool { storage.withLock { $0.hasReceivedAudio } }

    func reset() {
        storage.withLock { state in
            state.samples.removeAll(keepingCapacity: true)
            state.hasReceivedAudio = false
        }
    }

    func drain() -> [Float] {
        storage.withLock { state in
            let captured = state.samples
            state.samples = []
            return captured
        }
    }
}

/// Resamples tap buffers to whisper's format and hands them to the store. One instance per
/// engine, so the converter fields are written only by that engine's tap thread.
private final class TapConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let store: SampleStore
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    /// Cleared when the owning engine is retired, so a tap callback still in flight from an
    /// engine we have already replaced cannot inject audio into the next recording.
    private let active = OSAllocatedUnfairLock<Bool>(initialState: true)

    init(targetFormat: AVAudioFormat, store: SampleStore) {
        self.targetFormat = targetFormat
        self.store = store
    }

    func retire() { active.withLock { $0 = false } }

    func consume(buffer: AVAudioPCMBuffer) {
        guard active.withLock({ $0 }) else { return }

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
        store.append(frames)
    }
}

/// Identity of the current default input, used to tell "the device is still renegotiating"
/// from "the device has settled". A Bluetooth headset entering microphone mode changes its
/// nominal sample rate, and may replace its streams more than once on the way.
private struct InputDeviceState: Equatable {
    var deviceID: AudioDeviceID
    var sampleRate: Double

    static func current() -> InputDeviceState? {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var sampleRate = Double(0)
        var rateSize = UInt32(MemoryLayout<Double>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &rateAddress, 0, nil, &rateSize, &sampleRate
        ) == noErr, sampleRate > 0 else { return nil }

        return InputDeviceState(deviceID: deviceID, sampleRate: sampleRate)
    }
}

/// Captures microphone audio and exposes it as mono 16kHz Float32 samples, the format
/// whisper.cpp expects. Designed for short hold-to-talk utterances: recording is entirely
/// in-memory, never buffered to disk, and the microphone is closed the moment the key is
/// released.
@MainActor
public final class AudioRecorder {
    // nonisolated because TapConverter reads this from the audio thread. It is an immutable
    // Double, so there is nothing for the main actor to protect.
    public nonisolated static let whisperSampleRate: Double = 16_000

    /// Guard against accidental taps: very short clips make whisper hallucinate text rather
    /// than return nothing.
    private static let minimumDuration: TimeInterval = 0.3
    /// How long the device's identity and sample rate must hold still before we trust it.
    private static let deviceSettleDuration: TimeInterval = 0.25
    /// Ceiling on waiting for a device to settle, so a genuinely broken input still fails.
    private static let deviceSettleTimeout: TimeInterval = 3.0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.whisperSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let store = SampleStore()
    private var engine: AVAudioEngine?
    private var tap: TapConverter?
    private var configChangeObserver: NSObjectProtocol?
    private var supervisorTask: Task<Void, Never>?
    private var isRecording = false
    private var recordingStartedAt: Date?
    private var rebuildCount = 0

    /// Fires on the main actor the first time real audio actually reaches the tap.
    ///
    /// `engine.start()` returning is not the same moment: on a Bluetooth headset the first
    /// buffer can be most of a second later, and the recording can even be torn down and
    /// rebuilt in between. Showing "Recording" off `start()` therefore invited speaking into
    /// an input that was not live yet, which is exactly how the first words went missing.
    public var onCaptureBegan: (@MainActor () -> Void)?

    public init() {}

    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Starts capturing. Throws if microphone permission has not been granted: call
    /// `requestMicrophonePermission()` (and handle a `false` result in the UI) first.
    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.microphonePermissionDenied
        }

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioRecorderError.inputUnavailable(underlying: error)
        }
        #endif

        store.reset()
        rebuildCount = 0
        isRecording = true

        do {
            try openInput()
        } catch {
            isRecording = false
            closeInput()
            throw AudioRecorderError.inputUnavailable(underlying: error)
        }

        recordingStartedAt = Date()
        superviseInput()
    }

    /// Stops capturing, closes the microphone, and returns the samples, or nil if the hold
    /// was too short to be real or produced no audio at all.
    public func stopAndCapture() -> [Float]? {
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        isRecording = false

        // Closed immediately rather than held open: the microphone indicator going out is
        // how you know the recording ended, and this app's usage is one-and-done rather
        // than back-to-back, so nothing is gained by keeping the device warm.
        closeInput()

        let samples = store.drain()
        guard duration >= Self.minimumDuration, !samples.isEmpty else { return nil }
        return samples
    }

    /// Closes the microphone immediately. Called on app termination.
    public func teardown() {
        isRecording = false
        recordingStartedAt = nil
        closeInput()
    }

    // MARK: - Input lifecycle

    /// Opens the microphone: builds an engine, installs the tap, and starts it.
    ///
    /// A *new* AVAudioEngine every time, deliberately. An engine caches the input hardware's
    /// format the first time `inputNode` is touched, and `installTap(format: nil)` resolves
    /// against that cached value rather than against the hardware. So a reused engine keeps
    /// asserting the format it first saw: after a headset switches from 48kHz to 24kHz,
    /// every `start()` on that same engine fails with -10868 forever.
    private func openInput() throws {
        closeInput()

        let newEngine = AVAudioEngine()
        let newTap = TapConverter(targetFormat: targetFormat, store: store)
        engine = newEngine
        tap = newTap

        let inputNode = newEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            newTap.consume(buffer: buffer)
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: nil
        ) { _ in
            // Deliberately empty of recovery logic. This notification arrives roughly 450ms
            // after the engine has already stopped itself, which is far too late to be the
            // trigger for anything. superviseInput() watches `isRunning` instead.
            logger.notice("configuration change notification (informational)")
        }

        newEngine.prepare()
        try newEngine.start()
    }

    private func closeInput() {
        supervisorTask?.cancel()
        supervisorTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        tap?.retire()
        tap = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Watches the input for the duration of a hold, rebuilding it when it stops.
    ///
    /// Engaging the microphone makes a Bluetooth headset leave A2DP for a mode that can
    /// carry input, at a different sample rate. AVAudioEngine responds to that by stopping
    /// itself, and the recording is dead from then on unless something notices.
    ///
    /// Getting the recovery *timing* right is the whole problem. Rebuilding the instant the
    /// engine stops fed back on itself, because tearing an engine down releases the headset
    /// back to A2DP and building a new one drags it into microphone mode again: six restarts
    /// in five seconds, with the microphone indicator visibly blinking. Not rebuilding at
    /// all, and merely restarting the same engine, fails permanently with -10868 because
    /// that engine has the pre-switch sample rate cached.
    ///
    /// So: wait for the device to hold still, then rebuild exactly once.
    private func superviseInput() {
        supervisorTask?.cancel()
        supervisorTask = Task { @MainActor [weak self] in
            var announcedCapture = false

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25 * NSEC_PER_MSEC)
                guard !Task.isCancelled, let self, self.isRecording else { return }

                if !announcedCapture, self.store.hasReceivedAudio {
                    announcedCapture = true
                    logger.notice("first audio buffer received")
                    self.onCaptureBegan?()
                }

                guard let engine = self.engine, !engine.isRunning else { continue }

                logger.notice("input stopped, waiting for the device to settle")
                guard await self.waitForSettledInputDevice(), !Task.isCancelled,
                      let self = Optional(self), self.isRecording else { return }

                self.rebuildCount += 1
                do {
                    try self.openInput()
                    logger.notice("input rebuilt after device settled (rebuild \(self.rebuildCount, privacy: .public))")
                } catch {
                    logger.error("rebuild failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Polls the default input device until its identity and nominal sample rate have been
    /// unchanged for `deviceSettleDuration`. Returns false if it never settles.
    ///
    /// This is the piece that was missing. Rebuilding while the headset is still
    /// renegotiating just produces another engine pinned to a rate that is about to change
    /// again; waiting first means one rebuild lands on the format the device actually
    /// settled on.
    private func waitForSettledInputDevice() async -> Bool {
        var lastSeen = InputDeviceState.current()
        var unchangedSince = Date()
        let deadline = Date().addingTimeInterval(Self.deviceSettleTimeout)

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 40 * NSEC_PER_MSEC)
            if Task.isCancelled { return false }

            let now = InputDeviceState.current()
            if now != lastSeen {
                lastSeen = now
                unchangedSince = Date()
                continue
            }
            if now != nil, Date().timeIntervalSince(unchangedSince) >= Self.deviceSettleDuration {
                return true
            }
        }
        logger.error("input device never settled")
        return false
    }
}
