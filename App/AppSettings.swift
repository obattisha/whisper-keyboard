import Foundation
import ServiceManagement
import TranscriptionKit

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var languageHint: LanguageHint {
        didSet { UserDefaults.standard.set(languageHint.rawValue, forKey: Keys.languageHint) }
    }
    @Published var modelVariant: WhisperModelVariant {
        didSet {
            UserDefaults.standard.set(modelVariant.rawValue, forKey: Keys.modelVariant)
            NotificationCenter.default.post(name: Self.modelVariantDidChange, object: nil)
        }
    }

    /// Push-to-talk on Fn alone, alongside the recorded shortcut. See FnKeyMonitor.
    @Published var useFnKey: Bool {
        didSet { UserDefaults.standard.set(useFnKey, forKey: Keys.useFnKey) }
    }

    /// The floating "Listening" bubble. The menu bar icon shows a live waveform either way.
    @Published var showRecordingBubble: Bool {
        didSet { UserDefaults.standard.set(showRecordingBubble, forKey: Keys.showRecordingBubble) }
    }

    static let modelVariantDidChange = Notification.Name("AppSettings.modelVariantDidChange")
    @Published private(set) var launchAtLogin: Bool
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    private enum Keys {
        static let languageHint = "languageHint"
        static let modelVariant = "modelVariant"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let useFnKey = "useFnKey"
        static let showRecordingBubble = "showRecordingBubble"
    }

    private init() {
        let defaults = UserDefaults.standard
        languageHint = defaults.string(forKey: Keys.languageHint).flatMap { LanguageHint(rawValue: $0) } ?? .auto
        // Q5 by default: smallest download, fastest, and still multilingual — the best
        // fit for first-run setup. Users can pick a heavier variant from the Model menu.
        modelVariant = defaults.string(forKey: Keys.modelVariant).flatMap { WhisperModelVariant(rawValue: $0) } ?? .largeV3TurboQ5
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        useFnKey = defaults.bool(forKey: Keys.useFnKey)
        showRecordingBubble = defaults.object(forKey: Keys.showRecordingBubble) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            print("Failed to update launch-at-login: \(error)")
        }
    }
}
