import Foundation
import Testing
@testable import TranscriptionKit

@Test func transcribesJFKSample() async throws {
    // Requires a downloaded model at the standard ModelManager location — run
    // `Scripts/fetch-model.sh` first. Skips (rather than fails) if absent, so CI/fresh
    // checkouts without the 1.6GB model don't block on this test.
    let manager = ModelManager.shared
    guard await manager.isDownloaded(.largeV3Turbo) else {
        print("Skipping: model not downloaded, run Scripts/fetch-model.sh")
        return
    }
    let modelPath = await manager.localURL(for: .largeV3Turbo).path

    let fixtureURL = Bundle.module.url(forResource: "jfk", withExtension: "wav")!
    let samples = try loadMonoFloat32(wavURL: fixtureURL)

    let engine = WhisperEngine(modelPath: modelPath)
    try await engine.loadModel()
    let result = try await engine.transcribe(samples: samples, languageHint: .english)

    #expect(result.text.lowercased().contains("country"))
}

/// jfk.wav is already 16kHz mono PCM16 (whisper.cpp's own sample fixture), so this only
/// needs to parse the WAV header and convert Int16 -> Float32, no resampling.
private func loadMonoFloat32(wavURL: URL) throws -> [Float] {
    let data = try Data(contentsOf: wavURL)
    let headerSize = 44 // standard canonical WAV header
    let pcmData = data.subdata(in: headerSize..<data.count)
    let sampleCount = pcmData.count / MemoryLayout<Int16>.size
    var samples = [Float](repeating: 0, count: sampleCount)
    pcmData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let int16Buffer = raw.bindMemory(to: Int16.self)
        for i in 0..<sampleCount {
            samples[i] = Float(int16Buffer[i]) / Float(Int16.max)
        }
    }
    return samples
}
