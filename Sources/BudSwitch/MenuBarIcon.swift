import AppKit

extension NSImage {
    /// The app icon redrawn for the menu bar: the earbud lies in the switch's track, its head the knob, its ear tip
    /// half-tone behind it. As a template, it follows the menu bar's appearance and dims with the button.
    static func menuBarIcon(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 15), flipped: true) { _ in
            let track = NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 22, height: 9), xRadius: 4.5, yRadius: 4.5)
            track.lineWidth = 1
            track.stroke()

            let tip = NSBezierPath(ovalIn: NSRect(x: -2.75, y: -3.5, width: 5.5, height: 7))
            var placement = AffineTransform(translationByX: 24.1, byY: 3.4)
            placement.rotate(byDegrees: -45)
            tip.transform(using: placement)
            NSColor.black.withAlphaComponent(0.45).setFill()
            tip.fill()

            let bud = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4.5, width: 17.5, height: 6), xRadius: 3, yRadius: 3)
            bud.append(NSBezierPath(ovalIn: NSRect(x: 13.5, y: 1, width: 13, height: 13)))
            // Erases a 1 pt gap around the stem and head, setting them apart from the track and the tip.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            bud.lineWidth = 2
            bud.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            bud.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
