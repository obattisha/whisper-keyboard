import Foundation
import whisper

/// Thread-confined wrapper over the whisper.cpp C API (whisper.cpp requires the
/// context not be accessed from more than one thread at a time — hence `actor`).
public actor WhisperEngine {
    private var context: OpaquePointer?
    private let modelPath: String

    public init(modelPath: String) {
        self.modelPath = modelPath
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    /// Loads the model into memory. Call once at app launch (or on model switch);
    /// this is the slow step (disk read + Metal pipeline setup), not per-utterance.
    public func loadModel() throws {
        var params = whisper_context_default_params()
        params.flash_attn = true // enabled by default for Metal
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriptionError.contextInitializationFailed
        }
        context = ctx
    }

    public func transcribe(samples: [Float], languageHint: LanguageHint) throws -> TranscriptionResult {
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
