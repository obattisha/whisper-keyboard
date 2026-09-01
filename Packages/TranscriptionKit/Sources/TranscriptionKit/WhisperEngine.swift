import Foundation
import whisper

/// Serialized wrapper over the whisper.cpp C API.
///
/// whisper.cpp requires that its context not be touched from more than one thread at a
/// time. This was an `actor`, which serialized correctly but had two problems. It ran
/// inference on Swift's cooperative thread pool, where a multi-second, fully CPU-bound
/// `whisper_full` call occupies one of the small number of threads the rest of the app's
/// async work also draws from. And actors are re-entrant, so awaiting inside a transcribe
/// call would have let a second one interleave. A dedicated serial queue gives the same
/// mutual exclusion, keeps the work off the shared pool, and cannot interleave.
public final class WhisperEngine: @unchecked Sendable {
    /// Every access to `context` happens on this queue, which is what makes the
    /// `@unchecked Sendable` conformance above sound.
    private let queue = DispatchQueue(label: "com.omar.whisperkeyboard.whisper", qos: .userInitiated)
    private var context: OpaquePointer?
    private let modelPath: String

    public init(modelPath: String) {
        self.modelPath = modelPath
    }

    deinit {
        // Safety net for an engine dropped mid-life (a model switch). The app's own exit
        // path goes through shutdown() instead, for the reason documented there.
        if let context {
            whisper_free(context)
        }
    }

    /// Loads the model into memory. Call once at app launch (or on model switch);
    /// this is the slow step (disk read + Metal pipeline setup), not per-utterance.
    public func loadModel() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var params = whisper_context_default_params()
                params.flash_attn = true // enabled by default for Metal
                guard let ctx = whisper_init_from_file_with_params(self.modelPath, params) else {
                    continuation.resume(throwing: TranscriptionError.contextInitializationFailed)
                    return
                }
                self.context = ctx
                continuation.resume()
            }
        }
    }

    /// Releases the whisper context and every Metal resource it owns, synchronously.
    ///
    /// This has to happen while the app is still alive. whisper.cpp's Metal backend keeps
    /// a process-global residency set whose destructor asserts that everything has been
    /// handed back first (ggml-metal-device.m):
    ///
    ///     // note: if you hit this assert, most likely you haven't deallocated all Metal
    ///     // resources before exiting
    ///     GGML_ASSERT([rsets->data count] == 0);
    ///
    /// Nothing used to release the context before `exit()` ran that destructor: the engine
    /// was owned by StatusItemController, which lives until the process dies, so `deinit`
    /// never got a chance to run. Every single quit therefore ended in `Abort trap: 6` and
    /// a crash report. Called from `applicationWillTerminate`, before AppKit exits.
    public func shutdown() {
        queue.sync {
            if let context {
                whisper_free(context)
                self.context = nil
            }
        }
    }

    public func transcribe(samples: [Float], languageHint: LanguageHint) async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try self.run(samples: samples, languageHint: languageHint))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Must only be called on `queue`.
    private func run(samples: [Float], languageHint: LanguageHint) throws -> TranscriptionResult {
        guard let context else {
            throw TranscriptionError.modelNotLoaded
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))

        // withCString's closure-scoped pointer must stay alive through whisper_full,
        // so the call happens inside the withCString closure below.
        let languageCode = languageHint.whisperLanguageCode

        func runFull(languagePointer: UnsafePointer<CChar>?) -> Int32 {
            var p = params
            p.language = languagePointer
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, p, buffer.baseAddress, Int32(buffer.count))
            }
        }

        let status: Int32
        if let languageCode {
            status = languageCode.withCString { runFull(languagePointer: $0) }
        } else {
            status = runFull(languagePointer: nil)
        }

        guard status == 0 else {
            throw TranscriptionError.transcriptionFailed
        }

        var text = ""
        let segmentCount = whisper_full_n_segments(context)
        for i in 0..<segmentCount {
            text += String(cString: whisper_full_get_segment_text(context, i))
        }

        let detectedLangID = whisper_full_lang_id(context)
        let detectedLanguage = detectedLangID >= 0 ? String(cString: whisper_lang_str(detectedLangID)) : nil

        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLanguage
        )
    }
}
