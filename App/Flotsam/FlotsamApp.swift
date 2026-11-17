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
            Button(FlotsamStrings.text(forKey: "ui.menu.openLibrary") ?? "") { container.library?.toggle() }
                .disabled(container.library == nil)
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
                    Text(verbatim: Self.noticeRowText(notice))
                }
                Divider()
                Button(FlotsamStrings.text(forKey: "ui.menu.dismissAll") ?? "") {
                    Task { await container.reporter.dismissAllNotices() }
                }
            }
        }
    }

    /// One Notices row: the message, then the code as secondary text (FRD-000 section 9). A menu-style
    /// `MenuBarExtra` renders each item as a single styled string and ignores secondary foreground styles, so the
    /// code follows the message on the same line after a separator.
    private static func noticeRowText(_ notice: Notice) -> String {
        "\(notice.message) · \(notice.code.rawValue)"
    }
}
