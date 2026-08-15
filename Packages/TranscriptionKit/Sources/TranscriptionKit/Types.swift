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

    public var filename: String {
        switch self {
        case .largeV3Turbo: return "ggml-large-v3-turbo.bin"
        case .largeV3TurboQ5: return "ggml-large-v3-turbo-q5_0.bin"
        }
    }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    /// Pinned SHA-256 of the model file, verified at download time. Sourced from the Git
    /// LFS OID reported by huggingface.co/api/models/ggerganov/whisper.cpp/tree/main
    /// (Git LFS uses sha256 as its content hash, matching what ModelManager computes).
    public var expectedSHA256: String {
        switch self {
        case .largeV3Turbo: return "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        case .largeV3TurboQ5: return "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        }
    }

    public var displayName: String {
        switch self {
        case .largeV3Turbo: return "large-v3-turbo (1.6 GB, best quality)"
        case .largeV3TurboQ5: return "large-v3-turbo Q5 (574 MB, faster)"
        }
    }
}
