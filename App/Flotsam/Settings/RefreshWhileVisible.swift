import AppKit
import FlotsamBase
import SwiftUI

extension View {
    /// Runs `refresh` now, on every app activation, and every 2 s (`VisibleRefresh.interval`) while this view is on screen
    /// in a visible window (FR-008-13 rule b). It runs nothing while the window is closed, minimised or covered, or
    /// while another pane is selected. Apply it once per group of rows that share one refresh, not to each row.
    func refreshWhileVisible(_ refresh: @escaping @MainActor () -> Void) -> some View {
        modifier(RefreshWhileVisible(refresh: refresh))
    }
}

private struct RefreshWhileVisible: ViewModifier {
    let refresh: @MainActor () -> Void
    @State private var refresher: VisibleRefresh
    @State private var onScreen = false
    @State private var window: NSWindow?

    init(refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
        _refresher = State(initialValue: VisibleRefresh(refresh: refresh))
    }

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onAppear { onScreen = true; sync() }
            .onDisappear { onScreen = false; sync() }
            .onChange(of: window) { sync() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                if (note.object as? NSWindow) === window { sync() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refresh()
            }
    }

    private func sync() {
        refresher.setVisible(VisibleRefresh.isVisible(
            onScreen: onScreen, windowIsVisible: window.map { $0.occlusionState.contains(.visible) }))
    }
}

/// Reports the window that hosts the view it is attached to (nil while it has none).
private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        private let onChange: (NSWindow?) -> Void

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Probe is built in code, never decoded") } // fatal-ok: AppKit-required initialiser; the view is built in code, never decoded

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [onChange] in onChange(window) }
        }
    }
}
