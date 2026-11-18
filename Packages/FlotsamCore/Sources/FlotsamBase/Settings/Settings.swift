import Foundation
import os

/// One registry row: key, value type, default, validator and owner FR (FR-008-01). Rows are declared only in
/// `SettingKeys`; a setting without a row there does not exist.
public struct SettingKey<Value: SettingValue>: Sendable {
    public let name: String
    public let defaultValue: Value
    /// The FR that defines what the setting means (the "Owner of meaning" column of FR-008-01).
    public let owner: String
    let validator: @Sendable (Value) -> Bool

    public init(_ name: String, default defaultValue: Value, owner: String, validator: @escaping @Sendable (Value) -> Bool = { _ in true }) {
        self.name = name
        self.defaultValue = defaultValue
        self.owner = owner
        self.validator = validator
    }

    public var descriptor: SettingDescriptor {
        SettingDescriptor(name: name, valueType: String(describing: Value.self), defaultPersisted: defaultValue.persisted, owner: owner)
    }
}

/// A registry row without its generic type, for enumeration (AC-008-01).
public struct SettingDescriptor: Sendable, Equatable {
    public let name: String
    public let valueType: String
    public let defaultPersisted: String
    public let owner: String
}

/// The settings registry (FR-008-01): the single list of every setting key, type and default.
public enum SettingKeys {
    public static let captureMode = SettingKey("capture.mode", default: CaptureMode.active, owner: "FR-007-12")
    public static let screenshotsEnabled = SettingKey("screenshots.enabled", default: true, owner: "FR-002-05")
    public static let screenshotsFolderOverride = SettingKey(
        "screenshots.folderOverride", default: FolderOverride.none, owner: "FR-002-01", validator: { $0.isUsable })
    public static let shelfEnabled = SettingKey("shelf.enabled", default: true, owner: "FR-006-01")
    public static let shelfPlacement = SettingKey("shelf.placement", default: ShelfPlacement.rightEdge, owner: "FR-006-01")
    public static let shelfRevealOnEdgeHover = SettingKey("shelf.revealOnEdgeHover", default: false, owner: "FR-006-01")
    /// Open Library defaults to ⌃⌘V (key code 9 is V).
    public static let shortcutsOpenLibrary = SettingKey(
        "shortcuts.openLibrary", default: ChordBinding.chord(Chord(keyCode: 9, modifiers: [.control, .command])),
        owner: "FR-005-01", validator: { $0.isUsable })
    public static let shortcutsSaveClipboard = SettingKey(
        "shortcuts.saveClipboard", default: ChordBinding.none, owner: "FR-005-01", validator: { $0.isUsable })
    public static let shortcutsToggleShelf = SettingKey(
        "shortcuts.toggleShelf", default: ChordBinding.none, owner: "FR-005-01", validator: { $0.isUsable })
    public static let triggersEnabled = SettingKey("triggers.enabled", default: true, owner: "FR-005-10")
    public static let triggersExcludedApps = SettingKey(
        "triggers.excludedApps", default: BundleIdentifierList.defaultTriggerExcludedApps, owner: "FR-005-13",
        validator: { $0.isUsable })
    public static let privacyIgnoredApps = SettingKey(
        "privacy.ignoredApps", default: BundleIdentifierList.defaultIgnoredApps, owner: "FR-008-11", validator: { $0.isUsable })
    public static let storageRetention = SettingKey("storage.retention", default: RetentionPreset.d30, owner: "FR-007-09")
    public static let storageImageBudget = SettingKey("storage.imageBudget", default: ImageBudget.gib2, owner: "FR-007-08")
    public static let storageImageQuality = SettingKey("storage.imageQuality", default: ImageQuality.original, owner: "FR-007-08")
    public static let librarySort = SettingKey("library.sort", default: LibrarySort.recent, owner: "FR-004-12")
    public static let libraryViewMode = SettingKey("library.viewMode", default: LibraryViewMode.list, owner: "FR-003-07")
    public static let libraryPanelSize = SettingKey(
        "library.panelSize", default: PanelSize(width: 760, height: 480), owner: "FR-003-03", validator: { $0.isUsable })
    public static let onboardingCompleted = SettingKey("onboarding.completed", default: false, owner: "FR-008-12")
    public static let settingsLastPane = SettingKey("settings.lastPane", default: SettingsPane.general, owner: "FR-008-03")

