import AppKit
import FlotsamBase
import SwiftUI

/// The onboarding window (FR-008-12): one window, reopened fresh from "Show Setup Guide…". Closing it by any route
/// sets `onboarding.completed`.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let container: AppContainer
    private var window: NSWindow?
    private var model: OnboardingModel?

    init(container: AppContainer) {
        self.container = container
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            return
        }
        let model = OnboardingModel(container: container)
        let finish: () -> Void = { [weak self] in self?.window?.close() }
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: OnboardingView(model: model, finish: finish)))
        window.title = FlotsamStrings.text(forKey: "ui.onboarding.windowTitle") ?? ""
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
        // An agent app has no active window of its own, so it must activate to bring this one forward.
        NSApplication.shared.activate()
    }

    func windowWillClose(_ notification: Notification) {
        model?.markCompleted()
        window = nil
        model = nil
    }
}
