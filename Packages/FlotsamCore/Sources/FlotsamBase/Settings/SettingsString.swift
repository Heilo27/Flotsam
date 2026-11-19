import Foundation

/// Every catalogue key the Settings window uses, as a case, so a view cannot name a key that is not in
/// `Localizable.xcstrings` and a test can pin the enum to the file in both directions (FR-000-05, FR-008-17).
/// The raw value is the key's last segment: `launchAtLogin` is `ui.settings.launchAtLogin`.
public enum SettingsString: String, CaseIterable, Sendable {
    // Window and panes
    case window
    case paneGeneral, paneShortcuts, paneTypes, paneTriggers, panePrivacy, paneStorage, paneTips, paneAbout

    // General
    case launchAtLogin, loginApprovalCaption, openLoginItems
    case pickUpScreenshots, screenshotFolder, folderSystemDefault, chooseFolder, useSystemDefault
    /// The always-available backfill button (FR-002-12).
    case importRecentScreenshots
    case shelf, shelfPlacement, placementRightEdge, placementLeftEdge, placementBottomEdge, placementMenuBar, placementTopCenter
    case revealAtEdge, showSetupGuide, historyHelp
    /// The Library layout row (FR-008-04): label, the two choices and the caption under them.
    case libraryLayout, layoutStandard, layoutCompact, libraryLayoutHelp
    /// The auto-bundle row (FR-001-12, FR-008-04): label and caption.
    case autoBundle, autoBundleHelp

    /// The Library's look and behaviour rows (FR-008-04, FR-008-25), and the restore-defaults confirmation.
    case libraryBackground, backgroundSystem, backgroundLight, backgroundDark
    case previewPreset, presetClosed, presetOpen, presetRoomy, previewPresetHelp
    case closeAfterPaste, closeAfterPasteHelp, resumeOnReopen, resumeOnReopenHelp
    case libraryDisplay, displayPointer, displayFocus
    case resetLibraryDefaults, resetLibraryTitle, resetLibraryMessage, resetLibraryConfirm

    // Types (FR-008-26)
    case typesHelp, typeMoveUp, typeMoveDown

    // Tips (FR-008-27)
    case tipRecallTitle, tipRecallBody, tipPasteTitle, tipPasteBody, tipPreviewTitle, tipPreviewBody
    case tipMoveTitle, tipMoveBody, tipSnippetTitle, tipSnippetBody, tipShelfTitle, tipShelfBody

    // Shortcuts
    case shortcutOpenLibrary, shortcutSaveClipboard, shortcutToggleShelf, shortcutPasteQueue
    case shortcutNotSet, shortcutRecord, shortcutRecording, shortcutClear, shortcutNeedsModifier, shortcutsFootnote

    // Item editor: shortcut and trigger (FR-005-09)
    case editorWindow, editorShortcut, editorTrigger, editorTriggerPlaceholder, editorTriggerHelp
    /// The variable help caption: lists {date}, {time}, {clipboard} and format examples (FR-005-17, FRD-005 section 8).
    case editorVariablesHelp
    case editorNoTrigger, editorSave, editorItemGone, editorLoadFailed

    // Triggers and permissions
    case expandTriggers, permissionAccessibility, permissionInputMonitoring
    case permissionGranted, permissionNotGranted
    case permissionAccessibilityHelp, permissionInputMonitoringHelp, openSystemSettings
    case excludedApps, excludedAppsHelp
    /// The Triggers pane's inline text while Accessibility is missing (FR-008-06).
    case triggersAccessibilityPaused

    // Lists (Triggers and Privacy)
    case addApp, removeApp, resetToDefaults, chooseApp, chooseAppPrompt, notInstalled
    /// The one-tap password-manager preset on the ignored-apps list (FR-008-11).
    case addPasswordManagers, addPasswordManagersHelp
    case confirmResetIgnoredTitle, confirmResetIgnored, resetAction

    // Privacy
    case ignoredApps, ignoredAppsHelp, neverStored, noNetwork, pasteOtherApps, pasteOtherAppsHelp

    // Storage
    case keepHistoryFor, keepHelp
    case retention7Days, retention30Days, retention90Days, retention1Year, retentionForever
    case imageLimit, budget500MB, budget2GB, budget10GB, budgetUnlimited
    case imageQuality, qualityOriginal, qualityBalanced, qualityEfficient
    case qualityOriginalHelp, qualityBalancedHelp, qualityEfficientHelp
    case captureMode, modeActive, modePaused, modeCurated, modeActiveHelp, modePausedHelp, modeCuratedHelp
    case usageItems, usageImages, usageDatabase, usageUnavailable
    case clearHistory, clearRange, rangeLast5Minutes, rangeLastHour, rangeLast24Hours, rangeAllTime
    case clearIncludeExempt, clearCounting, clearNothing, clearCountFailed, clearCount, clearDelete, clearDeleting, clearDone, clearRecentTitle, cancel
    case confirmShortenTitle, confirmShorten, confirmBudgetTitle, confirmBudget, deleteAction
    case revealDataFolder

    // About
    case tagline, version, licenceLine, viewLicence, licenceTitle, done
    case copyDiagnostics, diagnosticsCopied, projectPage

    public var key: String { "ui.settings.\(rawValue)" }

    /// The catalogue text. A missing key shows the key itself, which is loud in the UI; the pinning test makes that
    /// unreachable for shipped builds.
    public var text: String { FlotsamStrings.text(forKey: key) ?? key }

    /// The text with `%lld` and `%@` filled from `arguments`, in order. Only counts and sizes and the period labels
    /// above are ever passed (FR-000-06); the argument kinds must match the template, otherwise the template is
    /// returned unfilled rather than handed to `String(format:)`.
    public func text(_ arguments: [MessageArgument]) -> String {
        let template = text
        guard let kinds = FlotsamStrings.formatKinds(in: template), kinds == arguments.map(\.kind) else { return template }
        return FlotsamStrings.formatted(forKey: key, arguments.map { $0.formatArgument() }) ?? template
    }

    /// A template of one count and one label (`confirmShorten`: "{n} items older than {period}"). The label is one
    /// of our own catalogue period names, never user text.
    public func text(count: Int, label: SettingsString) -> String {
        let template = text
        guard FlotsamStrings.formatKinds(in: template) == [.integer, .text] else { return template }
        return FlotsamStrings.formatted(forKey: key, [max(0, count), label.text]) ?? template
    }

    /// The About line "Version {version} ({build})": two text slots filled from the bundle's own version strings.
    public func text(version: String, build: String) -> String {
        let template = text
        guard FlotsamStrings.placeholderKinds(in: template) == [.text, .text] else { return template }
        return String(format: template, version, build)
    }
}
