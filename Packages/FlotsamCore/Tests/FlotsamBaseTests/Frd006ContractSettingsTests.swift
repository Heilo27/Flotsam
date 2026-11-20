import Foundation
import Testing
@testable import FlotsamBase

/// FRD-006 oracle contract tests, settings and menu area (OC-6001, 6002, 6003, 6006, 6119).
/// Expected values are literals from the oracle (key names, default values, row lists), never `SettingKeys` constants
/// used on the expected side.
@Suite struct Frd006ContractSettingsTests {
    private func toggleShelfRows(_ entries: [MenuEntry]) -> Int {
        entries.filter { if case .toggleShelf = $0 { true } else { false } }.count
    }

    // OC-6001. given a fresh install (nothing stored), then the Shelf is on, placement is right edge, hover reveal is
    // off, and the menu lists Toggle Shelf. Red if any default flips or the menu drops the row on a fresh store.
    @Test("OC-6001 a fresh install defaults to Shelf on, Right Edge, hover reveal off, and the menu shows Toggle Shelf")
    func oc6001_freshDefaults() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        #expect(settings.value(SettingKeys.shelfEnabled) == true)
        #expect(settings.value(SettingKeys.shelfPlacement) == ShelfPlacement.rightEdge)
        #expect(settings.value(SettingKeys.shelfRevealOnEdgeHover) == false)
        #expect(toggleShelfRows(MenuBarModel.entries(settings: settings)) == 1)
    }

    // OC-6001 persisted form: the default raw values on the registry rows are the literals the oracle names.
    @Test("OC-6001 the registry rows persist the defaults as true, rightEdge and false")
    func oc6001_registryDefaultsAreLiterals() {
        let rows = Dictionary(uniqueKeysWithValues: SettingKeys.all.map { ($0.name, $0.defaultPersisted) })
        #expect(rows["shelf.enabled"] == "true")
        #expect(rows["shelf.placement"] == "rightEdge")
        #expect(rows["shelf.revealOnEdgeHover"] == "false")
    }

    // OC-6002. given the Shelf on, when the user turns it off, then the menu has no Toggle Shelf row; the other rows are
    // unchanged (count delta of exactly one row, identity of the removed row).
    @Test("OC-6002 switching the Shelf off removes exactly the Toggle Shelf menu row")
    func oc6002_menuLosesToggleShelf() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        let before = MenuBarModel.entries(settings: settings)
        settings.set(false, for: SettingKeys.shelfEnabled)
        let after = MenuBarModel.entries(settings: settings)
        #expect(toggleShelfRows(before) == 1)
        #expect(toggleShelfRows(after) == 0)
        #expect(before.count - after.count == 1)
        #expect(after == before.filter { if case .toggleShelf = $0 { false } else { true } })
    }

    // OC-6003. given the Shelf was just turned off, when it is turned on again with no relaunch, then Toggle Shelf is
    // back in the menu carrying the chord the user had bound (⌘⇧9: key code 25, command+shift).
    @Test("OC-6003 turning the Shelf back on restores the Toggle Shelf row with its stored chord")
    func oc6003_menuRowReturnsWithChord() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        let chord = ChordBinding.chord(Chord(keyCode: 25, modifiers: [.command, .shift]))
        settings.set(chord, for: SettingKeys.shortcutsToggleShelf)
        settings.set(false, for: SettingKeys.shelfEnabled)
        #expect(toggleShelfRows(MenuBarModel.entries(settings: settings)) == 0)
        settings.set(true, for: SettingKeys.shelfEnabled)
        let rows = MenuBarModel.entries(settings: settings)
        #expect(toggleShelfRows(rows) == 1)
        #expect(rows.contains(.toggleShelf(chord)))
    }

    // OC-6006. given placement Left Edge and hover reveal on, when Flotsam relaunches (a NEW SettingsStore over the same
    // backing store), then both still read back. Red if either setting is held only in memory.
    @Test("OC-6006 placement Left Edge and hover reveal on survive a relaunch")
    func oc6006_placementAndHoverPersist() {
        let backing = MemoryKeyValueStore()
        let first = SettingsStore(store: backing)
        first.set(ShelfPlacement.leftEdge, for: SettingKeys.shelfPlacement)
        first.set(true, for: SettingKeys.shelfRevealOnEdgeHover)

        let relaunched = SettingsStore(store: backing)
        #expect(relaunched.value(SettingKeys.shelfPlacement) == ShelfPlacement.leftEdge)
        #expect(relaunched.value(SettingKeys.shelfRevealOnEdgeHover) == true)
        #expect(backing.string(forKey: "shelf.placement") == "leftEdge")
        #expect(backing.string(forKey: "shelf.revealOnEdgeHover") == "true")
    }

    // OC-6006 negative: a value never set does not read back as Left Edge (the persistence test above cannot pass on
    // a store that returns the last value written to ANY instance).
    @Test("OC-6006 an untouched store still reads the Right Edge default")
    func oc6006_untouchedStoreKeepsDefault() {
        let other = SettingsStore(store: MemoryKeyValueStore())
        #expect(other.value(SettingKeys.shelfPlacement) == ShelfPlacement.rightEdge)
        #expect(other.value(SettingKeys.shelfRevealOnEdgeHover) == false)
    }

    // OC-6119 (testable half: no Shelf usage counter is stored; the no-network clause has no seam, manual).
    // given the whole settings registry, then the only `shelf.*` keys are the four configuration keys (FR-006-01), and no key in
    // the registry is a counter or usage statistic.
    @Test("OC-6119 the only Shelf settings are enabled, placement, revealOnEdgeHover and edgeBar; no usage counter exists")
    func oc6119_noShelfUsageCounter() {
        let shelfKeys = SettingKeys.all.map(\.name).filter { $0.hasPrefix("shelf.") }.sorted()
        #expect(shelfKeys == ["shelf.edgeBar", "shelf.enabled", "shelf.placement", "shelf.revealOnEdgeHover"])
        let counterLike = SettingKeys.all.map(\.name).filter {
            let lower = $0.lowercased()
            return lower.contains("count") || lower.contains("usage") || lower.contains("stat") || lower.contains("telemetry")
        }
        #expect(counterLike.isEmpty)
    }
}
