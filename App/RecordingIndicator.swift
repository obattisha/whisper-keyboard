import AppKit
import SwiftUI

/// Shows that the mic is live: a small floating bubble with a waveform near the bottom of
/// the screen (optional, see AppSettings.showRecordingBubble), and the same waveform drawn
/// into the menu bar icon.
@MainActor
final class RecordingIndicator {
    enum Phase: Equatable {
        case hidden
        case starting
        case listening
        case transcribing
    }

    /// Enough history for the bubble; the menu bar icon uses the newest few.
    static let historyLength = 20

    private let model = BubbleModel()
    private lazy var panel = makePanel()

    var phase: Phase { model.phase }

    func show(_ phase: Phase, bubble: Bool) {
        if phase != model.phase, phase == .listening || phase == .starting {
            model.levels = Array(repeating: 0, count: Self.historyLength)
        }
        model.phase = phase
        guard bubble, phase != .hidden else {
            panel.orderOut(nil)
            return
        }
        position()
        panel.orderFrontRegardless()
    }

    func push(level: Float) {
        model.levels.removeFirst()
        model.levels.append(level)
    }

    var levels: [Float] { model.levels }

    /// Bottom center of the screen the pointer is on, just above the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 32))
    }

    /// Never takes focus or clicks: the dictated text has to paste into whatever app was
    /// in front, so this window must not become key, activate the app, or catch the mouse.
    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: BubbleView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: BubbleView.width, height: BubbleView.height)
        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    // MARK: - Menu bar icon

    /// Five bars from the newest levels, drawn as a template image so it follows the menu
    /// bar's light/dark appearance like the SF Symbols used for the other states.
    static func menuBarImage(levels: [Float]) -> NSImage {
        let recent = Array(levels.suffix(5))
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2.4
            let gap: CGFloat = 1.3
            let totalWidth = CGFloat(recent.count) * barWidth + CGFloat(recent.count - 1) * gap
            var x = (rect.width - totalWidth) / 2
            NSColor.black.setFill()
            for level in recent {
                let height = 3 + CGFloat(level) * 13
                let bar = NSRect(x: x, y: (rect.height - height) / 2, width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Recording"
        return image
    }
}

@MainActor
private final class BubbleModel: ObservableObject {
    @Published var phase: RecordingIndicator.Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: RecordingIndicator.historyLength)
}

private struct BubbleView: View {
    static let width: CGFloat = 220
    static let height: CGFloat = 52

    @ObservedObject var model: BubbleModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .listening:
                Circle().fill(.red).frame(width: 8, height: 8)
                waveform
                Text("Listening")
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting mic…")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            case .hidden:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.8)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
        .frame(width: Self.width, height: Self.height)
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(model.levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: 3 + CGFloat(model.levels[index]) * 17)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.05), value: model.levels)
    }
}
