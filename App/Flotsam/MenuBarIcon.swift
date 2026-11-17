import AppKit
import FlotsamBase

/// The status-item glyph for a `MenuIcon` (FR-008-16). Modes are told apart by glyph shape (the three template assets),
/// and the warning is a dot, so no state relies on colour. Every image is a template: the system tints it for light,
/// dark and the highlighted menu bar.
enum MenuBarIcon {
    static func image(for icon: MenuIcon) -> NSImage {
        let base: NSImage
        switch (icon.mode, icon.warning) {
        case (.active, true): return template("MenuBarWarning")
        case (.active, false): return template("MenuBarActive")
        case (.paused, _): base = template("MenuBarPaused")
        case (.curated, _): base = template("MenuBarCurated")
        }
        return icon.warning ? withDot(base) : base
    }

    private static func template(_ name: String) -> NSImage {
        let image = NSImage(named: name) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    /// The assets carry a baked-in dot only for the Active mode, so Paused and Curated get the same dot drawn on:
    /// a solid disc with a clear ring around it, which stays an alpha-only (template-safe) image.
    private static func withDot(_ base: NSImage) -> NSImage {
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 6, height: 6)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
