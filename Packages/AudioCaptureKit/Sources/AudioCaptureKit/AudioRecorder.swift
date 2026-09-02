// AVAudioConverter's input-supply closure is annotated @Sendable in the SDK but runs
// synchronously inside convert(to:error:), so capturing the non-Sendable input buffer there
// is safe. That, and only that, is what this @preconcurrency import covers. Capture
// callbacks below run on a realtime audio thread and deliberately touch no main-actor state.
@preconcurrency import AVFoundation
import CoreAudio
import os

private let logger = Logger(subsystem: "com.omar.whisperkeyboard", category: "audio")

public enum AudioRecorderError: Error, LocalizedError {
    case microphonePermissionDenied
    case inputUnavailable(underlying: Error)
    case inputDeviceUnavailable
    case coreAudio(status: OSStatus, operation: String)

    /// Deliberately short and human-readable: this string goes straight into the menu bar,
    /// which used to show a raw CoreAudio dump.
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .inputDeviceUnavailable:
            return "No microphone available"
        case .coreAudio:
            return "Microphone unavailable"
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
/// A separate, non-isolated type because `AudioRecorder` is `@MainActor` and the capture
/// callback is not. Calling a main-actor method from that callback compiles (the module is
/// imported `@preconcurrency`) but does not hop threads: it runs the body on the audio
/// thread, racing the main thread's reads. That race silently dropped whole utterances.
final class SampleStore: @unchecked Sendable {
    private struct Storage {
        var samples: [Float] = []
        var hasReceivedAudio = false
        var onFirstBuffer: (@Sendable () -> Void)?
    }

    private let storage = OSAllocatedUnfairLock<Storage>(initialState: Storage())

    /// Called on the main queue the first time real audio lands, which is the only honest
    /// signal that capture is live. Nothing polls for it.
    func setFirstBufferHandler(_ handler: (@Sendable () -> Void)?) {
        storage.withLock { $0.onFirstBuffer = handler }
    }

    /// Audio thread.
    func append(_ frames: UnsafeBufferPointer<Float>) {
        guard !frames.isEmpty else { return }
        let notify: (@Sendable () -> Void)? = storage.withLockUnchecked { state in
            state.samples.append(contentsOf: frames)
            guard !state.hasReceivedAudio else { return nil }
            state.hasReceivedAudio = true
            return state.onFirstBuffer
        }
        // Dispatched outside the lock, and only ever once per recording.
        if let notify { DispatchQueue.main.async(execute: notify) }
    }

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

/// Identity of the current default input. A Bluetooth headset entering microphone mode
/// changes its nominal sample rate, and may replace its streams more than once on the way,
/// so this is how "still renegotiating" is told from "settled".
struct InputDeviceState: Equatable {
    var deviceID: AudioDeviceID
    var sampleRate: Double

    static func current() -> InputDeviceState? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        var sampleRate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate) == noErr,
              sampleRate > 0 else { return nil }
        return InputDeviceState(deviceID: deviceID, sampleRate: sampleRate)
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

#if os(macOS)

/// Input-only capture through an AUHAL audio unit bound to a specific device.
///
/// Replaces `AVAudioEngine` on macOS for one reason: `AVAudioEngine.inputNode` silently
/// stands up an aggregate device with *both* an input and an output stream, even for an app
/// that never plays anything. The logs showed it configuring a 2ch 24kHz output render
/// format on a pair of headphones we only ever recorded from. That phantom output is what
/// drags AirPods into call quality even when an app is recording from an entirely different
/// microphone, and it gave the device more to renegotiate during the Bluetooth profile
/// switch than it needed.
///
/// AUHAL with output disabled opens exactly one stream on exactly one device. It also takes
/// the client format directly, so the 16kHz mono conversion whisper needs happens inside
/// CoreAudio rather than in an AVAudioConverter we drive ourselves, and there is no cached
/// engine-side format to go stale (the -10868 loop).
private final class AUHALCapture: @unchecked Sendable {
    private var unit: AudioUnit?
    private let store: SampleStore
    /// Cleared before teardown so a callback still in flight cannot touch freed buffers.
    private let active = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Preallocated: the render callback must not allocate.
    private static let maximumFramesPerSlice: UInt32 = 4096
    private static let frameCapacity: AVAudioFrameCount = 16_384
    private var bufferList: UnsafeMutableAudioBufferListPointer
    private let targetFormat: AVAudioFormat
    /// Hardware-rate mono, rendered into directly by the callback.
    private var hardwareBuffer: AVAudioPCMBuffer?
    /// 16kHz mono, the format whisper wants.
    private var resampledBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var loggedRenderFailure = false

