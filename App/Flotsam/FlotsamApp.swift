import FlotsamBase
import FlotsamStorage
import SwiftUI

/// App entry point (L4). Owns UI and platform wiring only; behaviour lives in FlotsamCore (ADR-0001).
@main
struct FlotsamApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        MenuBarExtra("Flotsam", systemImage: "tray.full") {
            Text(verbatim: FlotsamStrings.text(forKey: "ui.menu.status") ?? "")
            Divider()
            Button(FlotsamStrings.text(forKey: "ui.menu.quit") ?? "") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onChange(of: container.startupError) { _, error in
            if let error { FlotsamLog.log(error, category: .core) }
        }
    }
}
