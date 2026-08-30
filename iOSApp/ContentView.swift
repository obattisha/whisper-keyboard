import SwiftUI
import AVFoundation
import AudioCaptureKit

struct ContentView: View {
    @ObservedObject private var coordinator = DictationCoordinator.shared
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        VStack(spacing: 24) {
            Text("whisper-keyboard").font(.title2).bold()

            if !micGranted {
                micPermissionStep
            } else if !coordinator.isModelReady {
                modelDownloadStep
            } else {
                recordingStep
            }
        }
        .padding(24)
        .task {
            await coordinator.refreshModelStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private var micPermissionStep: some View {
        VStack(spacing: 12) {
            Text("Microphone access is needed to transcribe your speech.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Grant Microphone Access") {
                Task {
                    micGranted = await AudioRecorder.requestMicrophonePermission()
                }
            }
        }
    }

    private var modelDownloadStep: some View {
        VStack(spacing: 12) {
            if let progress = coordinator.downloadProgress {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Download the speech model — \(coordinator.modelVariant.displayName) — to get started.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Download Model") {
                    Task { await coordinator.downloadModel() }
                }
            }
        }
    }

    private var recordingStep: some View {
        VStack(spacing: 20) {
            statusLabel

            Button(action: handleTap) {
                Image(systemName: buttonSymbol)
                    .font(.system(size: 64))
                    .frame(width: 120, height: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.state == .recording ? .red : .accentColor)
            .clipShape(Circle())
            .disabled(coordinator.state == .transcribing)

            if !coordinator.lastTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last transcript").font(.caption).foregroundStyle(.secondary)
                    Text(coordinator.lastTranscript)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    Button("Copy") {
                        UIPasteboard.general.string = coordinator.lastTranscript
                    }
                }
            }
        }
    }

    private var statusLabel: some View {
        Group {
            switch coordinator.state {
            case .idle: Text("Tap to record")
            case .recording: Text("Recording… tap to stop").foregroundStyle(.red)
            case .transcribing: Text("Transcribing…")
            case .error(let message): Text(message).foregroundStyle(.red)
            }
        }
        .font(.headline)
    }

    private var buttonSymbol: String {
        switch coordinator.state {
        case .idle, .error: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "waveform"
        }
    }

    private func handleTap() {
        switch coordinator.state {
        case .idle, .error:
            Task { await coordinator.beginDictation() }
        case .recording:
            coordinator.requestStop()
        case .transcribing:
            break
        }
    }
}
