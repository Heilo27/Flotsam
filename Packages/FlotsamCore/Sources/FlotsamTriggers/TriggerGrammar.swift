import Foundation
import FlotsamBase

/// FR-005-08: what a typed trigger may look like, and how two triggers are compared.
///
/// A trigger is a leading ASCII punctuation or symbol character followed by 1-23 ASCII letters, digits, `-` or `_`
/// (2-24 characters in all). The stored trigger must be ASCII, and so must everything typed against it: any typed
/// non-ASCII scalar kills the word (FR-005-11), including one that Unicode normalises to an ASCII character such as
/// the Greek question mark U+037E (which normalises to `;`). Such a character never matches a trigger and is never
/// held as a prefix. The matcher enforces this before it compares anything, so Swift's canonical string equality
/// never gets to fold a typed character.
///
/// Case folding is ASCII only. That is deliberate: it is the same fold as the `item.trigger` column's `COLLATE NOCASE`
/// index, so "is this a duplicate" has one answer in the editor, the matcher snapshot and the database. Full Unicode
/// case folding would disagree with SQLite and could never apply anyway (the grammar is ASCII).
public enum TriggerGrammar {
    public static let minimumLength = 2
    public static let maximumLength = 24

    /// Checks the shape only. Uniqueness needs the other triggers: see `validate(_:among:)`.
    public static func validate(_ text: String) -> FlotsamResult<Void> {
        isWellFormed(text)
            ? .success(())
            : .failure(FlotsamError(.trgVal001, "Trigger does not match the trigger grammar"))
    }

    /// Shape plus the case-insensitive uniqueness rule. `existing` is every other item's trigger; pass the edited
    /// item's own trigger out of it (it may be saved unchanged).
    public static func validate(_ text: String, among existing: some Sequence<String>) -> FlotsamResult<Void> {
        if case .failure(let error) = validate(text) { return .failure(error) }
        let key = canonicalKey(text)
        for other in existing where canonicalKey(other) == key {
            return .failure(FlotsamError(.trgVal002, "Trigger is already used by another item"))
        }
        return .success(())
    }

    /// The comparison key: ASCII letters lowercased, every other scalar untouched.
    public static func canonicalKey(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A, let lower = Unicode.Scalar(scalar.value + 0x20) {
                scalars.append(lower)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func isWellFormed(_ text: String) -> Bool {
        // utf8 bytes, not Characters: a combining sequence such as "e" + U+0301 is one Character but not ASCII.
        let bytes = Array(text.utf8)
        guard bytes.count >= minimumLength, bytes.count <= maximumLength else { return false }
        guard isLeadingSymbol(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy(isBodyCharacter)
    }

    /// ASCII punctuation and symbols: U+0021-2F, 3A-40, 5B-60, 7B-7E.
    private static func isLeadingSymbol(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte)
            || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
    }

    private static func isBodyCharacter(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == 0x2D || byte == 0x5F
    }
}