    init(store: SampleStore, targetFormat: AVAudioFormat) {
        self.store = store
        self.targetFormat = targetFormat
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
    }

    deinit {
        free(bufferList.unsafeMutablePointer)
    }

    func open(deviceID: AudioDeviceID) throws {
        close()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecorderError.inputDeviceUnavailable
        }

        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "AudioComponentInstanceNew")
        guard let newUnit else { throw AudioRecorderError.inputDeviceUnavailable }
        unit = newUnit

        // Input on, output off. The second half is the entire point of this class.
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(
            newUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size)
        ), "EnableIO(input)")

        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(
            newUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size)
        ), "EnableIO(output)")

        // Bound explicitly, rather than following whatever the system default becomes.
        var device = deviceID
        try check(AudioUnitSetProperty(
            newUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        ), "CurrentDevice")

        var maximumFrames = Self.maximumFramesPerSlice
        try check(AudioUnitSetProperty(
            newUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maximumFrames, UInt32(MemoryLayout<UInt32>.size)
        ), "MaximumFramesPerSlice")

        // Ask the hardware what rate it is actually running at, and take exactly that.
        //
        // Setting 16kHz here instead, and letting AUHAL resample, is what broke the first
        // attempt at this: its input element does not reliably sample-rate convert, and
        // `inNumberFrames` in the callback counts *hardware* frames, so AudioUnitRender was
        // being handed a frame count in one rate and a buffer in another. It failed
        // silently and every hold captured nothing. Match the hardware, resample below.
        var hardwareFormat = AudioStreamBasicDescription()
        var hardwareFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(
            newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
            &hardwareFormat, &hardwareFormatSize
        ), "StreamFormat(hardware)")

        let hardwareSampleRate = hardwareFormat.mSampleRate > 0
            ? hardwareFormat.mSampleRate
            : AudioRecorder.whisperSampleRate

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: hardwareSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(AudioUnitSetProperty(
            newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "StreamFormat")

        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: hardwareSampleRate,
            channels: 1, interleaved: false
        ),
        let hardwareBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: Self.frameCapacity),
        let resampledBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: Self.frameCapacity),
        let converter = AVAudioConverter(from: captureFormat, to: targetFormat) else {
            throw AudioRecorderError.inputDeviceUnavailable
        }
        self.hardwareBuffer = hardwareBuffer
        self.resampledBuffer = resampledBuffer
        self.converter = converter
        loggedRenderFailure = false
        logger.notice("capture opened at \(hardwareSampleRate, privacy: .public) Hz, resampling to 16000")

        var callback = AURenderCallbackStruct(
            inputProc: auhalInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            newUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "SetInputCallback")

        try check(AudioUnitInitialize(newUnit), "AudioUnitInitialize")
        active.withLock { $0 = true }
        do {
            try check(AudioOutputUnitStart(newUnit), "AudioOutputUnitStart")
        } catch {
            active.withLock { $0 = false }
            throw error
        }
    }

    func close() {
        // Order matters: stop the callback from doing anything, then stop IO (which waits
        // for an in-flight callback to return), then tear the unit down.
        active.withLock { $0 = false }
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        hardwareBuffer = nil
        resampledBuffer = nil
        converter = nil
    }

    /// Audio thread.
    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard active.withLock({ $0 }), let unit,
              let hardwareBuffer, let resampledBuffer, let converter else { return noErr }
        guard frames <= Self.frameCapacity, let hardwareChannels = hardwareBuffer.floatChannelData else {
            return noErr
        }

        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: frames * 4,
            mData: UnsafeMutableRawPointer(hardwareChannels[0])
        )

        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            // Logged once so a silent capture failure is visible without flooding the log
            // from a realtime callback.
            if !loggedRenderFailure {
                loggedRenderFailure = true
                logger.error("AudioUnitRender failed: \(status, privacy: .public)")
            }
            return status
        }

        hardwareBuffer.frameLength = frames
        resampledBuffer.frameLength = 0

        var supplied = false
        let result = converter.convert(to: resampledBuffer, error: nil) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return hardwareBuffer
        }
        guard result != .error, let resampled = resampledBuffer.floatChannelData else { return noErr }

        store.append(UnsafeBufferPointer(start: resampled[0], count: Int(resampledBuffer.frameLength)))
        return noErr
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        logger.error("\(operation, privacy: .public) failed: \(status, privacy: .public)")
        throw AudioRecorderError.coreAudio(status: status, operation: operation)
    }
}

