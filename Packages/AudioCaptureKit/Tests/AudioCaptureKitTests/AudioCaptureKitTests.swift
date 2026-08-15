import Testing
@testable import AudioCaptureKit

@Test func whisperSampleRateIsSixteenKilohertz() {
    #expect(AudioRecorder.whisperSampleRate == 16_000)
}
