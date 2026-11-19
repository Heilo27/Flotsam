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
    /// The one home of how a stored boolean reads (FR-008-02). We write "true"/"false", but `UserDefaults` also hands
    /// back its own native boolean spellings as strings: `defaults write -bool` and `.set(true)` read as "1"/"0", and a
    /// `-key NO` launch argument as "YES"/"NO". Those are a valid boolean, not corrupt data, so they must not raise
    /// SET-DAT-001 (TASK-454). Exactly those spellings: anything else ("maybe", "2", "yes", "TRUE ", "") is invalid.
    public init?(persisted: String) {
        switch persisted {
        case "true", "YES", "1": self = true
        case "false", "NO", "0": self = false
        default: return nil
        }
    }
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

    // The menu-bar Pause/Resume Capture toggle (label and resulting mode) is defined once, in
    // `MenuBarModel.captureToggle(for:)` (FR-008-16); it is deliberately not a property here (Rule 9).

    // Save Clipboard (FRD-005) and Shelf drops (FRD-006) work in every mode, so there is deliberately no property
    // for them: a gate that always answers "yes" would only invite someone to make it answer "no".
}
public enum RetentionPreset: String, SettingValue, CaseIterable { case d7, d30, d90, y1, forever }
public enum ImageBudget: String, SettingValue, CaseIterable { case mib500, gib2, gib10, unlimited }
public enum ImageQuality: String, SettingValue, CaseIterable { case original, balanced, efficient }
public enum ShelfPlacement: String, SettingValue, CaseIterable { case rightEdge, leftEdge, bottomEdge, menuBar, topCenter }
public enum LibraryViewMode: String, SettingValue, CaseIterable { case list, grid }

/// The Library's window layout (`library.layout`, FR-003-06): Standard has the optional preview pane on the right,
/// Compact is sidebar and list only, in a nearly square window.
public enum LibraryLayoutMode: String, SettingValue, CaseIterable { case standard, compact }

/// The Settings window's panes in display order (FR-008-03). Also the value of `settings.lastPane`.
public enum SettingsPane: String, SettingValue, CaseIterable { case general, shortcuts, types, triggers, privacy, storage, tips, about }

/// The Library's panel background (`library.background`, FR-003-21): follow the system appearance, or force light or dark.
public enum LibraryBackground: String, SettingValue, CaseIterable { case system, light, dark }

/// How the Library opens (`library.previewPreset`, FR-003-04): Closed is the original behaviour; Open starts with the
/// preview showing; Roomy also opens at least `roomyFloor` so the preview has room. Compact ignores every preset: it has
/// no preview column and stays one glance (FR-003-06). The two rules below are the one home of what a preset does.
public enum LibraryPreviewPreset: String, SettingValue, CaseIterable {
    case closed, open, roomy

    /// The size Roomy raises the remembered Standard size to. The remembered size itself is not changed.
    public static let roomyFloor = PanelSize(width: 960, height: 600)

    public func opensPreview(in layout: LibraryLayoutMode) -> Bool {
        layout == .standard && self != .closed
    }

    /// `size` as the panel opens: raised to `roomyFloor` by Roomy in Standard, otherwise as remembered.
    public func openingSize(from size: PanelSize, in layout: LibraryLayoutMode) -> PanelSize {
        guard layout == .standard, self == .roomy else { return size }
        return PanelSize(width: max(size.width, Self.roomyFloor.width), height: max(size.height, Self.roomyFloor.height))
    }
}

/// Which display the Library opens on (`library.display`, FR-003-03): the one under the pointer, or the one holding the
/// focused window of the app that was frontmost (the paste target).
public enum LibraryDisplay: String, SettingValue, CaseIterable { case pointer, focus }

/// The item types the Library's Types rows and the Shelf's pills show, in order (`library.types`, FR-003-12). A type
/// absent from the list is hidden there; its items stay in All and in search. Persisted as a JSON list of kind names.
public struct TypeOrder: SettingValue {
    public var kinds: [ItemKind]

    public init(_ kinds: [ItemKind]) { self.kinds = kinds }

    /// Every type, in `ItemKind.displayOrder`.
    public static let `default` = TypeOrder(ItemKind.displayOrder)

    public init?(persisted: String) {
        guard let data = persisted.data(using: .utf8), let names = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        let kinds = names.compactMap(ItemKind.init(rawValue:))
        // An unknown name or a repeated type is not something the Types pane could have written.
        guard kinds.count == names.count, Set(kinds).count == kinds.count else { return nil }
        self.kinds = kinds
    }

    public var persisted: String {
        // Encoding an array of strings cannot fail; the empty-list fallback keeps this non-throwing.
        guard let data = try? JSONEncoder().encode(kinds.map(\.rawValue)), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The types to show: the listed ones, in list order, that have at least one item. The one place the sidebar and the
    /// Shelf's pills apply the setting.
    public func shown(counts: [ItemKind: Int]) -> [ItemKind] { kinds.filter { (counts[$0] ?? 0) > 0 } }
}

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
    /// The structural half of FR-005-02: a stored chord must carry ⌘ or ⌃ and a real, non-modifier key. The full binding rules (reserved list,
    /// system hotkeys) are FRD-005's and run when a chord is recorded; this only rejects stored data that no recorder
    /// could have produced.
    var isUsable: Bool {
        switch self {
        case .none: true
        case .chord(let chord): chord.hasCommandOrControl && chord.hasUsableKey
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

    /// FR-008-11: copies from these apps are never stored. The default is empty: password managers' concealed copies are
    /// kept encrypted (FRD-001 FR-001-04 gate 3), so the list is only what the user chooses to exclude. Identifiers the
    /// user types are unverified, so a wrong one silently fails to protect that app; `passwordManagerPreset` holds only
    /// identifiers verified against a source (FRD-008 §9 item 2).
    public static let defaultIgnoredApps = BundleIdentifierList([])

    /// The six password-manager apps the list held by default before secure clips (FR-008-11). Kept only so
    /// `IgnoredAppsMigration` can recognise a list the user never customised.
    static let retiredIgnoredAppsDefault = BundleIdentifierList([
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ])

    /// FR-008-11: the "Add Password Managers" preset, the one home of the list. Static and never fetched. Every
    /// identifier was checked against the vendor's or Homebrew's published bundle identifier, or the app's own
    /// Info.plist (FRD-008 section 9 item 2). An app not listed here, or installed under another identifier, is added
    /// by hand.
    public static let passwordManagerPreset = BundleIdentifierList([
        "com.apple.Passwords",  // Passwords (macOS 15+, /System/Applications)
        "com.apple.keychainaccess",  // Keychain Access
        "com.1password.1password",  // 1Password 8
        "com.bitwarden.desktop",  // Bitwarden
        "org.keepassxc.keepassxc",  // KeePassXC
        "me.proton.pass.electron",  // Proton Pass
        "com.nordsec.nordpass",  // NordPass
        "com.keepersecurity.passwordmanager",  // Keeper
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

/// A size in points (`library.panelSize`, `library.compactPanelSize`).
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
