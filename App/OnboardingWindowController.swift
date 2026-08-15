import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    static func show(onComplete: @escaping () -> Void) -> OnboardingWindowController {
        let controller = OnboardingWindowController(onComplete: onComplete)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    private init(onComplete: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to whisper-keyboard"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.contentView = NSHostingView(rootView: OnboardingView(onComplete: { [weak self] in
            onComplete()
            self?.close()
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
