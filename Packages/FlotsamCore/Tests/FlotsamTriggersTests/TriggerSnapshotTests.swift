import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// FR-005-12 snapshot, FR-005-22 lifecycle.
@Suite struct TriggerSnapshotTests {
    private let a = UUID(), b = UUID(), c = UUID()

    private func snapshot(_ triggers: [UUID: String]) -> TriggerSnapshot {
        TriggerSnapshot(bindings: ItemBindings(triggers: triggers))
    }

    @Test func lookupUsesTheCanonicalKey() {
        let s = snapshot([a: ";Sig"])
        #expect(s.itemId(forKey: TriggerGrammar.canonicalKey(";SIG")) == a)
        #expect(s.itemId(forKey: ";nope") == nil)
    }

    @Test func invalidTriggersAreSkipped() {
        let s = snapshot([a: "sig", b: ";", c: ";ok"])
        #expect(s.count == 1)
        #expect(s.itemId(forKey: ";ok") == c)
    }

    @Test func collidingTriggersAreBothDroppedBecauseAMatchMustBeExactlyOneItem() {
        let s = snapshot([a: ";dup", b: ";DUP", c: ";fine"])
        #expect(s.count == 1)
        #expect(s.itemId(forKey: ";dup") == nil)
    }

    @Test func deletingItemsRemovesThemSynchronously() {
        let store = TriggerSnapshotStore()
        store.replace(snapshot([a: ";aa", b: ";bb"]), token: store.beginRebuild())
        store.remove(itemIds: [a])
        #expect(store.policy.triggers.itemId(forKey: ";aa") == nil)
        #expect(store.policy.triggers.itemId(forKey: ";bb") == b)
    }

    @Test func aRebuildStartedBeforeADeleteCannotResurrectTheDeletedTrigger() {
        let store = TriggerSnapshotStore()
        store.replace(snapshot([a: ";aa", b: ";bb"]), token: store.beginRebuild())
        let token = store.beginRebuild()  // a rebuild begins and reads the database...
        store.remove(itemIds: [a])  // ...a delete lands before it finishes...
        // ...its result still installs (FR-005-22: the delete drops only its own trigger) but without the deleted one
        #expect(store.replace(snapshot([a: ";aa", b: ";bb", c: ";cc"]), token: token))
        #expect(store.policy.triggers.itemId(forKey: ";aa") == nil)
        #expect(store.policy.triggers.itemId(forKey: ";bb") == b)
        #expect(store.policy.triggers.itemId(forKey: ";cc") == c)
    }

    @Test func theNewestRebuildWinsOverAnOlderOne() {
        let store = TriggerSnapshotStore()
        let old = store.beginRebuild()
        let new = store.beginRebuild()
        #expect(store.replace(snapshot([b: ";bb"]), token: new))
        #expect(store.replace(snapshot([a: ";aa"]), token: old) == false)
        #expect(store.policy.triggers.itemId(forKey: ";bb") == b)
    }

    @Test func excludedAppsSurviveASnapshotReplace() {
        let store = TriggerSnapshotStore()
        store.setExcludedApps(["com.apple.Terminal"])
        store.replace(snapshot([a: ";aa"]), token: store.beginRebuild())
        #expect(store.policy.excludedApps == ["com.apple.Terminal"])
    }
}
