import AppKit

/// Draws the app icon in code: a pull-request glyph on a blue rounded square.
/// The same art is used for the Dock icon (color) and the menu bar (template).
enum IconArt {
    private static let glyph = "arrow.triangle.pull"

    private static func symbol(pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// `scale` is the glyph's point size relative to the square; the glyph is
    /// shrunk to fit if it would overflow (symbols are taller than their point size).
    private static func drawGlyph(in square: NSRect, scale: CGFloat = 0.5, weight: NSFont.Weight = .semibold,
                                  color: NSColor, operation: NSCompositingOperation) {
        guard let symbol = symbol(pointSize: square.width * scale, weight: weight, color: color) else { return }
        let fit = min(1, square.width / symbol.size.width, square.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        let origin = NSPoint(x: square.midX - size.width / 2, y: square.midY - size.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: operation, fraction: 1)
    }

    /// Full-color app icon, following the macOS icon grid (content inset ~10%).
    static func drawAppIcon(in rect: NSRect) {
        let square = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
        let path = NSBezierPath(roundedRect: square, xRadius: square.width * 0.225, yRadius: square.width * 0.225)
        NSGradient(starting: NSColor(srgbRed: 0.15, green: 0.52, blue: 1.0, alpha: 1),
                   ending: NSColor(srgbRed: 0.0, green: 0.32, blue: 0.8, alpha: 1))?
            .draw(in: path, angle: -90)
        drawGlyph(in: square, color: .white, operation: .sourceOver)
    }

    /// Monochrome template glyph for the menu bar (no background); macOS tints it to match.
    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Heaviest weight: thin strokes are hard to see at menu bar size.
            drawGlyph(in: rect, scale: 1, weight: .black, color: .black, operation: .sourceOver)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Writes an .iconset folder for `iconutil`. Invoked by the build script.
    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = base * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appending(path: name))
            }
        }
    }
}
