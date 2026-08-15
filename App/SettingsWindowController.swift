import AppKit
import SwiftUI

/// SwiftUI's `Settings` scene relies on the `showSettingsWindow:` responder-chain action,
/// which AppKit only wires up for apps with a standard main menu — this app is
/// `.accessory` (menu bar only, no Dock icon, no main menu), so that action never
/// resolves and the menu item silently does nothing. Managing the window directly, the
/// same way `OnboardingWindowController` does, works regardless of activation policy.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "whisper-keyboard Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