/// Top-level so it is a plain C function pointer, which AURenderCallbackStruct requires.
private func auhalInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<AUHALCapture>.fromOpaque(inRefCon).takeUnretainedValue()
        .render(flags: ioActionFlags, timestamp: inTimeStamp, bus: inBusNumber, frames: inNumberFrames)
}

/// Watches CoreAudio for the events that actually invalidate a capture.
///
/// This replaces a supervisor that polled every 25ms and inferred trouble from timeouts:
/// "no audio for 600ms means stalled", "1.5s is how long a cold Bluetooth open takes".
/// Those numbers were guesses about someone else's hardware, and the tighter one was
/// actively harmful, declaring a healthy-but-slow start dead and rebuilding on top of it.
/// CoreAudio will say when the sample rate changes, when IO stops abnormally, when the
/// streams are replaced, and when the default input moves. Waiting to be told costs nothing
/// and is never wrong about timing.
private final class DeviceChangeObserver {
    private struct Registration {
        var objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private var registrations: [Registration] = []
    private let queue = DispatchQueue(label: "com.omar.whisperkeyboard.device-events")

    func observe(deviceID: AudioDeviceID, onChange: @escaping @Sendable (String, Bool) -> Void) {
        stop()
        // The Bool is whether the event alone justifies rebuilding. A rate or stream change
        // is only interesting if it left us on something different from what we opened
        // against; IO stopping abnormally is unconditional.
        let targets: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, String, Bool)] = [
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
             kAudioObjectPropertyScopeGlobal, "default input device changed", false),
            (deviceID, kAudioDevicePropertyNominalSampleRate,
             kAudioObjectPropertyScopeGlobal, "nominal sample rate changed", false),
            (deviceID, kAudioDevicePropertyStreamConfiguration,
             kAudioDevicePropertyScopeInput, "input streams changed", false),
            (deviceID, kAudioDevicePropertyIOStoppedAbnormally,
             kAudioObjectPropertyScopeGlobal, "IO stopped abnormally", true),
        ]

        for (objectID, selector, scope, reason, forces) in targets {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange(reason, forces) }
            guard AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) == noErr else {
                continue
            }
            registrations.append(Registration(objectID: objectID, address: address, block: block))
        }
    }

    func stop() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                registration.objectID, &address, queue, registration.block
            )
        }
        registrations.removeAll()
    }

    deinit { stop() }
}

#else

/// iOS keeps AVAudioEngine: AUHAL is macOS-only, and the phantom-output problem it solves
/// does not arise here.
private final class EngineCapture: @unchecked Sendable {
    private let store: SampleStore
    private let targetFormat: AVAudioFormat
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let active = OSAllocatedUnfairLock<Bool>(initialState: false)

    init(store: SampleStore, targetFormat: AVAudioFormat) {
        self.store = store
        self.targetFormat = targetFormat
    }