    /// Every row, in the order of the FR-008-01 table. A test pins this list to the table and to the source.
    public static let all: [SettingDescriptor] = [
        captureMode.descriptor, screenshotsEnabled.descriptor, screenshotsFolderOverride.descriptor,
        shelfEnabled.descriptor, shelfPlacement.descriptor, shelfRevealOnEdgeHover.descriptor,
        shortcutsOpenLibrary.descriptor, shortcutsSaveClipboard.descriptor, shortcutsToggleShelf.descriptor,
        triggersEnabled.descriptor, triggersExcludedApps.descriptor, privacyIgnoredApps.descriptor,
        storageRetention.descriptor, storageImageBudget.descriptor, storageImageQuality.descriptor,
        librarySort.descriptor, libraryViewMode.descriptor, libraryPanelSize.descriptor,
        onboardingCompleted.descriptor, settingsLastPane.descriptor,
    ]
}

public struct SettingReading<Value: SettingValue>: Sendable {
    public let value: Value
    /// True when a stored value failed its validator and the default was substituted (AC-008-02).
    public let recoveredFromInvalid: Bool
}

/// A change event: the key and its new value in persisted form (FR-008-02). Typed streams come from `changes(of:)`.
public struct SettingChange: Sendable, Equatable {
    public let name: String
    public let persisted: String
}

/// The only reader and writer of settings.
///
/// Change delivery mirrors `ItemEventBus`: handlers run inline on the writer's executor, so an effect (a hotkey
/// re-registering, the menu icon) is in place before `set` returns. Copies of a store share one hub, so any copy sees
/// every change.
public struct SettingsStore: Sendable {
    private struct HubState {
        var handlers: [UUID: @Sendable (SettingChange) -> Void] = [:]
        var reportedInvalid: Set<String> = []
    }

    private let store: any KeyValueStore
    private let hub = OSAllocatedUnfairLock(initialState: HubState())
    private let onInvalid: (@Sendable (_ keyName: String) -> Void)?

    /// `onInvalid` is called once per launch per key when a stored value was replaced by its default; the composition
    /// root raises SET-DAT-001 there (FR-008-02).
    public init(store: any KeyValueStore, onInvalid: (@Sendable (_ keyName: String) -> Void)? = nil) {
        self.store = store
        self.onInvalid = onInvalid
    }

    /// Reads a value. A stored value that fails to parse or fails its validator is overwritten with the default
    /// and the default is returned with `recoveredFromInvalid` set; the first such read per key also calls `onInvalid`.
    public func read<Value: SettingValue>(_ key: SettingKey<Value>) -> SettingReading<Value> {
        guard let raw = store.string(forKey: key.name) else {
            return SettingReading(value: key.defaultValue, recoveredFromInvalid: false)
        }
        if let value = Value(persisted: raw), key.validator(value) {
            return SettingReading(value: value, recoveredFromInvalid: false)
        }
        // Rewrite the default rather than removing the key, so `defaults read` shows it (AC-008-02, OC-8011).
        store.setString(key.defaultValue.persisted, forKey: key.name)
        let firstTime = hub.withLock { $0.reportedInvalid.insert(key.name).inserted }
        if firstTime { onInvalid?(key.name) }
        return SettingReading(value: key.defaultValue, recoveredFromInvalid: true)
    }

    public func value<Value: SettingValue>(_ key: SettingKey<Value>) -> Value { read(key).value }

    /// Stores `value` and delivers the change. The caller is the settings control that made the change; a failed apply
    /// must not call this (FR-008-02: the control reverts). Writing never reads, so it does not count as a read of the key.
    public func set<Value: SettingValue>(_ value: Value, for key: SettingKey<Value>) {
        store.setString(value.persisted, forKey: key.name)
        let change = SettingChange(name: key.name, persisted: value.persisted)
        // Snapshot under the lock, call outside it: a handler may subscribe or unsubscribe without deadlocking.
        let handlers = hub.withLock { Array($0.handlers.values) }
        for handler in handlers { handler(change) }
    }

    /// Registers a handler for every change; call the returned closure to unsubscribe.
    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (SettingChange) -> Void) -> @Sendable () -> Void {
        let token = UUID()
        hub.withLock { $0.handlers[token] = handler }
        return { [hub] in hub.withLock { $0.handlers[token] = nil } }
    }

    /// The new values of one key, as they are written. Does not replay the current value.
    public func changes<Value: SettingValue>(of key: SettingKey<Value>) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let unsubscribe = subscribe { change in
                guard change.name == key.name, let value = Value(persisted: change.persisted) else { return }
                continuation.yield(value)
            }
            continuation.onTermination = { _ in unsubscribe() }
        }
    }
}
