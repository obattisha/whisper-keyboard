import AppKit

/// Push-to-talk on the Fn (Globe) key by itself. KeyboardShortcuts' recorder can't capture a
/// bare modifier, so this watches `flagsChanged` directly. Global event monitors need
/// Accessibility, which the app already requires for inserting text.
@MainActor
final class FnKeyMonitor {
    /// kVK_Function from Carbon.HIToolbox, hardcoded like TextInserter's 'V' keycode.
    private static let fnKeyCode: UInt16 = 63

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired when another key goes down while Fn is held (Fn+Delete, Fn+arrows, Fn+F-keys):
    /// that press was a shortcut, not a dictation, so the recording should be thrown away.
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false
    private var chorded = false

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        // Global covers every other app; local covers this app's own windows (Settings),
        // which global monitors don't see.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if isDown {
            isDown = false
            onCancel?()
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if isDown, !chorded {
                chorded = true
                onCancel?()
            }
        case .flagsChanged:
            guard event.keyCode == Self.fnKeyCode else { return }
            let pressed = event.modifierFlags.contains(.function)
            if pressed, !isDown {
                isDown = true
                chorded = false
                onPress?()
            } else if !pressed, isDown {
                isDown = false
                if !chorded {
                    onRelease?()
                }
            }
        default:
            break
        }
    }
}
