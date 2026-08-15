import Foundation
import CryptoKit

public enum ModelManagerError: Error {
    case checksumMismatch
    case downloadFailed
}

/// Downloads and verifies ggml model files into Application Support, outside the app bundle
/// and outside git (models are large binaries fetched on first run, never committed).
public actor ModelManager {
    public static let shared = ModelManager()

    public struct DownloadProgress: Sendable {
        public let bytesWritten: Int64
        public let totalBytes: Int64
    }

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("WhisperKeyboard/Models", isDirectory: true)
    }

    public func localURL(for variant: WhisperModelVariant) -> URL {
        modelsDirectory.appendingPathComponent(variant.filename)
    }

    public func isDownloaded(_ variant: WhisperModelVariant) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: variant).path)
    }

    /// Downloads `variant` if not already present, verifying its SHA-256 against the pinned
    /// digest in `WhisperModelVariant.expectedSHA256`. Deletes and throws on mismatch rather
    /// than silently proceeding with a possibly-corrupt model.
    public func download(
        _ variant: WhisperModelVariant,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        if isDownloaded(variant) { return }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destination = localURL(for: variant)
        let downloadedTempURL = try await DownloadTask.run(url: variant.downloadURL, onProgress: onProgress)

        let digest = try Self.sha256(ofFileAt: downloadedTempURL)
        guard digest == variant.expectedSHA256 else {
            try? FileManager.default.removeItem(at: downloadedTempURL)
            throw ModelManagerError.checksumMismatch
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedTempURL, to: destination)
    }

    private static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Wraps a delegate-based URLSessionDownloadTask in async/await so progress callbacks
/// (which only exist via the delegate API, not the async `bytes(from:)`/`download(from:)`
/// convenience methods) can still reach the caller.
private final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (ModelManager.DownloadProgress) -> Void
    private let continuation: CheckedContinuation<URL, Error>

    private init(
        onProgress: @escaping @Sendable (ModelManager.DownloadProgress) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.onProgress = onProgress
        self.continuation = continuation
    }

    static func run(
        url: URL,
        onProgress: @escaping @Sendable (ModelManager.DownloadProgress) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = DownloadTask(onProgress: onProgress, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: task, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(ModelManager.DownloadProgress(bytesWritten: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted by the system as soon as this delegate method returns,
        // so move it to a stable temp location synchronously before resuming.
        let stableLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        do {
            try FileManager.default.moveItem(at: location, to: stableLocation)
            continuation.resume(returning: stableLocation)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        }
    }
}
