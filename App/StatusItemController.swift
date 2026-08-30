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
    case downloadingModel(progress: Double)
    case loadingModel
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
    private let downloadModelItem = NSMenuItem(title: "Download Model…", action: #selector(downloadCurrentModel), keyEquivalent: "")
    private var languageItems: [LanguageHint: NSMenuItem] = [:]
    private var modelItems: [WhisperModelVariant: NSMenuItem] = [:]
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    // Insertion has no reliable success signal — the clipboard-paste fallback just sends
    // ⌘V into whatever's frontmost, which can be a genuine no-op (no text field focused)
    // with no error thrown. Keeping every transcription here, in memory only (cleared on
    // quit, never written to disk — dictated speech can be sensitive), is the safety net:
    // it's recorded before insertion is even attempted, so a lost paste is still copyable.
    private let recentTranscriptionsParent = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
    private var recentTranscriptions: [String] = []
    private static let maxRecentTranscriptions = 20
    private static let previewLength = 60

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
        guard case .loadingModel = state else {
            startLoadingModel()
            return
        }
        // Already loading (e.g. called again from onboarding's completion callback right
        // after the app-launch call already started one) — let that one finish.
    }

    private func startLoadingModel() {
        Task {
            let variant = settings.modelVariant
            guard await ModelManager.shared.isDownloaded(variant) else {
                logger.notice("loadModelIfAvailable: \(variant.rawValue, privacy: .public) not downloaded yet, skipping")
                return
            }
            let path = await ModelManager.shared.localURL(for: variant).path
            logger.notice("loadModelIfAvailable: loading \(variant.rawValue, privacy: .public) from \(path, privacy: .public)")
            // Loading a multi-gigabyte model (mmap + Metal shader compilation) can take
            // real time — without a distinct state here, the status line kept showing
            // "Idle" throughout, so a hotkey press mid-load hit the "Model not loaded"
            // error below even though loading was already happening automatically.
            state = .loadingModel
            let newEngine = WhisperEngine(modelPath: path)
            do {
                try await newEngine.loadModel()
                engine = newEngine
                state = .idle
                logger.notice("loadModelIfAvailable: model loaded successfully")
            } catch {
                logger.error("loadModelIfAvailable: failed to load model: \(String(describing: error), privacy: .public)")
                state = .error("Failed to load model")
            }
        }
    }

    /// Downloads `variant` (no-op if already present) and, on success, loads it. Drives
    /// the menu bar's "Downloading model… N%" state so this is safe to call directly from
    /// a menu click — the Model submenu (selecting an undownloaded variant) and the
    /// "Download Model…" item (shown whenever no model is loaded) both go through this.
    private func downloadAndLoad(_ variant: WhisperModelVariant) {
        state = .downloadingModel(progress: 0)
        Task {
            do {
                try await ModelManager.shared.download(variant) { progress in
                    let fraction = progress.totalBytes > 0
                        ? Double(progress.bytesWritten) / Double(progress.totalBytes)
                        : 0
                    Task { @MainActor [weak self] in
                        self?.state = .downloadingModel(progress: fraction)
                    }
                }
            } catch {
                logger.error("downloadAndLoad: download failed: \(String(describing: error), privacy: .public)")
                state = .error("Model download failed")
                return
            }
            state = .idle
            loadModelIfAvailable()
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
                // Record after (not before) attempting insertion, and only the cheap array
                // bookkeeping here — rebuilding the menu's NSMenuItems is deferred to
                // menuWillOpen so it never adds latency to the actual paste. `defer` still
                // runs this even if insert() throws below, so a failed/lost paste is caught.
                defer { recordTranscription(result.text) }
                try TextInserter.insert(result.text)
                state = .idle
            } catch InputInjectionKit.TextInserter.InsertionError.notTrusted {
                state = .error("Accessibility permission needed")
            } catch {
                state = .error("Transcription failed")
            }
        }
    }

    // MARK: - Recent transcriptions

    private func recordTranscription(_ text: String) {
        recentTranscriptions.insert(text, at: 0)
        if recentTranscriptions.count > Self.maxRecentTranscriptions {
            recentTranscriptions.removeLast(recentTranscriptions.count - Self.maxRecentTranscriptions)
        }
        // Menu rebuild deliberately not done here — see the call site in transcribe().
    }

    private func rebuildRecentTranscriptionsMenu() {
        let recentMenu = NSMenu()
        if recentTranscriptions.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent transcriptions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
            for (index, text) in recentTranscriptions.enumerated() {
                let item = NSMenuItem(title: Self.preview(of: text), action: #selector(copyRecentTranscription(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = index
                item.toolTip = text
                recentMenu.addItem(item)
            }
            recentMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear Recent Transcriptions", action: #selector(clearRecentTranscriptions), keyEquivalent: "")
            clearItem.target = self
            recentMenu.addItem(clearItem)
        }
        recentTranscriptionsParent.submenu = recentMenu
    }

    private static func preview(of text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count > previewLength ? String(collapsed.prefix(previewLength)) + "…" : collapsed
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        menu.addItem(recentTranscriptionsParent)
        rebuildRecentTranscriptionsMenu()
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

        downloadModelItem.target = self
        menu.addItem(downloadModelItem)

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
        rebuildRecentTranscriptionsMenu()
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
        case .downloadingModel(let progress):
            statusLineItem.title = "Downloading model… \(Int(progress * 100))%"
            statusItem.button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        case .loadingModel:
            statusLineItem.title = "Loading model…"
            statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        case .error(let message):
            statusLineItem.title = message
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }

        for (hint, item) in languageItems {
            item.state = (hint == settings.languageHint) ? .on : .off
            let isSupported = hint == .auto || hint == .english || settings.modelVariant.isMultilingual
            item.isEnabled = isSupported
            item.toolTip = isSupported ? nil : "\(settings.modelVariant.displayName) is English-only"
        }
        for (variant, item) in modelItems {
            item.state = (variant == settings.modelVariant) ? .on : .off
            Task {
                let isDownloaded = await ModelManager.shared.isDownloaded(variant)
                item.title = isDownloaded ? variant.displayName : "\(variant.displayName) (not downloaded)"
            }
        }
        launchAtLoginItem.state = settings.launchAtLogin ? .on : .off
        accessibilityItem.isHidden = TextInserter.isAccessibilityTrusted

        // Only surface this when there's actually something for the user to trigger: not
        // while a download/load is already automatically in progress, and not once a model
        // is loaded — just when nothing is loaded and nothing is already working on it
        // (fresh install with no model yet, or a load/download that failed).
        switch state {
        case .downloadingModel, .loadingModel:
            downloadModelItem.isHidden = true
        default:
            downloadModelItem.isHidden = engine != nil
            if engine == nil {
                let variant = settings.modelVariant
                Task {
                    let isDownloaded = await ModelManager.shared.isDownloaded(variant)
                    downloadModelItem.title = isDownloaded ? "Load Model…" : "Download Model…"
                }
            }
        }
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
        // Arabic only makes sense for a multilingual model — switching to an English-only
        // one while it's selected would silently force a language token that model can't
        // decode, so fall back to English rather than leave that stale combination in place.
        if !variant.isMultilingual && settings.languageHint == .arabic {
            settings.languageHint = .english
        }
        refresh()
        Task {
            if await !ModelManager.shared.isDownloaded(variant) {
                downloadAndLoad(variant)
            }
        }
    }

    @objc private func downloadCurrentModel() {
        downloadAndLoad(settings.modelVariant)
    }

    @objc private func copyRecentTranscription(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, recentTranscriptions.indices.contains(index) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recentTranscriptions[index], forType: .string)
    }

    @objc private func clearRecentTranscriptions() {
        recentTranscriptions.removeAll()
        rebuildRecentTranscriptionsMenu()
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
