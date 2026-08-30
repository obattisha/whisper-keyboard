import SwiftUI
import KeyboardShortcuts
import TranscriptionKit

@MainActor
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var downloadState: ModelDownloadState = .checking

    // Onboarding gates entry behind `hasCompletedOnboarding`, so once that flag is set
    // there'd otherwise be no way back to a download screen if the model file is ever
    // missing later — switching variants, freeing disk space, restoring settings onto a
    // new Mac. This mirrors OnboardingView's own download step so that path always exists.
    private enum ModelDownloadState: Equatable {
        case checking
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed(String)
    }

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Push-to-talk hotkey:", name: .pushToTalk)

            Picker("Language:", selection: $settings.languageHint) {
                Text("Auto-detect").tag(LanguageHint.auto)
                Text("English").tag(LanguageHint.english)
                Text("Arabic").tag(LanguageHint.arabic)
            }

            Picker("Model:", selection: $settings.modelVariant) {
                ForEach(WhisperModelVariant.allCases, id: \.self) { variant in
                    Text(variant.displayName).tag(variant)
                }
            }

            modelStatusRow

            Toggle("Launch at Login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
        }
        .padding(24)
        .frame(width: 420)
        .task(id: settings.modelVariant) {
            downloadState = .checking
            let isDownloaded = await ModelManager.shared.isDownloaded(settings.modelVariant)
            downloadState = isDownloaded ? .downloaded : .notDownloaded
        }
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        switch downloadState {
        case .checking:
            EmptyView()
        case .notDownloaded:
            Button("Download \(settings.modelVariant.displayName)") { startDownload() }
        case .downloading(let progress):
            ProgressView(value: progress)
            Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
        case .downloaded:
            Label("Model downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading) {
                Text(message).foregroundStyle(.red).font(.caption)
                Button("Retry") { startDownload() }
            }
        }
    }

    private func startDownload() {
        let variant = settings.modelVariant
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
                await MainActor.run {
                    downloadState = .downloaded
                    // StatusItemController already reloads the engine on this notification
                    // when the variant changes; post it here too so a download completing
                    // for the *current* variant (no change event otherwise) also reloads it.
                    NotificationCenter.default.post(name: AppSettings.modelVariantDidChange, object: nil)
                }
            } catch {
                await MainActor.run { downloadState = .failed("Download failed: \(error.localizedDescription)") }
            }
        }
    }
}
