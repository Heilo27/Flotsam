import AppKit
import FlotsamBase
import FlotsamLibrary
import FlotsamShelf
import Testing

// Worf, TASK-160/162/264: PanelWindowSpecAppKit.swift is the one place a PanelWindowSpec becomes NSPanel flags. The spec
// values are pinned in FlotsamLibraryTests / FlotsamShelfTests; these tests pin the mapping itself, on a real (headless)
// NSPanel, with literal expected AppKit values. Red if any flag is mapped to the wrong NSPanel property, dropped, or
// inverted, or if either shipped spec changes shape.

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PanelWindowSpecAppKitTests {
    private func panel(_ mask: NSWindow.StyleMask) -> NSPanel {
        NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: mask, backing: .buffered, defer: true)
    }

    // FR-003-01 / FR-003-03: the Library is non-activating, floating, on every Space, over full-screen apps, resizable,
    // movable by its background, and does not hide when the app deactivates. Window cycling is NOT ignored.
    @Test("FR-003-01 the Library spec maps to a non-activating floating all-Spaces resizable NSPanel")
    func libraryMapping() {
        let spec = LibraryPanelDriver.windowSpec
        let mask = spec.styleMask(adding: [.titled, .fullSizeContentView])
        #expect(mask == [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView])
        let p = panel(mask)
        spec.apply(to: p)
        #expect(p.isFloatingPanel == true)
        #expect(p.level == .floating)
        #expect(p.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
        #expect(p.hidesOnDeactivate == false)
        #expect(p.isMovableByWindowBackground == true)
        #expect(p.styleMask.contains(.nonactivatingPanel))
        #expect(p.styleMask.contains(.resizable))
    }

    // FR-006-02: the Shelf is non-activating, floating, on every Space, over full-screen apps, out of window cycling,
    // fixed size, not movable by its background. Red if ignoresCycle is dropped or resizable leaks in.
    @Test("FR-006-02 the Shelf spec maps to a non-activating floating all-Spaces fixed-size NSPanel outside window cycling")
    func shelfMapping() {
        let spec = ShelfWindowPolicy.windowSpec
        let mask = spec.styleMask(adding: [.borderless])
        #expect(mask == [.borderless, .nonactivatingPanel])
        let p = panel(mask)
        spec.apply(to: p)
        #expect(p.isFloatingPanel == true)
        #expect(p.level == .floating)
        #expect(p.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        #expect(p.hidesOnDeactivate == false)
        #expect(p.isMovableByWindowBackground == false)
        #expect(p.styleMask.contains(.nonactivatingPanel))
        #expect(!p.styleMask.contains(.resizable))
    }

    // Negative case: every flag off (and hidesOnDeactivate on) yields a plain panel; nothing is forced on.
    @Test("a spec with every window flag off maps to a normal-level panel with no collection behaviour")
    func allOffMapping() {
        let spec = PanelWindowSpec(
            isNonActivating: false, isFloating: false, joinsAllSpaces: false, isFullScreenAuxiliary: false,
            ignoresWindowCycling: false, hidesOnDeactivate: true, isResizable: false, isMovableByBackground: false)
        let mask = spec.styleMask(adding: [.borderless])
        #expect(mask == [.borderless])
        let p = panel(mask)
        spec.apply(to: p)
        #expect(p.isFloatingPanel == false)
        #expect(p.level == .normal)
        #expect(p.collectionBehavior == [])
        #expect(p.hidesOnDeactivate == true)
        #expect(p.isMovableByWindowBackground == false)
        #expect(!p.styleMask.contains(.nonactivatingPanel))
    }
}
