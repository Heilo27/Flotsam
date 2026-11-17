import AppKit

/// The menu-bar glyph, with a dot when background Notices are waiting (FR-000-08 b).
///
/// Why drawn instead of a second SF Symbol: menu-bar images are templates, which the system tints and strips of
/// colour. The badged variant is a non-template image that draws the symbol in the current label colour (so it
/// still follows light and dark) plus a red dot, which is the one colour the badge needs.
enum MenuBarIcon {
    private static let symbol = "tray.full"

    static func image(badged: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        guard badged else {
            base.isTemplate = true
            return base
        }
        let tinted = base.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? base
        let image = NSImage(size: base.size, flipped: false) { rect in
            tinted.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
