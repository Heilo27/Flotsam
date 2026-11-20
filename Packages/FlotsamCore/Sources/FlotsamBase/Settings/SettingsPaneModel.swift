import Foundation

/// Pane identity, order, icon and title (FR-008-03, DESIGN §3.3). Order is the enum's declaration order.
extension SettingsPane {
    public var title: SettingsString {
        switch self {
        case .general: .paneGeneral
        case .library: .paneLibrary
        case .shortcuts: .paneShortcuts
        case .types: .paneTypes
        case .triggers: .paneTriggers
        case .privacy: .panePrivacy
        case .storage: .paneStorage
        case .tips: .paneTips
        case .about: .paneAbout
        }
    }

    /// SF Symbol name for the toolbar item (DESIGN §7 icon table).
    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .library: "books.vertical"
        case .shortcuts: "keyboard"
        case .types: "square.grid.2x2"
        case .triggers: "bolt"
        case .privacy: "hand.raised"
        case .storage: "internaldrive"
        case .tips: "lightbulb"
        case .about: "info.circle"
        }
    }

    /// The pane the window reopens on (`settings.lastPane`); the registry already substitutes the default for a stored
    /// value that is not a pane id.
    public static func lastOpened(in settings: SettingsStore) -> SettingsPane {
        settings.value(SettingKeys.settingsLastPane)
    }

    public func remember(in settings: SettingsStore) {
        settings.set(self, for: SettingKeys.settingsLastPane)
    }
}

// MARK: - General

public enum ShelfRevealRule {
    /// "Reveal on edge hover" and "Show edge bar" are disabled when the Shelf is off or
    /// placed in the menu bar (FR-008-04); both need an edge to sit at.
    public static func isEnabled(shelfEnabled: Bool, placement: ShelfPlacement) -> Bool {
        shelfEnabled && placement != .menuBar
    }
}

/// How the Launch at Login row looks for a status read from macOS (FR-008-15): `.enabled` is on, `.requiresApproval` is
/// on with a caption and a Login Items button, anything else is off.
public struct LoginItemPresentation: Equatable, Sendable {
    public let isOn: Bool
    public let caption: SettingsString?
    public let showsLoginItemsButton: Bool

    public init(status: LoginItemStatus) {
        switch status {
        case .enabled:
            isOn = true; caption = nil; showsLoginItemsButton = false
        case .requiresApproval:
            isOn = true; caption = .loginApprovalCaption; showsLoginItemsButton = true
        case .off:
            isOn = false; caption = nil; showsLoginItemsButton = false
        }
    }
}

extension LibraryLayoutMode {
    public var label: SettingsString {
        switch self {
        case .standard: .layoutStandard
        case .compact: .layoutCompact
        }
    }
}

extension LibraryBackground {
    public var label: SettingsString {
        switch self {
        case .system: .backgroundSystem
        case .light: .backgroundLight
        case .dark: .backgroundDark
        }
    }
}

extension LibraryPreviewPreset {
    public var label: SettingsString {
        switch self {
        case .closed: .presetClosed
        case .open: .presetOpen
        case .roomy: .presetRoomy
        }
    }
}

extension LibraryDisplay {
    public var label: SettingsString {
        switch self {
        case .pointer: .displayPointer
        case .focus: .displayFocus
        }
    }
}

extension ShelfPlacement {
    public var label: SettingsString {
        switch self {
        case .rightEdge: .placementRightEdge
        case .leftEdge: .placementLeftEdge
        case .bottomEdge: .placementBottomEdge
        case .menuBar: .placementMenuBar
        case .topCenter: .placementTopCenter
        }
    }
}

// MARK: - Permissions (Triggers, Privacy)

/// One permission row: state, what it enables, and which button opens System Settings (FR-008-13 rule c).
public struct PermissionRow: Equatable, Sendable, Identifiable {
    public let kind: PermissionKind
    public let isGranted: Bool

    public var id: PermissionKind { kind }

    public var name: SettingsString {
        switch kind {
        case .accessibility: .permissionAccessibility
        case .inputMonitoring: .permissionInputMonitoring
        }
    }

    public var enables: SettingsString {
        switch kind {
        case .accessibility: .permissionAccessibilityHelp
        case .inputMonitoring: .permissionInputMonitoringHelp
        }
    }

    /// Status is words, never colour alone (FR-008-17).
    public var status: SettingsString { isGranted ? .permissionGranted : .permissionNotGranted }

    /// Reads every permission fresh from the probe; never cached (FR-008-13 rule b).
    public static func current(probe: any PermissionProbe) -> [PermissionRow] {
        PermissionKind.allCases.map { PermissionRow(kind: $0, isGranted: probe.isGranted($0)) }
    }
}

// MARK: - Storage

extension RetentionPreset {
    public var label: SettingsString {
        switch self {
        case .d7: .retention7Days
        case .d30: .retention30Days
        case .d90: .retention90Days
        case .y1: .retention1Year
        case .forever: .retentionForever
        }
    }

    /// Longer-lived presets sort higher; Forever is the longest. Declaration order is the order of the length of time
    /// kept, which `SettingsStorageTests` pins.
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Moving to a shorter preset can delete items, so it asks first (FR-007-09).
    public func isShorter(than other: RetentionPreset) -> Bool { rank < other.rank }
}

extension ImageBudget {
    public var label: SettingsString {
        switch self {
        case .mib500: .budget500MB
        case .gib2: .budget2GB
        case .gib10: .budget10GB
        case .unlimited: .budgetUnlimited
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Lowering the budget can delete images, so it asks first (FR-007-09).
    public func isLower(than other: ImageBudget) -> Bool { rank < other.rank }
}

extension ImageQuality {
    public var label: SettingsString {
        switch self {
        case .original: .qualityOriginal
        case .balanced: .qualityBalanced
        case .efficient: .qualityEfficient
        }
    }

    public var caption: SettingsString {
        switch self {
        case .original: .qualityOriginalHelp
        case .balanced: .qualityBalancedHelp
        case .efficient: .qualityEfficientHelp
        }
    }
}

extension CaptureMode {
    public var label: SettingsString {
        switch self {
        case .active: .modeActive
        case .paused: .modePaused
        case .curated: .modeCurated
        }
    }

    public var caption: SettingsString {
        switch self {
        case .active: .modeActiveHelp
        case .paused: .modePausedHelp
        case .curated: .modeCuratedHelp
        }
    }
}

/// What a change to retention or the image budget does (FR-007-09): a change that cannot delete is applied at once;
/// a reducing change asks only when the preview count is above zero. Cancel reverts the control.
public enum StorageChangeFlow: Equatable, Sendable {
    case applyNow
    case confirm(count: Int)

    /// Whether the preview has to be fetched at all: only a reduction can delete anything.
    public static func needsPreview(retention new: RetentionPreset, from old: RetentionPreset) -> Bool { new.isShorter(than: old) }
    public static func needsPreview(budget new: ImageBudget, from old: ImageBudget) -> Bool { new.isLower(than: old) }

    public static func after(previewCount count: Int) -> StorageChangeFlow { count > 0 ? .confirm(count: count) : .applyNow }
}
