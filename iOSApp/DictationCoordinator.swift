import Foundation
import TranscriptionKit
import AudioCaptureKit

/// Shared dictation state machine, driven by both the in-app UI and `DictateIntent`
/// (Action Button/Shortcuts). The Action Button only fixed-trigger-fires custom intents —
/// there's no "hold to record, release to stop" on iOS the way there is with a physical
/// hotkey on macOS — so both entry points converge on the same "start recording, wait for
/// an explicit stop" flow: `beginDictation()` starts recording and suspends until
/// `requestStop()` is called from the UI's Stop button, then transcribes and returns.
@MainActor
final class DictationCoordinator: ObservableObject {
    static let shared = DictationCoordinator()

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    /// iOS default: the smaller quantized model, since phone storage/RAM is more
    /// constrained than a Mac. Not user-configurable yet — a v2 concern.
    let modelVariant: WhisperModelVariant = .largeV3TurboQ5
    private let languageHint: LanguageHint = .auto

    /// Safety cap so a forgotten recording (e.g. app backgrounded mid-hold) doesn't run
    /// forever draining battery and holding the mic.
    private static let maxRecordingDuration: TimeInterval = 120

    @Published private(set) var state: State = .idle
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var isModelReady = false
    @Published private(set) var downloadProgress: Double?

    private let recorder = AudioRecorder()
    private var engine: WhisperEngine?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var safetyTimeoutTask: Task<Void, Never>?

    private init() {}

    // MARK: - Model lifecycle

    func refreshModelStatus() async {
        isModelReady = await ModelManager.shared.isDownloaded(modelVariant)
        if isModelReady {
            await loadEngineIfNeeded()
        }
    }

    func downloadModel() async {
        downloadProgress = 0
        do {
            try await ModelManager.shared.download(modelVariant) { progress in
                let fraction = progress.totalBytes > 0
                    ? Double(progress.bytesWritten) / Double(progress.totalBytes)
                    : 0
                Task { @MainActor in
                    self.downloadProgress = fraction
                }
            }
            downloadProgress = nil
            isModelReady = true
            await loadEngineIfNeeded()
        } catch {
            downloadProgress = nil
            state = .error("Model download failed: \(error.localizedDescription)")
        }
    }

    private func loadEngineIfNeeded() async {
        guard engine == nil else { return }
        let path = await ModelManager.shared.localURL(for: modelVariant).path
        let newEngine = WhisperEngine(modelPath: path)
        do {
            try await newEngine.loadModel()
            engine = newEngine
        } catch {
            state = .error("Failed to load model")
        }
    }

    // MARK: - Dictation flow

    /// Starts recording and suspends until `requestStop()` is called (or the safety
    /// timeout elapses), then transcribes and returns the result. Used by both the UI's
    /// Start button and `DictateIntent.perform()`.
    @discardableResult
    func beginDictation() async -> String? {
        switch state {
        case .idle:
            break
        case .error:
            // Same trap the macOS hotkey had: without this, one failed attempt left every
            // later tap a no-op, because nothing moved the state back out of `.error`.
            state = .idle
        case .recording, .transcribing:
            return nil
        }
        guard isModelReady else {
            state = .error("Model not downloaded")
            return nil
        }

        do {
            try recorder.start()
        } catch {
            state = .error(error.localizedDescription)
            return nil
        }
        state = .recording

        safetyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxRecordingDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.requestStop()
        }

        await withCheckedContinuation { continuation in
            self.stopContinuation = continuation
        }
        safetyTimeoutTask?.cancel()
        safetyTimeoutTask = nil

        return await stopAndTranscribe()
    }

    /// Signals a pending `beginDictation()` call to stop recording and transcribe.
    func requestStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func stopAndTranscribe() async -> String? {
        guard let samples = recorder.stopAndCapture() else {
            state = .idle
            return nil
        }
        state = .transcribing

        guard let engine else {
            state = .error("Model not loaded")
            return nil
        }
        do {
            let result = try await engine.transcribe(samples: samples, languageHint: languageHint)
            state = .idle
            guard !result.text.isEmpty else { return nil }
            lastTranscript = result.text
            return result.text
        } catch {
            state = .error("Transcription failed")
            return nil
        }
    }
}
