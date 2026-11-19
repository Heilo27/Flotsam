import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation

/// What the Library reads from storage. `FlotsamDatabase` conforms below; tests use a fake, so view-model tests need no
/// database.
public protocol LibraryDataSource: Sendable {
    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage>
    func sidebarCounts() async -> FlotsamResult<SidebarCounts>
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent>
    func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data?
    /// Called when the last Library or Shelf panel closes (FR-003-13).
    func releaseMemory() async
}

extension FlotsamDatabase: LibraryDataSource {}

/// The paste sequence as the Library calls it. `PasteService` conforms below.
@MainActor
public protocol PastePerforming {
    func paste(itemId: UUID, mode: PasteMode, target: FrontmostApp?, host: any PasteHost) async -> FlotsamResult<PasteOutcome>
}

extension PasteService: PastePerforming {}

/// The settings the Library owns (FR-003-03, FR-003-06, FR-003-07), behind one seam so the Settings UI (FRD-008) and the
/// panel read and write the same keys.
public protocol LibraryPreferences: Sendable {
    var viewMode: LibraryViewMode { get nonmutating set }
    /// The Standard layout's remembered size.
    var panelSize: PanelSize { get nonmutating set }
    /// The Compact layout's remembered size, kept apart so switching layouts never overwrites the other one.
    var compactPanelSize: PanelSize { get nonmutating set }
    var layout: LibraryLayoutMode { get nonmutating set }
    /// The sort FR-004-12 remembers: ⌘S writes it, the panel reads it on open.
    var sort: LibrarySort { get nonmutating set }
}

extension LibraryPreferences {
    /// The remembered size for `layout`; the one place that picks between the two size keys.
    public func panelSize(for layout: LibraryLayoutMode) -> PanelSize {
        switch layout {
        case .standard: panelSize
        case .compact: compactPanelSize
        }
    }

    public func setPanelSize(_ size: PanelSize, for layout: LibraryLayoutMode) {
        switch layout {
        case .standard: panelSize = size
        case .compact: compactPanelSize = size
        }
    }
}

public struct SettingsLibraryPreferences: LibraryPreferences {
    private let settings: SettingsStore

    public init(settings: SettingsStore) { self.settings = settings }

    public var viewMode: LibraryViewMode {
        get { settings.value(SettingKeys.libraryViewMode) }
        nonmutating set { settings.set(newValue, for: SettingKeys.libraryViewMode) }
    }

    public var panelSize: PanelSize {
        get { settings.value(SettingKeys.libraryPanelSize) }
        nonmutating set { settings.set(newValue, for: SettingKeys.libraryPanelSize) }
    }

    public var compactPanelSize: PanelSize {
        get { settings.value(SettingKeys.libraryCompactPanelSize) }
        nonmutating set { settings.set(newValue, for: SettingKeys.libraryCompactPanelSize) }
    }

    public var layout: LibraryLayoutMode {
        get { settings.value(SettingKeys.libraryLayout) }
        nonmutating set { settings.set(newValue, for: SettingKeys.libraryLayout) }
    }

    public var sort: LibrarySort {
        get { settings.value(SettingKeys.librarySort) }
        nonmutating set { settings.set(newValue, for: SettingKeys.librarySort) }
    }
}

/// Everything the view model asks of its surroundings that is not storage or paste: error reporting, Finder, Settings,
/// and the FRD-004/005 commands that live elsewhere. Defaults are inert so a test sets only what it observes.
public struct LibraryEffects {
    public var report: @MainActor (FlotsamError) -> Void
    /// ⌘R: the file paths of the selected item, to reveal in Finder (platform adapter).
    public var reveal: @MainActor ([String]) -> Void
    public var openSettings: @MainActor () -> Void
    /// Commands owned by FRD-004 and FRD-005 (pin, tags, note, edit, delete, sort, ungroup, shortcut editor). The
    /// Library only owns the keys (FR-003-08); the owner of each command supplies the behaviour.
    public var external: @MainActor (LibraryExternalCommand, [UUID]) -> Void
    /// Whether Accessibility is granted, for the footer's copy-only notice (FR-003-18).
    public var isAccessibilityTrusted: @MainActor () -> Bool
    /// The footer's "Enable" button (FR-008-14): opens the Accessibility pane of System Settings through the shared
    /// `PermissionProbe`, the same path as onboarding and the Triggers pane.
    public var openAccessibilitySettings: @MainActor () -> Void

    public init(
        report: @escaping @MainActor (FlotsamError) -> Void = { _ in },
        reveal: @escaping @MainActor ([String]) -> Void = { _ in },
        openSettings: @escaping @MainActor () -> Void = {},
        external: @escaping @MainActor (LibraryExternalCommand, [UUID]) -> Void = { _, _ in },
        isAccessibilityTrusted: @escaping @MainActor () -> Bool = { true },
        openAccessibilitySettings: @escaping @MainActor () -> Void = {}
    ) {
        self.report = report
        self.reveal = reveal
        self.openSettings = openSettings
        self.external = external
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.openAccessibilitySettings = openAccessibilitySettings
    }
}