    func open() throws {
        close()
        let newEngine = AVAudioEngine()
        engine = newEngine
        active.withLock { $0 = true }
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.consume(buffer: buffer)
        }
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            active.withLock { $0 = false }
            throw AudioRecorderError.inputUnavailable(underlying: error)
        }
    }

    func close() {
        active.withLock { $0 = false }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        converterInputFormat = nil
    }

    private func consume(buffer: AVAudioPCMBuffer) {
        guard active.withLock({ $0 }) else { return }
        if converter == nil || !(converterInputFormat?.isEqual(to: buffer.format) ?? false) {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channelData = output.floatChannelData else { return }
        store.append(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }
}

#endif

/// Captures microphone audio and exposes it as mono 16kHz Float32 samples, the format
/// whisper.cpp expects. Designed for short hold-to-talk utterances: recording is entirely
/// in-memory, never buffered to disk, and the microphone closes the moment the key is
/// released.
@MainActor
public final class AudioRecorder {
    // nonisolated because the capture path reads this from the audio thread. It is an
    // immutable Double, so there is nothing for the main actor to protect.
    public nonisolated static let whisperSampleRate: Double = 16_000

    /// Guard against accidental taps: very short clips make whisper hallucinate text rather
    /// than return nothing.
    private static let minimumDuration: TimeInterval = 0.3
    /// Bound on recovery attempts within one hold, so nothing can loop indefinitely.
    private static let maximumRebuilds = 3
    /// How long device events must stop arriving before a rebuild is attempted.
    ///
    /// Not a guess about how long any hardware takes. CoreAudio emits a *burst* of property
    /// changes while a device reconfigures, and rebuilding on the first one lands on a state
    /// that is about to change again. Each new event restarts this window, so the wait
    /// lasts exactly as long as the device keeps changing, however long that is, rather
    /// than a duration hardcoded from someone else's headphones.
    private static let eventCoalescingWindow: TimeInterval = 0.12

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.whisperSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let store = SampleStore()
    private var rebuildTask: Task<Void, Never>?
    private var isRecording = false
    private var recordingStartedAt: Date?
    private var openedDeviceState: InputDeviceState?
    private var rebuildCount = 0
    private var pendingForcedRebuild = false

    #if os(macOS)
    private let deviceObserver = DeviceChangeObserver()
    #endif

    #if os(macOS)
    private lazy var capture = AUHALCapture(store: store, targetFormat: targetFormat)
    #else
    private lazy var capture = EngineCapture(store: store, targetFormat: targetFormat)
    #endif

    /// Fires on the main actor the first time real audio actually reaches the capture path.
    ///
    /// Starting the unit returning success is not the same moment: on a Bluetooth headset
    /// the first buffer can be most of a second later, and capture can even be torn down and
    /// rebuilt in between. Showing "Recording" through that gap is what invited speaking
    /// into an input that was not live yet, losing the first words.
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
        store.setFirstBufferHandler { [weak self] in
            Task { @MainActor [weak self] in
                logger.notice("first audio buffer received")
                self?.onCaptureBegan?()
            }
        }
        rebuildCount = 0
        pendingForcedRebuild = false
        isRecording = true

        do {
            try openInput()
        } catch {
            isRecording = false
            capture.close()
            throw error
        }

        recordingStartedAt = Date()
    }

    /// Stops capturing, closes the microphone, and returns the samples, or nil if the hold
    /// was too short to be real or produced no audio at all.
    public func stopAndCapture() -> [Float]? {
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        isRecording = false

        stopObserving()
        capture.close()
        openedDeviceState = nil

        let samples = store.drain()
        guard duration >= Self.minimumDuration, !samples.isEmpty else { return nil }
        return samples
    }

    /// Closes the microphone immediately. Called on app termination.
    public func teardown() {
        isRecording = false
        recordingStartedAt = nil
        stopObserving()
        capture.close()
        openedDeviceState = nil
    }

    private func stopObserving() {
        rebuildTask?.cancel()
        rebuildTask = nil
        store.setFirstBufferHandler(nil)
        #if os(macOS)
        deviceObserver.stop()
        #endif
    }

    // MARK: - Input lifecycle

    private func openInput() throws {
        #if os(macOS)
        guard let deviceID = InputDeviceState.defaultInputDeviceID() else {
            throw AudioRecorderError.inputDeviceUnavailable
        }
        try capture.open(deviceID: deviceID)
        openedDeviceState = InputDeviceState.current()
        deviceObserver.observe(deviceID: deviceID) { [weak self] reason, forcesRebuild in
            Task { @MainActor [weak self] in
                self?.deviceDidChange(reason: reason, forcesRebuild: forcesRebuild)
            }
        }
        #else
        try capture.open()
        openedDeviceState = InputDeviceState.current()
        #endif
    }

    /// CoreAudio reported something that may have invalidated capture.
    private func deviceDidChange(reason: String, forcesRebuild: Bool) {
        guard isRecording else { return }
        logger.notice("device event: \(reason, privacy: .public)")
        if forcesRebuild { pendingForcedRebuild = true }
        scheduleRebuild()
    }

    /// Rebuilds capture once the device has stopped changing.
    ///
    /// Every new event restarts the window, so this waits precisely as long as the hardware
    /// takes and no longer. There is no timeout on how slow a device is allowed to be: the
    /// only bound is the user releasing the key.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.eventCoalescingWindow * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            guard self.rebuildCount < Self.maximumRebuilds else {
                logger.error("refusing to rebuild capture again this recording")
                return
            }

            // A rate or stream event that left us on the same device at the same rate
            // changed nothing we depend on, so there is nothing to rebuild. Only IO
            // stopping abnormally is unconditional.
            let deviceMoved = InputDeviceState.current() != self.openedDeviceState
            guard deviceMoved || self.pendingForcedRebuild else {
                logger.notice("device event settled back to the state we opened against")
                return
            }
            self.pendingForcedRebuild = false

            self.rebuildCount += 1
            do {
                try self.openInput()
                logger.notice("capture rebuilt (rebuild \(self.rebuildCount, privacy: .public))")
            } catch {
                logger.error("rebuild failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

}
