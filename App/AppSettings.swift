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

    static let modelVariantDidChange = Notification.Name("AppSettings.modelVariantDidChange")
    @Published private(set) var launchAtLogin: Bool
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    private enum Keys {
        static let languageHint = "languageHint"
        static let modelVariant = "modelVariant"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private init() {
        let defaults = UserDefaults.standard
        languageHint = defaults.string(forKey: Keys.languageHint).flatMap { LanguageHint(rawValue: $0) } ?? .auto
        modelVariant = defaults.string(forKey: Keys.modelVariant).flatMap { WhisperModelVariant(rawValue: $0) } ?? .largeV3Turbo
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
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
