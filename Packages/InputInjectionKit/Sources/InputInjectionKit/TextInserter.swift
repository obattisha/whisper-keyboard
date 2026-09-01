import AppKit
import ApplicationServices

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
            throw InsertionError.notTrusted
        }

        if insertViaAccessibilityAPI(text) {
            return
        }
        insertViaPasteboard(text)
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
