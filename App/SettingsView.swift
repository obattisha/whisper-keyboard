import SwiftUI
import KeyboardShortcuts
import TranscriptionKit

@MainActor
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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

            Toggle("Launch at Login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
        }
        .padding(24)
        .frame(width: 420)
    }
}
