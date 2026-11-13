// MenuBarGlyph — the openVM mark for the menu bar: the app icon's two screens in one colour. The host's
// screen is an outline, and the guest's, raised over its lower right corner, is filled. Drawn here as a
// template image, so it follows the menu bar's light or dark look and needs no file in the bundle.
//
// The shapes are the app icon's own (tools/build/AppIcon.icon), scaled from its 1024-point canvas.
import AppKit

enum MenuBarGlyph {
    /// The icon's two screens on its 1024-point canvas, measured from the top left as in its SVG layers.
    static let host = NSRect(x: 174, y: 232, width: 580, height: 430)
    static let guest = NSRect(x: 400, y: 430, width: 450, height: 340)
    static let hostRadius: CGFloat = 72
    static let guestRadius: CGFloat = 64

    static func image(side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let bounds = host.union(guest)
            // The pair fills the width but for a point of margin, and sits in the middle.
            let scale = (side - 2) / bounds.width
            func place(_ rect: NSRect) -> NSRect {
                NSRect(
                    x: 1 + (rect.minX - bounds.minX) * scale,
                    y: (side - bounds.height * scale) / 2 + (rect.minY - bounds.minY) * scale,
                    width: rect.width * scale, height: rect.height * scale)
            }
            let line = max(1.25, side / 14)
            let gap = line * 0.9
            let hostRect = place(host).insetBy(dx: line / 2, dy: line / 2)
            let guestRect = place(guest)
            NSColor.black.set()

            // The guest's screen is in front: the host's outline stops short of it.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side))
            let cut = guestRect.insetBy(dx: -gap, dy: -gap)
            clip.append(
                NSBezierPath(
                    roundedRect: cut, xRadius: guestRadius * scale + gap, yRadius: guestRadius * scale + gap
                ).reversed)
            clip.addClip()
            let outline = NSBezierPath(
                roundedRect: hostRect, xRadius: hostRadius * scale, yRadius: hostRadius * scale)
            outline.lineWidth = line
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()

            NSBezierPath(roundedRect: guestRect, xRadius: guestRadius * scale, yRadius: guestRadius * scale)
                .fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "openVM"
        return image
    }
}
