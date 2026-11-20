import Foundation

/// Which glyph the status item shows (FR-008-16): one shape per capture mode, plus a warning dot while unacknowledged
/// Warning or Error Notices exist. The dot combines with any mode. Shape, not colour, tells the states apart.
public struct MenuIcon: Equatable, Sendable {
    public let mode: CaptureMode
    public let warning: Bool

    public init(mode: CaptureMode, warning: Bool) {
        self.mode = mode
        self.warning = warning
    }

    /// Catalogue keys for the VoiceOver label, in reading order: the mode, then "needs attention" when the dot shows.
    public var accessibilityKeys: [String] {
        let modeKey: String
        switch mode {
        case .active: modeKey = "ui.menu.iconActive"
        case .paused: modeKey = "ui.menu.iconPaused"
        case .curated: modeKey = "ui.menu.iconCurated"
        }
        return warning ? [modeKey, "ui.menu.iconAttention"] : [modeKey]
    }
}

/// One row of the menu-bar menu, in the order of FR-008-16.
public enum MenuEntry: Equatable, Sendable {
    case openLibrary(ChordBinding)
    case saveClipboard(ChordBinding)
    /// "Add Clip…": opens the text entry window (FR-004-19).
    case addClip(ChordBinding)
    case toggleShelf(ChordBinding)
    case separator
    /// "Pause Capture" or "Resume Capture". Resume (next `.active`) is a plain item that writes `next` to `capture.mode`.
    /// Pause (next `.paused`) is a submenu, because pausing has a length: `PauseDuration.allCases`, then "Until I Resume",
    /// which writes `next` with no end time (FR-008-16, hill-climb r3).
    case captureToggle(titleKey: String, next: CaptureMode)
    /// The "Clear Recent" submenu (`ClearRange.recentMenuRanges`); each choice asks for confirmation (FR-007-11).
    case clearRecent
    case notices
    case settings
    case setupGuide
    case quit
}

/// The menu's content as a function of settings, so the menu is built when it opens and is never stale.
public enum MenuBarModel {
    public static func icon(mode: CaptureMode, hasWarning: Bool) -> MenuIcon {
        MenuIcon(mode: mode, warning: hasWarning)
    }

    /// The one home of the Pause/Resume Capture rule (FR-008-16, FR-007-12): the menu label and the mode a click
    /// sets both come from here. Active offers Pause (-> Paused); Paused and Curated offer Resume (-> Active).
    /// Curated is chosen in Settings only, so the menu never produces it.
    public static func captureToggle(for mode: CaptureMode) -> (titleKey: String, next: CaptureMode) {
        switch mode {
        case .active: ("ui.menu.pauseCapture", .paused)
        case .paused, .curated: ("ui.menu.resumeCapture", .active)
        }
    }

    public static func entries(settings: SettingsStore) -> [MenuEntry] {
        entries(
            mode: settings.value(SettingKeys.captureMode), shelfEnabled: settings.value(SettingKeys.shelfEnabled),
            openLibrary: settings.value(SettingKeys.shortcutsOpenLibrary),
            saveClipboard: settings.value(SettingKeys.shortcutsSaveClipboard),
            addClip: settings.value(SettingKeys.shortcutsAddClip),
            toggleShelf: settings.value(SettingKeys.shortcutsToggleShelf))
    }

    public static func entries(
        mode: CaptureMode, shelfEnabled: Bool, openLibrary: ChordBinding, saveClipboard: ChordBinding,
        addClip: ChordBinding = .none, toggleShelf: ChordBinding
    ) -> [MenuEntry] {
        let toggle = captureToggle(for: mode)
        var rows: [MenuEntry] = [.openLibrary(openLibrary), .saveClipboard(saveClipboard), .addClip(addClip)]
        if shelfEnabled { rows.append(.toggleShelf(toggleShelf)) }
        rows += [.separator, .captureToggle(titleKey: toggle.titleKey, next: toggle.next)]
        // Warnings and Errors opens the closing group with Settings, Show Setup Guide and Quit: it is an app-level
        // surface, not a capture action (hill-climb r6).
        rows += [.clearRecent, .separator, .notices]
        rows += [.settings, .setupGuide, .separator, .quit]
        return rows
    }
}
