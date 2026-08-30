import AppKit
import AVFoundation
import OSLog
import KeyboardShortcuts
import TranscriptionKit
import AudioCaptureKit
import InputInjectionKit

private let logger = Logger(subsystem: "com.omar.whisperkeyboard", category: "dictation")

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.control, .option]))
}

private enum DictationState {
    case idle
    case recording
    case transcribing
    case error(String)
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let recorder = AudioRecorder()
    private let settings = AppSettings.shared
    private var engine: WhisperEngine?

    private var state: DictationState = .idle {
        didSet { refresh() }
    }

    private let statusLineItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(grantAccessibility), keyEquivalent: "")
    private var languageItems: [LanguageHint: NSMenuItem] = [:]
    private var modelItems: [WhisperModelVariant: NSMenuItem] = [:]
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "whisper-keyboard")
        buildMenu()
        refresh()

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            logger.notice("hotkey keyDown fired")
            self?.beginRecording()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            logger.notice("hotkey keyUp fired")
            self?.endRecordingAndTranscribe()
        }

        NotificationCenter.default.addObserver(
            forName: AppSettings.modelVariantDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.engine = nil
                self?.loadModelIfAvailable()
                self?.refresh()
            }
        }
    }

    /// Loads the currently-selected model in the background if it's already downloaded.
    /// If it isn't, onboarding is responsible for downloading it first — this just covers
    /// normal app launches after setup is complete.
    func loadModelIfAvailable() {
        Task {
            let variant = settings.modelVariant
            guard await ModelManager.shared.isDownloaded(variant) else {
                logger.notice("loadModelIfAvailable: \(variant.rawValue, privacy: .public) not downloaded yet, skipping")
                return
            }
            let path = await ModelManager.shared.localURL(for: variant).path
            logger.notice("loadModelIfAvailable: loading \(variant.rawValue, privacy: .public) from \(path, privacy: .public)")
            let newEngine = WhisperEngine(modelPath: path)
            do {
                try await newEngine.loadModel()
                engine = newEngine
                logger.notice("loadModelIfAvailable: model loaded successfully")
            } catch {
                logger.error("loadModelIfAvailable: failed to load model: \(String(describing: error), privacy: .public)")
                state = .error("Failed to load model")
            }
        }
    }

    // MARK: - Dictation flow

    private func beginRecording() {
        logger.notice("beginRecording: state=\(String(describing: self.state), privacy: .public) engineLoaded=\(self.engine != nil, privacy: .public)")
        guard case .idle = state else { return }
        guard engine != nil else {
            state = .error("Model not loaded")
            return
        }

        // AudioRecorder.start() only checks authorization, it doesn't request it — if
        // permission was never asked (e.g. after a TCC reset, or on a first launch that
        // skipped onboarding), there'd otherwise be no path that ever shows the system
        // prompt, and every hotkey press would silently fail forever.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task {
                let granted = await AudioRecorder.requestMicrophonePermission()
                if granted {
                    startRecordingNow()
                } else {
                    state = .error("Microphone permission denied")
                }
            }
            return
        }

        startRecordingNow()
    }

    private func startRecordingNow() {
        do {
            try recorder.start()
            state = .recording
        } catch {
            logger.error("startRecordingNow: recorder.start() failed: \(String(describing: error), privacy: .public)")
            state = .error("Mic error: \(error)")
        }
    }

    private func endRecordingAndTranscribe() {
        guard case .recording = state else { return }
        guard let samples = recorder.stopAndCapture() else {
            state = .idle
            return
        }
        state = .transcribing

        Task {
            guard let engine else {
                state = .error("Model not loaded")
                return
            }
            do {
                let result = try await engine.transcribe(samples: samples, languageHint: settings.languageHint)
                guard !result.text.isEmpty else {
                    state = .idle
                    return
                }
                try TextInserter.insert(result.text)
                state = .idle
            } catch InputInjectionKit.TextInserter.InsertionError.notTrusted {
                state = .error("Accessibility permission needed")
            } catch {
                state = .error("Transcription failed")
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        let hotkeyItem = NSMenuItem(title: "Change Hotkey…", action: #selector(openSettings), keyEquivalent: "")
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        let languageMenu = NSMenu()
        for hint in LanguageHint.allCases {
            let item = NSMenuItem(title: hint.menuTitle, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hint
            languageItems[hint] = item
            languageMenu.addItem(item)
        }
        let languageParent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.setSubmenu(languageMenu, for: languageParent)
        menu.addItem(languageParent)

        let modelMenu = NSMenu()
        for variant in WhisperModelVariant.allCases {
            let item = NSMenuItem(title: variant.displayName, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = variant
            modelItems[variant] = item
            modelMenu.addItem(item)
        }
        let modelParent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        menu.setSubmenu(modelMenu, for: modelParent)
        menu.addItem(modelParent)

        menu.addItem(.separator())

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit whisper-keyboard", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Accessibility trust can change out-of-band (user grants/revokes it in System
        // Settings while the app is running), so re-check on every menu open rather than
        // only on dictation-state transitions.
        refresh()
    }

    private func refresh() {
        switch state {
        case .idle:
            statusLineItem.title = "Idle"
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        case .recording:
            statusLineItem.title = "Recording…"
            statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        case .transcribing:
            statusLineItem.title = "Transcribing…"
            statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        case .error(let message):
            statusLineItem.title = message
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }

        for (hint, item) in languageItems {
            item.state = (hint == settings.languageHint) ? .on : .off
        }
        for (variant, item) in modelItems {
            item.state = (variant == settings.modelVariant) ? .on : .off
        }
        launchAtLoginItem.state = settings.launchAtLogin ? .on : .off
        accessibilityItem.isHidden = TextInserter.isAccessibilityTrusted
    }

    // MARK: - Actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let hint = sender.representedObject as? LanguageHint else { return }
        settings.languageHint = hint
        refresh()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let variant = sender.representedObject as? WhisperModelVariant else { return }
        settings.modelVariant = variant
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.setLaunchAtLogin(!settings.launchAtLogin)
        refresh()
    }

    @objc private func grantAccessibility() {
        TextInserter.requestAccessibilityTrust()
        TextInserter.openAccessibilitySettings()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension LanguageHint {
    var menuTitle: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .arabic: return "Arabic"
        }
    }
}
