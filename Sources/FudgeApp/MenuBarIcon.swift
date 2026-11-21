import AppKit

/// The menu bar item's glyph: the app icon's piece of fudge, as a monochrome cube with a swirl on top. It's a
/// template image, so the menu bar draws it in its own color, light or dark. Drawn in code, it's sharp at every
/// scale and needs no resource in the bundle.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fudge"
        return image
    }()

    /// A cube seen from above a corner, 16 pt tall, centered in 18 × 18 pt: the top face and the two sides, told
    /// apart by cut-out edges, and the swirl cut into the top.
    private static func draw() {
        let left = 2.0
        let right = 16.0
        let middle = 9.0
        let top = 17.0
        let bottom = 1.0
        // Half the top face's height: the top face's side corners sit this far below its back corner.
        let rise = 3.6
        let edge = top - 2 * rise  // where the top face's front corner meets the vertical edge
        let shoulder = top - rise  // the side corners of the top face
        let foot = bottom + rise  // the side corners of the bottom

        let silhouette = NSBezierPath()
        silhouette.move(to: NSPoint(x: middle, y: top))
        silhouette.line(to: NSPoint(x: right, y: shoulder))
        silhouette.line(to: NSPoint(x: right, y: foot))
        silhouette.line(to: NSPoint(x: middle, y: bottom))
        silhouette.line(to: NSPoint(x: left, y: foot))
        silhouette.line(to: NSPoint(x: left, y: shoulder))
        silhouette.close()
        // A thin stroke with round joins softens the corners, like the fudge's.
        silhouette.lineJoinStyle = .round
        silhouette.lineWidth = 1.5
        NSColor.black.set()
        silhouette.fill()
        silhouette.stroke()

        guard let context = NSGraphicsContext.current else { return }
        context.compositingOperation = .clear

        let edges = NSBezierPath()
        edges.move(to: NSPoint(x: left + 0.4, y: shoulder))
        edges.line(to: NSPoint(x: middle, y: edge))
        edges.line(to: NSPoint(x: right - 0.4, y: shoulder))
        edges.move(to: NSPoint(x: middle, y: edge))
        edges.line(to: NSPoint(x: middle, y: bottom + 0.4))
        edges.lineWidth = 1.2
        edges.lineJoinStyle = .round
        edges.stroke()

        let swirl = NSBezierPath()
        swirl.move(to: NSPoint(x: 5.6, y: shoulder - 0.3))
        swirl.curve(
            to: NSPoint(x: 12.6, y: shoulder + 0.5),
            controlPoint1: NSPoint(x: 7.6, y: shoulder + 2.4),
            controlPoint2: NSPoint(x: 10.4, y: shoulder - 1.9))
        swirl.lineWidth = 1.1
        swirl.lineCapStyle = .round
        swirl.stroke()

        context.compositingOperation = .sourceOver
    }
}
