import AppIntents

/// Exposed to the Action Button and Shortcuts app. `openAppWhenRun` is the key setting:
/// without it, the system may run `perform()` in a lightweight, memory-constrained Intents
/// process unsuited to loading a Whisper model — this forces a full app launch instead,
/// giving `beginDictation()` the same memory budget as opening the app normally.
struct DictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate"
    static var description = IntentDescription(
        "Records speech and transcribes it on-device with Whisper, then copies the result."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = await DictationCoordinator.shared.beginDictation() ?? ""
        return .result(value: text)
    }
}

struct WhisperKeyboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: ["Dictate with \(.applicationName)"],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
    }
}
