import Foundation

public enum LanguageHint: String, Codable, CaseIterable, Sendable {
    case auto
    case english
    case arabic

    /// The ISO 639-1 code whisper.cpp expects, or nil for auto-detect.
    var whisperLanguageCode: String? {
        switch self {
        case .auto: return nil
        case .english: return "en"
        case .arabic: return "ar"
        }
    }
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let detectedLanguage: String?
}

public enum TranscriptionError: Error {
    case modelNotLoaded
    case contextInitializationFailed
    case transcriptionFailed
}

public enum WhisperModelVariant: String, Codable, CaseIterable, Sendable {
    case largeV3Turbo = "large-v3-turbo"
    case largeV3TurboQ5 = "large-v3-turbo-q5_0"
    case distilLargeV3 = "distil-large-v3"

    public var filename: String {
        switch self {
        case .largeV3Turbo: return "ggml-large-v3-turbo.bin"
        case .largeV3TurboQ5: return "ggml-large-v3-turbo-q5_0.bin"
        case .distilLargeV3: return "ggml-distil-large-v3.bin"
        }
    }

    /// Distil-Whisper ships its own ggml conversion under a separate Hugging Face repo
    /// (distil-whisper/distil-large-v3-ggml), not ggerganov/whisper.cpp where the standard
    /// Whisper variants live.
    private var huggingFaceRepo: String {
        switch self {
        case .largeV3Turbo, .largeV3TurboQ5: return "ggerganov/whisper.cpp"
        case .distilLargeV3: return "distil-whisper/distil-large-v3-ggml"
        }
    }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main/\(filename)")!
    }

    /// Pinned SHA-256 of the model file, verified at download time. Sourced from each
    /// variant's Git LFS OID (huggingface.co/api/models/<repo>/tree/main) — Git LFS uses
    /// sha256 as its content hash, matching what ModelManager computes.
    public var expectedSHA256: String {
        switch self {
        case .largeV3Turbo: return "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        case .largeV3TurboQ5: return "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        case .distilLargeV3: return "2883a11b90fb10ed592d826edeaee7d2929bf1ab985109fe9e1e7b4d2b69a298"
        }
    }

    public var displayName: String {
        switch self {
        case .largeV3Turbo: return "large-v3-turbo (1.6 GB, best quality)"
        case .largeV3TurboQ5: return "large-v3-turbo Q5 (574 MB, faster)"
        case .distilLargeV3: return "distil-large-v3 (1.5 GB, ~5x faster, English-only)"
        }
    }

    /// Whether this variant was trained on languages beyond English. Forcing a
    /// LanguageHint the model can't actually do (e.g. Arabic into an English-only model)
    /// pushes a language token whisper.cpp doesn't understand rather than gracefully
    /// falling back, so the UI uses this to keep that combination from being selectable.
    public var isMultilingual: Bool {
        switch self {
        case .largeV3Turbo, .largeV3TurboQ5: return true
        case .distilLargeV3: return false
        }
    }
}
