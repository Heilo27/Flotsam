import AppKit
import FlotsamBase

/// Maps `PanelWindowSpec` (the decision, pinned by tests in FlotsamBase's consumers) onto an `NSPanel`. The one place the
/// spec becomes AppKit flags, so the Library and the Shelf cannot drift apart on them.
extension PanelWindowSpec {
    /// The style mask must carry `nonactivatingPanel` from `init`: set afterwards, AppKit does not apply it to the
    /// window server's activation tag.
    func styleMask(adding base: NSWindow.StyleMask) -> NSWindow.StyleMask {
        var mask = base
        if isNonActivating { mask.insert(.nonactivatingPanel) }
        if isResizable { mask.insert(.resizable) }
        return mask
    }

    @MainActor
    func apply(to panel: NSPanel) {
        panel.isFloatingPanel = isFloating
        panel.level = isFloating ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = []
        if joinsAllSpaces { behavior.insert(.canJoinAllSpaces) }
        if isFullScreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
        if ignoresWindowCycling { behavior.insert(.ignoresCycle) }
        panel.collectionBehavior = behavior
        panel.hidesOnDeactivate = hidesOnDeactivate
        panel.isMovableByWindowBackground = isMovableByBackground
    }
}
