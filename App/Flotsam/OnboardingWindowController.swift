import AppKit
import FlotsamBase
import SwiftUI

/// The onboarding window (FR-008-12): one window, reopened fresh from "Show Setup Guide…". Closing it by any route
/// sets `onboarding.completed`.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let container: AppContainer
    private var window: NSWindow?
    private var front: WindowFrontAdapter?
    private var model: OnboardingModel?

    init(container: AppContainer) {
        self.container = container
    }

    /// `resuming`: the launch-time show continues an unfinished onboarding; "Show Setup Guide…" starts over.
    func show(resuming: Bool = false) {
        if window != nil {
            front?.bringToFront()
            return
        }
        let model = OnboardingModel(container: container, resuming: resuming)
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
        // An agent app has no active window of its own, so it must activate to bring this one forward.
        let front = WindowFrontAdapter(window: window)
        self.front = front
        front.bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        model?.markCompleted()
        window = nil
        front = nil
        model = nil
    }
}
