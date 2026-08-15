import SwiftUI
import AVFoundation
import TranscriptionKit
import AudioCaptureKit
import InputInjectionKit

@MainActor
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var downloadState: DownloadState = .notStarted
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axTrusted = TextInserter.isAccessibilityTrusted

    private let variant = AppSettings.shared.modelVariant

    private enum DownloadState: Equatable {
        case notStarted
        case downloading(progress: Double)
        case done
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up whisper-keyboard").font(.title2).bold()

            step(
                title: "1. Download the speech model",
                done: downloadState == .done
            ) {
                switch downloadState {
                case .notStarted:
                    Button("Download \(variant.displayName)") { startDownload() }
                case .downloading(let progress):
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                case .done:
                    Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    VStack(alignment: .leading) {
                        Text(message).foregroundStyle(.red).font(.caption)
                        Button("Retry") { startDownload() }
                    }
                }
            }

            step(title: "2. Allow microphone access", done: micGranted) {
                if micGranted {
                    Label("Microphone access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant Microphone Access") {
                        Task {
                            micGranted = await AudioRecorder.requestMicrophonePermission()
                        }
                    }
                }
            }

            step(title: "3. Allow Accessibility access", done: axTrusted) {
                if axTrusted {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Needed to insert dictated text at your cursor in other apps.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open System Settings…") {
                            TextInserter.requestAccessibilityTrust()
                            TextInserter.openAccessibilitySettings()
                        }
                        Button("I've granted it — check again") {
                            axTrusted = TextInserter.isAccessibilityTrusted
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    AppSettings.shared.hasCompletedOnboarding = true
                    onComplete()
                }
                    .disabled(downloadState != .done || !micGranted || !axTrusted)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 440)
        .task {
            if await ModelManager.shared.isDownloaded(variant) {
                downloadState = .done
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Granting Accessibility (and, on some macOS versions, Microphone) happens in
            // System Settings, a separate app — refresh when we regain focus rather than
            // relying solely on the manual "check again" button.
            axTrusted = TextInserter.isAccessibilityTrusted
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    @ViewBuilder
    private func step(title: String, done: Bool, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func startDownload() {
        downloadState = .downloading(progress: 0)
        Task {
            do {
                try await ModelManager.shared.download(variant) { progress in
                    let fraction = progress.totalBytes > 0
                        ? Double(progress.bytesWritten) / Double(progress.totalBytes)
                        : 0
                    Task { @MainActor in
                        downloadState = .downloading(progress: fraction)
                    }
                }
                await MainActor.run { downloadState = .done }
            } catch {
                await MainActor.run { downloadState = .failed("Download failed: \(error.localizedDescription)") }
            }
        }
    }
}
