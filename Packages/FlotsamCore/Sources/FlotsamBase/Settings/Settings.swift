/// A setting value stored as a string (FRD-008 FR-008-02). Every case's raw value is its persisted form.
public protocol SettingValue: RawRepresentable<String>, Sendable {}

/// One registry row: key, type and default. Rows are declared only in `SettingKeys`.
public struct SettingKey<Value: SettingValue>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public enum CaptureMode: String, SettingValue, CaseIterable {
    case active, paused, curated

    /// Whether the clipboard poll may save copies on its own (FR-007-12). The one definition: Capture asks here
    /// rather than comparing modes, so the semantics cannot drift between callers.
    public var capturesClipboardAutomatically: Bool { self == .active }

    /// Whether screenshot pickup may import (FR-007-12). Paused and Curated both skip import but still advance
    /// `screenshots.lastScanAt`, so nothing taken during the pause is imported on resume.
    public var importsScreenshots: Bool { self == .active }

    /// What the menu-bar item "Pause Capture" / "Resume Capture" does (FR-007-12). Only Paused shows "Resume Capture",
    /// which returns to Active; Active and Curated both show "Pause Capture", which pauses. Curated is chosen in
    /// Settings only, so the menu never produces it. One definition: the menu label and the action both come from
    /// here, so the label can never promise a different mode than the click sets.
    public var isPaused: Bool { self == .paused }
    public var afterMenuToggle: CaptureMode { isPaused ? .active : .paused }

    // Save Clipboard (FRD-005) and Shelf drops (FRD-006) work in every mode, so there is deliberately no property
    // for them: a gate that always answers "yes" would only invite someone to make it answer "no".
}
public enum RetentionPreset: String, SettingValue, CaseIterable { case d7, d30, d90, y1, forever }
public enum ImageBudget: String, SettingValue, CaseIterable { case mib500, gib2, gib10, unlimited }
public enum ImageQuality: String, SettingValue, CaseIterable { case original, balanced, efficient }

/// The settings registry. The skeleton holds the four FRD-007 keys; the other 15 FRD-008 keys join with their FRDs.
public enum SettingKeys {
    public static let captureMode = SettingKey("capture.mode", default: CaptureMode.active)
    public static let storageRetention = SettingKey("storage.retention", default: RetentionPreset.d30)
    public static let storageImageBudget = SettingKey("storage.imageBudget", default: ImageBudget.gib2)
    public static let storageImageQuality = SettingKey("storage.imageQuality", default: ImageQuality.original)
}

public struct SettingReading<Value: SettingValue>: Sendable {
    public let value: Value
    /// True when a stored value was unknown and the default was substituted; the caller raises SET-DAT-001 (AC-008-02).
    public let recoveredFromInvalid: Bool
}

/// The only reader and writer of settings. Change notification (AsyncStream) arrives with the first subscriber.
public struct SettingsStore: Sendable {
    private let store: any KeyValueStore

    public init(store: any KeyValueStore) { self.store = store }

    public func read<Value: SettingValue>(_ key: SettingKey<Value>) -> SettingReading<Value> {
        guard let raw = store.string(forKey: key.name) else {
            return SettingReading(value: key.defaultValue, recoveredFromInvalid: false)
        }
        if let value = Value(rawValue: raw) {
            return SettingReading(value: value, recoveredFromInvalid: false)
        }
        return SettingReading(value: key.defaultValue, recoveredFromInvalid: true)
    }

    public func value<Value: SettingValue>(_ key: SettingKey<Value>) -> Value { read(key).value }

    public func set<Value: SettingValue>(_ value: Value, for key: SettingKey<Value>) {
        store.setString(value.rawValue, forKey: key.name)
    }
}
