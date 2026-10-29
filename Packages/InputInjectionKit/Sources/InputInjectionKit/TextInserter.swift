import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.omar.whisperkeyboard", category: "insert")

/// Inserts transcribed text at the current cursor position in whichever app is focused.
/// Requires the app to be trusted for Accessibility (System Settings > Privacy & Security
/// > Accessibility) — without it, both insertion paths are unavailable, not just the
/// AX-direct one, since the synthetic-paste path also depends on `AXIsProcessTrusted()`.
@MainActor
public enum TextInserter {
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system Accessibility permission prompt if not already trusted/denied.
    /// Only shows the native prompt once per app install; call `openAccessibilitySettings()`
    /// as a fallback for users who dismissed it or need to re-grant after a rebuild.
    @discardableResult
    public static func requestAccessibilityTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    public enum InsertionError: Error {
        case notTrusted
        case noFocusedElement
    }

    /// Inserts `text` at the cursor in the frontmost app's focused text field, trying the
    /// Accessibility API first and falling back to a synthetic clipboard paste for apps
    /// (browsers, Electron apps, Terminal) whose AX trees don't expose a settable
    /// selected-text attribute.
    public static func insert(_ text: String) throws {
        guard isAccessibilityTrusted else {
            logger.error("insert: not trusted for Accessibility")
            throw InsertionError.notTrusted
        }

        let target = focusedApplication()
        let chromium = isChromium(target)
        logger.notice("insert: target=\(target?.bundleIdentifier ?? "nil", privacy: .public) chromium=\(chromium, privacy: .public)")
        if !chromium, insertViaAccessibilityAPI(text) {
            logger.notice("insert: AX path reported success")
            return
        }
        logger.notice("insert: pasting via Cmd-V")
        insertViaPasteboard(text)
    }

    /// Chromium-based apps, meaning Electron apps (Claude desktop, Slack, VS Code, ...) and
    /// Chromium browsers (Chrome, Edge, Brave, ...), report `kAXSelectedTextAttribute` as
    /// settable on web rich-text editors and return `.success` when it's set, but the editor
    /// (ProseMirror on claude.ai, Monaco, etc.) never sees the change, so nothing appears.
    /// That "success" also skipped the paste fallback, leaving the text only in Recent
    /// Transcriptions. Go straight to pasting for these apps.
    ///
    /// They all bundle Chromium as "<Name> Framework.framework" ("Electron Framework",
    /// "Google Chrome Framework", "Microsoft Edge Framework"), so match on that.
    private static func isChromium(_ app: NSRunningApplication?) -> Bool {
        guard let bundleURL = app?.bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.contains { $0.hasSuffix(" Framework.framework") }
    }

    /// The app that owns keyboard focus, asked of Accessibility rather than
    /// `NSWorkspace.frontmostApplication`. In this menu-bar (LSUIElement) app that property
    /// can go stale: it reported com.apple.loginwindow while Claude was in front, which made
    /// the Electron check above miss and the dictation vanish into the AX path again.
    private static func focusedApplication() -> NSRunningApplication? {
        var appRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &appRef)
        guard result == .success, let appRef else { return NSWorkspace.shared.frontmostApplication }
        // Safe force-cast: kAXFocusedApplicationAttribute always yields an AXUIElement on .success.
        var pid: pid_t = 0
        guard AXUIElementGetPid(appRef as! AXUIElement, &pid) == .success else {
            return NSWorkspace.shared.frontmostApplication
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    private static func insertViaAccessibilityAPI(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusedResult == .success, let focusedRef else { return false }
        // Safe force-cast: AXUIElementCopyAttributeValue for kAXFocusedUIElementAttribute
        // always yields an AXUIElement on .success.
        let focusedElement = focusedRef as! AXUIElement

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &settable)
        guard settableResult == .success, settable.boolValue else { return false }

        let setResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return setResult == .success
    }

    /// Virtual keycode for 'V' (kVK_ANSI_V from Carbon.HIToolbox) — hardcoded to avoid
    /// pulling in the Carbon framework for a single constant.
    private static let virtualKeyCodeV: CGKeyCode = 0x09

    private static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        // Every flavor of every item, not just `types.first`. A single clipboard item
        // routinely carries several representations at once (copying from a browser gives
        // public.html, public.png and public.utf8-plain-text together), and keeping only
        // the first one meant this "restore" quietly destroyed the rest of the user's
        // clipboard on every dictation that fell back to pasting.
        let savedItems: [[String: Data]] = pasteboard.pasteboardItems?.map { item in
            var flavors: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    flavors[type.rawValue] = data
                }
            }
            return flavors
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyCodeV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyCodeV, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        if keyDown == nil || keyUp == nil {
            logger.error("insert: failed to create Cmd-V events")
        }
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            let restored = savedItems.compactMap { flavors -> NSPasteboardItem? in
                guard !flavors.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (typeRaw, data) in flavors {
                    item.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
                }
                return item
            }
            if !restored.isEmpty {
                pasteboard.writeObjects(restored)
            }
        }
    }
}
