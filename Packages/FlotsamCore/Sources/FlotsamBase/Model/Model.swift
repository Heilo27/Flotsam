import Foundation

/// Item kinds (FRD-001 FR-001-05..15, FRD-002). One enum, shared by Storage, Payload and the UI.
public enum ItemKind: String, CaseIterable, Sendable {
    case text, richText, link, color, phone, email, image, file, folder, bundle, screenshot

    /// The kinds in the order every type list shows them (FR-003-12 sidebar Types rows; FR-006-22 Shelf type pills). The
    /// one home of that order: `ItemKind` itself stays in storage order, so nothing that persists or counts by kind is
    /// affected. The exhaustive switch makes a new kind a compile error here.
    public static let displayOrder: [ItemKind] = allCases.sorted { displayRank($0) < displayRank($1) }

    private static func displayRank(_ kind: ItemKind) -> Int {
        switch kind {
        case .text: 0
        case .richText: 1
        case .link: 2
        case .color: 3
        case .phone: 4
        case .email: 5
        case .image: 6
        case .screenshot: 7
        case .file: 8
        case .folder: 9
        case .bundle: 10
        }
    }

    /// The kinds stored by reference to files on disk (FRD-001 FR-001-12): their content is the members, not a blob.
    public var referencesFiles: Bool {
        switch self {
        case .file, .folder, .bundle: true
        case .text, .richText, .link, .color, .phone, .email, .image, .screenshot: false
        }
    }
}

public enum CaptureOrigin: Sendable, Equatable {
    case pasteboard, shelfDrop, screenshotFile
}

public struct SourceApp: Sendable, Equatable {
    public let bundleId: String?
    public let name: String?

    public init(bundleId: String?, name: String?) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// Immutable bytes handed from the main-actor poll to the ingest actor (ADR-0004).
public struct CapturedPayload: Sendable, Equatable {
    public let representations: [PasteboardRepresentation]
    public let source: SourceApp?
    public let capturedAt: Date
    public let origin: CaptureOrigin
    /// The pasteboard carried `org.nspasteboard.ConcealedType` (FR-001-04 gate 3). `representations` then holds the
    /// plain text only; ingest seals it instead of classifying it, so it never reaches storage as text.
    public let isConcealed: Bool

    public init(
        representations: [PasteboardRepresentation], source: SourceApp?, capturedAt: Date, origin: CaptureOrigin,
        isConcealed: Bool = false
    ) {
        self.representations = representations
        self.source = source
        self.capturedAt = capturedAt
        self.origin = origin
        self.isConcealed = isConcealed
    }
}

public struct ChordModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ChordModifiers(rawValue: 1 << 0)
    public static let control = ChordModifiers(rawValue: 1 << 1)
    public static let option = ChordModifiers(rawValue: 1 << 2)
    public static let shift = ChordModifiers(rawValue: 1 << 3)
}

/// A key chord. Validation rules (FR-005-02) live in Shortcuts; this is only the value.
public struct Chord: Sendable, Hashable {
    public let keyCode: UInt16
    public let modifiers: ChordModifiers

    public init(keyCode: UInt16, modifiers: ChordModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// FR-005-02 (a): a global shortcut must carry ⌘ or ⌃. The one home of that test: `ChordBinding.isUsable` (stored
    /// data) and Shortcuts' `ChordValidator` (recording) both call it (Rule 9).
    public var hasCommandOrControl: Bool { !modifiers.isDisjoint(with: [.command, .control]) }

    /// Modifier keys and fn: key codes that are never a shortcut's key (FR-005-02 b, FR-005-04).
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// Letters, digits, punctuation (US ANSI key codes), Space, Return, Tab, Escape, Delete, arrows, F1 to F20.
    static let allowedKeyCodes: Set<UInt16> = {
        var codes: Set<UInt16> = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
            31, 32, 33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50,
        ]
        codes.formUnion([36, 48, 49, 51, 53, 123, 124, 125, 126])  // Return Tab Space Delete Escape, arrows
        codes.formUnion([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90])  // F1-F20
        return codes
    }()

    /// FR-005-02 (b): the key is a real, non-modifier key. The one home of that test, beside `hasCommandOrControl`:
    /// `ChordBinding.isUsable` (stored data, FR-008-02) and Shortcuts' `ChordValidator` (recording) both call it (Rule 9).
    public var hasUsableKey: Bool { !Self.modifierKeyCodes.contains(keyCode) && Self.allowedKeyCodes.contains(keyCode) }
}

/// The one definition of "matches" for search (FR-003-09): case- and diacritic-insensitive.
/// Used by the Storage writer (to build `searchText`) and by Library (to build query tokens), so they cannot drift.
public enum SearchNormalizer {
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Splits on whitespace and normalises each token; empty query gives no tokens.
    public static func tokens(from query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
    }
}
