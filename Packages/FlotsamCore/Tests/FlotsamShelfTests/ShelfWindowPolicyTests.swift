import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

/// FRD-006 FR-006-02 / AC-006-02 window behaviour (OC-6007, OC-6010, OC-6011, OC-6037) and the key/front ordering of
/// FR-006-04 / FR-006-08, asserted on `ShelfWindowPolicy` (the values the App's `NSPanel` is configured from; no AppKit).
/// Expected values are the FRD's and the oracle's words written out as literals, never read back from the policy.
/// Not covered here (TASK-518, the real-OS matrix): whether a real `NSPanel` is actually key, on which Space, over a
/// real full-screen app, or absent from the Dock and the app switcher.
@Suite struct ShelfWindowPolicyTests {
    private let spec = ShelfWindowPolicy.windowSpec

    // OC-6007. "after each reveal TextEdit is still the frontmost app and its menu bar is shown". The Shelf never
    // activates Flotsam, which needs the non-activating panel style. Red if the flag is dropped.
    @Test("OC-6007 the Shelf window is a non-activating panel, so a reveal leaves the other app frontmost")
    func oc6007_nonActivating() {
        #expect(spec.isNonActivating)
    }

    // OC-6007 (menu item, then hotkey). Both are sticky reveals: they make the panel key and front, never activate.
    @Test("OC-6007 the menu item and the hotkey reveal with key-and-front ordering, which has no app activation")
    func oc6007_stickyTriggersKeyAndFront() {
        #expect(ShelfWindowPolicy.ordering(for: ShelfTrigger.menuItem.mode) == .keyAndFront)
        #expect(ShelfWindowPolicy.ordering(for: ShelfTrigger.hotkey.mode) == .keyAndFront)
    }

    // OC-6010. "visible on top of full-screen Safari; the Space does not change". Full-screen auxiliary lets a panel
    // sit over a full-screen app, all-Spaces lets it appear on the current Space, floating keeps it on top.
    @Test("OC-6010 the Shelf window floats, joins all Spaces and is full-screen auxiliary")
    func oc6010_overFullScreenApp() {
        #expect(spec.isFloating)
        #expect(spec.joinsAllSpaces)
        #expect(spec.isFullScreenAuxiliary)
        #expect(!spec.hidesOnDeactivate)
    }

    // OC-6011. "Flotsam is not in the app switcher; the backtick never focuses the Shelf". The window is ignored by
    // window cycling, is non-activating, and only a sticky Shelf may become key.
    @Test("OC-6011 the Shelf window is excluded from window cycling and a transient Shelf is never key")
    func oc6011_notInCycling() {
        #expect(spec.ignoresWindowCycling)
        #expect(spec.isNonActivating)
        for trigger in [ShelfTrigger.drag, .hover, .menuBarIconDrag] {
            #expect(ShelfWindowPolicy.ordering(for: trigger.mode) == .frontWithoutKey)
        }
    }

    // OC-6037. "drags its border and its body: size and position unchanged". Not resizable, not movable by background.
    // Red if either flag flips.
    @Test("OC-6037 the Shelf window is neither resizable nor movable by its background")
    func oc6037_fixedSizeAndPosition() {
        #expect(!spec.isResizable)
        #expect(!spec.isMovableByBackground)
    }

    // The whole value, so a flag added or changed later is a visible diff here.
    @Test("FR-006-02 the complete Shelf window spec")
    func windowSpecLiteral() {
        let expected = PanelWindowSpec(
            isNonActivating: true, isFloating: true, joinsAllSpaces: true, isFullScreenAuxiliary: true,
            ignoresWindowCycling: true, hidesOnDeactivate: false, isResizable: false, isMovableByBackground: false)
        #expect(spec == expected)
    }

    // FR-006-04 / OC-6008, OC-6009. Only the hotkey and the menu item are sticky; the other three never take key.
    @Test("FR-006-04 each trigger's ordering: hotkey and menu item key-and-front; drag, hover, menu-bar-icon drag front only")
    func orderingPerTrigger() {
        let expected: [ShelfTrigger: ShelfWindowPolicy.Ordering] = [
            .hotkey: .keyAndFront, .menuItem: .keyAndFront,
            .drag: .frontWithoutKey, .hover: .frontWithoutKey, .menuBarIconDrag: .frontWithoutKey,
        ]
        #expect(Set(ShelfTrigger.allCases) == Set(expected.keys))
        for trigger in ShelfTrigger.allCases {
            #expect(ShelfWindowPolicy.ordering(for: trigger.mode) == expected[trigger])
        }
    }

    // The ordering and the reveal machine's `canBecomeKey` (which the panel's `allowsKey` follows) must agree for
    // every trigger, or the panel would be ordered key but refuse it (or the reverse).
    @Test("the key-and-front ordering holds exactly when the reveal machine says the Shelf can become key")
    func orderingMatchesMachine() {
        let origin = Date(timeIntervalSinceReferenceDate: 3_000_000)
        for trigger in ShelfTrigger.allCases {
            var machine = ShelfRevealMachine()
            _ = machine.send(.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: true), at: origin)
            _ = machine.send(.toggle(trigger, screen: 0), at: origin.addingTimeInterval(1))
            guard machine.visibleTrigger == trigger else { continue }
            #expect(machine.canBecomeKey == (ShelfWindowPolicy.ordering(for: trigger.mode) == .keyAndFront))
        }
    }
}
