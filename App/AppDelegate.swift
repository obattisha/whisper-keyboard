import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon — menu bar only

        let controller = StatusItemController()
        statusItemController = controller

        // Always attempt this regardless of onboarding status — it's a no-op if the model
        // isn't downloaded yet, and it means a model already on disk gets used even if
        // onboarding's completion state is ever wrong for some reason (e.g. its bundle
        // identity changed underneath a stale UserDefaults flag, as happened during dev).
        controller.loadModelIfAvailable()

        if !AppSettings.shared.hasCompletedOnboarding {
            onboardingWindowController = OnboardingWindowController.show { [weak self] in
                self?.onboardingWindowController = nil
                controller.loadModelIfAvailable()
            }
        }
    }
}
