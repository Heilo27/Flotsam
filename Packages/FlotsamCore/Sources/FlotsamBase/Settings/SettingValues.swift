import Foundation

/// A setting value with a string persisted form (FRD-008 FR-008-02). `UserDefaultsStore` holds strings only, so every
/// registry type states how it is written and read back. Enums get this for free from their raw value.
public protocol SettingValue: Sendable, Equatable {
    init?(persisted: String)
    var persisted: String { get }
}

extension SettingValue where Self: RawRepresentable, RawValue == String {
    public init?(persisted: String) { self.init(rawValue: persisted) }
    public var persisted: String { rawValue }
}

extension Bool: SettingValue {
    public init?(persisted: String) { self.init(persisted) }
    public var persisted: String { description }
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
public enum ShelfPlacement: String, SettingValue, CaseIterable { case rightEdge, leftEdge, bottomEdge, menuBar }
public enum LibraryViewMode: String, SettingValue, CaseIterable { case list, grid }

/// The Settings window's panes in display order (FR-008-03). Also the value of `settings.lastPane`.
public enum SettingsPane: String, SettingValue, CaseIterable { case general, shortcuts, triggers, privacy, storage, about }

extension LibrarySort: SettingValue {}

/// A shortcut setting: a chord, or none (FR-005-01 lets Save Clipboard and Toggle Shelf stay unbound).
public enum ChordBinding: SettingValue {
    case none
    case chord(Chord)

    public init?(persisted: String) {
        if persisted == "none" { self = .none; return }
        let parts = persisted.split(separator: ":")
        guard parts.count == 2, let keyCode = UInt16(parts[0]), let modifiers = UInt8(parts[1]) else { return nil }
        self = .chord(Chord(keyCode: keyCode, modifiers: ChordModifiers(rawValue: modifiers)))
    }

    public var persisted: String {
        switch self {
        case .none: "none"
        case .chord(let chord): "\(chord.keyCode):\(chord.modifiers.rawValue)"
        }
    }

    /// Single home of the chord-usability rule: FRD-005's recorder reuses this and must not restate it (Rule 9).
    /// The structural half of FR-005-02: a stored chord must carry ⌘ or ⌃. The full binding rules (reserved list,
    /// system hotkeys) are FRD-005's and run when a chord is recorded; this only rejects stored data that no recorder
    /// could have produced.
    var isUsable: Bool {
        switch self {
        case .none: true
        case .chord(let chord): chord.hasCommandOrControl
        }
    }
}

/// A list of application bundle identifiers (ignored apps, trigger-excluded apps).
public struct BundleIdentifierList: SettingValue {
    public var identifiers: [String]

    public init(_ identifiers: [String]) { self.identifiers = identifiers }

    public init?(persisted: String) {
        guard let data = persisted.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        self.identifiers = decoded
    }

    public var persisted: String {
        // Encoding an array of strings cannot fail; the empty-list fallback keeps this non-throwing.
        guard let data = try? JSONEncoder().encode(identifiers), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    var isUsable: Bool { identifiers.allSatisfy { !$0.isEmpty && !$0.contains(where: \.isWhitespace) } }

    /// FR-008-11: copies from these apps are never stored. Bundle identifiers are unverified against real installs
    /// (FRD-008 §9 item 2; spike TASK-009), so a wrong one silently fails to protect that app.
    public static let defaultIgnoredApps = BundleIdentifierList([
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ])

    /// FR-005-13: typed triggers do not expand in these apps. FRD-005 owns the list; it is declared here because the
    /// registry holds every default (FR-008-01).
    public static let defaultTriggerExcludedApps = BundleIdentifierList([
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "io.alacritty",
        "dev.warp.Warp-Stable", "co.zeit.hyper", "com.microsoft.rdc.macos", "com.apple.ScreenSharing",
        "com.parallels.desktop.console", "com.vmware.fusion",
    ])
}

/// The screenshot folder override: none, or a security-scoped bookmark (FR-008-10).
public enum FolderOverride: SettingValue {
    case none
    case bookmark(Data)

    public init?(persisted: String) {
        if persisted.isEmpty { self = .none; return }
        guard let data = Data(base64Encoded: persisted) else { return nil }
        self = .bookmark(data)
    }

    public var persisted: String {
        switch self {
        case .none: ""
        case .bookmark(let data): data.base64EncodedString()
        }
    }

    /// An unresolvable bookmark reads as none (AC-008-02). The resolve error carries nothing the user can act on, so
    /// it is reduced to "not usable" and surfaces as SET-DAT-001.
    var isUsable: Bool {
        switch self {
        case .none: return true
        case .bookmark(let data):
            var stale = false
            return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)) != nil
        }
    }
}

/// A size in points (`library.panelSize`).
public struct PanelSize: SettingValue {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init?(persisted: String) {
        let parts = persisted.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        self.init(width: width, height: height)
    }

    public var persisted: String { "\(width)x\(height)" }

    var isUsable: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }
}

extension FolderOverride {
    /// Validates a chosen folder (exists, is a directory, readable, listable) and stores a security-scoped bookmark of
    /// it (FR-008-10). Any failure is `SET-VAL-001` and the previous value stays with the caller.
    public static func choosing(_ url: URL) -> FlotsamResult<FolderOverride> {
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              manager.isReadableFile(atPath: url.path), (try? manager.contentsOfDirectory(atPath: url.path)) != nil,
              let data = try? url.bookmarkData(options: [.withSecurityScope])
        else { return .failure(FlotsamError(.setVal001, "Chosen screenshot folder is unusable")) }
        return .success(.bookmark(data))
    }

    /// The folder a bookmark points at; nil for `.none` or a bookmark that no longer resolves.
    public var resolvedURL: URL? {
        guard case .bookmark(let data) = self else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
