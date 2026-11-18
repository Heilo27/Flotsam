import FlotsamBase
import Foundation

/// FR-005-06: runs Save Clipboard and shows the result as a HUD. Success shows `ui.shortcuts.saved`; a rejected
/// payload shows its reason, using the catalogue text only (FR-000-05).
@MainActor
public struct SaveClipboardAction {
    private let saver: any ClipboardSaver
    private let hud: @MainActor (String) -> Void

    public init(saver: any ClipboardSaver, hud: @escaping @MainActor (String) -> Void) {
        self.saver = saver
        self.hud = hud
    }

    public func run() async {
        hud(Self.message(for: await saver.saveClipboardNow()))
    }

    /// The HUD text for an outcome. The three gate rejections have their own wording; every other failure uses its
    /// error code's catalogue message.
    public static func message(for outcome: SaveClipboardOutcome) -> String {
        switch outcome {
        case .saved: text("ui.shortcuts.saved")
        case .rejected(let error):
            switch error.code {
            case .capPol001: text("ui.shortcuts.notSavedConcealed")
            case .capPol002: text("ui.shortcuts.notSavedIgnoredApp")
            case .capVal001: text("ui.shortcuts.notSavedEmpty")
            default: FlotsamStrings.message(for: error)
            }
        }
    }

    private static func text(_ key: String) -> String {
        FlotsamStrings.text(forKey: key) ?? FlotsamStrings.message(for: .sysInt001)
    }
}
