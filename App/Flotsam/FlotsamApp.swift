import FlotsamBase
import FlotsamStorage
import SwiftUI

/// App entry point (L4). Owns UI and platform wiring only; behaviour lives in FlotsamCore (ADR-0001).
@main
struct FlotsamApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        MenuBarExtra {
            Text(verbatim: FlotsamStrings.text(forKey: "ui.menu.status") ?? "")
            Divider()
            noticesMenu
            Divider()
            Button(FlotsamStrings.text(forKey: "ui.menu.quit") ?? "") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: MenuBarIcon.image(badged: container.presenter.hasBadge))
                .accessibilityLabel(FlotsamStrings.text(forKey: "ui.menu.title") ?? "")
        }
    }

    /// Menu bar, Notices (FR-000-08 b): newest 10 background failures, with "Dismiss all".
    @ViewBuilder
    private var noticesMenu: some View {
        Menu(FlotsamStrings.text(forKey: "ui.menu.notices") ?? "") {
            if container.presenter.notices.isEmpty {
                Text(verbatim: FlotsamStrings.text(forKey: "ui.menu.noNotices") ?? "")
            } else {
                ForEach(container.presenter.notices) { notice in
                    Text(verbatim: notice.message)
                }
                Divider()
                Button(FlotsamStrings.text(forKey: "ui.menu.dismissAll") ?? "") {
                    Task { await container.reporter.dismissAllNotices() }
                }
            }
        }
    }
}
