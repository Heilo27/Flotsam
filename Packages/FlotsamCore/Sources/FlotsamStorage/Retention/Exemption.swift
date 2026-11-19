import FlotsamBase
import Foundation
import GRDB

/// The one definition of "exempt" (FR-007-10), as SQL. The time sweep, budget eviction and Clear History all splice
/// these in, so they cannot disagree about which items are protected. Exemption is derived from `pinned`, `trigger`
/// and `hotkeyCode`; there is deliberately no stored flag that could drift from them (FR-007-03).
enum Exemption {
    static let sqlPredicate = "(pinned = 1 OR \"trigger\" IS NOT NULL OR hotkeyCode IS NOT NULL)"
    static let notExemptSQL = "(pinned = 0 AND \"trigger\" IS NULL AND hotkeyCode IS NULL)"
    /// After the last exemption is released, the item stays safe from automatic deletion for this long (FR-007-10).
    static let graceMillis: Int64 = TimeSpan.dayMillis

    /// What an automatic pass (time sweep, budget eviction) may delete as far as exemption goes: not exempt, and not
    /// within the grace window after an exemption was released (FR-007-09, FR-007-08). Exactly one `?`, bound to
    /// `graceCutoff(now:)`. Clear History uses `notExemptSQL` alone: it is the user's explicit, counted action.
    static let autoDeletableSQL = "(\(notExemptSQL) AND (exemptReleasedAt IS NULL OR exemptReleasedAt < ?))"

    /// `autoDeletableSQL` bound to `now`, as the guard the automatic passes re-apply inside the delete transaction.
    static func autoDeletableGuard(now: Int64) -> DeletionGuard {
        DeletionGuard(sql: autoDeletableSQL, arguments: [graceCutoff(now: now)])
    }

    /// The value for `autoDeletableSQL`'s placeholder: an `exemptReleasedAt` older than this is out of grace.
    static func graceCutoff(now: Int64) -> Int64 { now - graceMillis }
}

/// A change to one of the three things that make an item exempt (FR-007-10). Pin, trigger and hotkey edits all go
/// through `FlotsamDatabase.applyExemptionEdit`, so `exemptReleasedAt` is maintained in exactly one place.
public enum ExemptionEdit: Sendable, Equatable {
    case setPinned(Bool)
    /// nil removes the trigger. The unique case-insensitive index (FR-007-03) rejects a clash; callers validate first.
    case setTrigger(String?)
    /// nil removes the hotkey.
    case setHotkey(Chord?)

    /// Whether the edit gives the item a trigger or a hotkey (not clears one). A secure clip refuses these.
    var setsBinding: Bool {
        switch self {
        case .setPinned: false
        case .setTrigger(let trigger): trigger != nil
        case .setHotkey(let chord): chord != nil
        }
    }
}

extension FlotsamDatabase {
    /// Applies a pin, trigger or hotkey change and keeps `exemptReleasedAt` right in the same transaction
    /// (FR-007-10): set to now when the edit removes the item's last exemption, cleared when the item is exempt again.
    ///
    /// Why here and not in each caller: pin lives in Library, trigger in Triggers, hotkey in Shortcuts. If each set
    /// its own column, any one forgetting the grace stamp would let the sweep delete a just-unpinned item. The
    /// before/after test uses `Exemption.sqlPredicate` itself, so "last exemption" has one definition.
    ///
    /// Returns false when the item no longer exists (deleted by a racing sweep): nothing to edit, not a failure.
    ///
    /// A secure clip takes no trigger and no hotkey (FR-005-09): setting either is rejected with `TRG-VAL-006` and
    /// nothing changes. Clearing one is allowed (a secure row has none, so it is a no-op), and pinning is allowed.
    public func applyExemptionEdit(_ edit: ExemptionEdit, to id: UUID) async -> FlotsamResult<Bool> {
        let now = clock.now().epochMillis
        let result = await organizeWrite { db in try Self.applyExemptionEdit(db, edit: edit, id: id, now: now) }
        // The registry and the trigger snapshot rebuild from this; published after the commit (FR-005-22).
        if case .success(true) = result { events.publish(.itemsChanged) }
        return result
    }

    /// The body of `applyExemptionEdit`, for a caller that already holds a write transaction and edits several items in
    /// it (FR-004-01 multi-selection pin). The only place `exemptReleasedAt` is maintained, and the only place a
    /// secure clip is refused a trigger or hotkey (`OrganizeRejection` carrying `TRG-VAL-006`; the schema trigger
    /// behind it is the last line, not the message).
    static func applyExemptionEdit(_ db: Database, edit: ExemptionEdit, id: UUID, now: Int64) throws -> Bool {
        let key = id.uuidString
        guard let state = try Row.fetchOne(
            db, sql: "SELECT \(Exemption.sqlPredicate) AS exempt, isSecure FROM item WHERE id = ?", arguments: [key])
        else { return false }
        let wasExempt: Bool = state["exempt"]
        let isSecure: Bool = state["isSecure"]
        if isSecure, edit.setsBinding {
            throw OrganizeRejection(error: FlotsamError(
                .trgVal006, "A secure item cannot have a shortcut or trigger", context: [.itemId: .id(id)]))
        }

        switch edit {
        case .setPinned(let pinned):
            try db.execute(sql: "UPDATE item SET pinned = ? WHERE id = ?", arguments: [pinned ? 1 : 0, key])
        case .setTrigger(let trigger):
            try db.execute(sql: "UPDATE item SET \"trigger\" = ? WHERE id = ?", arguments: [trigger, key])
        case .setHotkey(let chord):
            try db.execute(
                sql: "UPDATE item SET hotkeyCode = ?, hotkeyModifiers = ? WHERE id = ?",
                arguments: [chord.map { Int($0.keyCode) }, chord.map { Int($0.modifiers.rawValue) }, key])
        }

        // Exempt after the edit: clear any release stamp. Not exempt: stamp only on the exempt -> not exempt
        // transition, so editing an already-released item does not extend its grace.
        try db.execute(
            sql: """
                UPDATE item SET updatedAt = ?, exemptReleasedAt = CASE
                    WHEN \(Exemption.sqlPredicate) THEN NULL
                    WHEN ? THEN ?
                    ELSE exemptReleasedAt END
                WHERE id = ?
                """,
            arguments: [now, wasExempt, now, key])
        return true
    }
}

extension FlotsamDatabase: ItemBindingSource {
    /// Every stored item hotkey and trigger, for the hotkey registry and the trigger snapshot (FR-005-01, FR-005-12).
    /// Read from the same columns `Exemption` is derived from, so the three can never disagree.
    public func itemBindings() async -> FlotsamResult<ItemBindings> {
        do {
            return .success(try await pool.read { db in
                var bindings = ItemBindings()
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, \"trigger\", hotkeyCode, hotkeyModifiers FROM item WHERE \"trigger\" IS NOT NULL OR hotkeyCode IS NOT NULL")
                for row in rows {
                    guard let id = UUID(uuidString: row["id"] as String) else { continue }
                    if let trigger: String = row["trigger"] { bindings.triggers[id] = trigger }
                    if let code: Int = row["hotkeyCode"], let modifiers: Int = row["hotkeyModifiers"] {
                        bindings.hotkeys[id] = Chord(
                            keyCode: UInt16(truncatingIfNeeded: code), modifiers: ChordModifiers(rawValue: UInt8(truncatingIfNeeded: modifiers)))
                    }
                }
                return bindings
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }
}
