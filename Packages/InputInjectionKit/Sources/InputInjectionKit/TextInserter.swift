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
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
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
            for (typeRaw, data) in savedItems {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
            }
        }
    }
}
