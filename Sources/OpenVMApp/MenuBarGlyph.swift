// MenuBarGlyph — the openVM mark for the menu bar: a screen holding a second, raised screen. Drawn here
// as a template image, so it follows the menu bar's light or dark look and needs no file in the bundle.
import AppKit

enum MenuBarGlyph {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // The host's screen: an outline.
            let outer = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 12, height: 10), xRadius: 2.5, yRadius: 2.5)
            outer.lineWidth = 1.5
            // The guest's screen sits over its lower right corner, so the outline is cut away under it.
            let inner = NSRect(x: 7.5, y: 1.5, width: 9.5, height: 8)
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
            clip.append(NSBezierPath(roundedRect: inner.insetBy(dx: -1.5, dy: -1.5), xRadius: 3.5, yRadius: 3.5).reversed)
            clip.addClip()
            outer.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "openVM"
        return image
    }
}
