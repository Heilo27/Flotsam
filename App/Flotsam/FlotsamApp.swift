import AppKit

/// App entry point (L4). A pure AppKit agent: no Dock icon (LSUIElement), no scenes. The status item, menu and
/// onboarding window are owned by `AppDelegate`; behaviour lives in FlotsamCore (ADR-0001).
@main
enum FlotsamApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
