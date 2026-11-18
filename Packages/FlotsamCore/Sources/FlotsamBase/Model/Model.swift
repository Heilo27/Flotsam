import Foundation

/// Item kinds (FRD-001 FR-001-05..15, FRD-002). One enum, shared by Storage, Payload and the UI.
public enum ItemKind: String, CaseIterable, Sendable {
    case text, richText, link, color, phone, email, image, file, folder, bundle, screenshot

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

    public init(
        representations: [PasteboardRepresentation], source: SourceApp?, capturedAt: Date, origin: CaptureOrigin
    ) {
        self.representations = representations
        self.source = source
        self.capturedAt = capturedAt
        self.origin = origin
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
