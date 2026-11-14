import AppKit

// A single ink-green nib on a quiet paper tile. Drawn as paths so every
// macOS icon size has crisp edges, without an external raster dependency.
func drawIcon(pixels: Int) {
    let paper = NSColor(srgbRed: 0.970, green: 0.976, blue: 0.964, alpha: 1)
    let ink = NSColor(srgbRed: 0.17, green: 0.38, blue: 0.34, alpha: 1)
    let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904),
                            xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.11)
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    paper.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.84, green: 0.87, blue: 0.85, alpha: 0.55).setStroke()
    tile.lineWidth = 1.5
    tile.stroke()

    // The rounded shoulders feel like a drop of ink; the opening and slit
    // make the writing nib legible without a separate page or pencil.
    let nib = NSBezierPath()
    nib.move(to: NSPoint(x: 292, y: 274))
    nib.curve(to: NSPoint(x: 361, y: 635),
              controlPoint1: NSPoint(x: 305, y: 451),
              controlPoint2: NSPoint(x: 315, y: 563))
    nib.curve(to: NSPoint(x: 636, y: 779),
              controlPoint1: NSPoint(x: 415, y: 717),
              controlPoint2: NSPoint(x: 550, y: 779))
    nib.curve(to: NSPoint(x: 754, y: 661),
              controlPoint1: NSPoint(x: 699, y: 779),
              controlPoint2: NSPoint(x: 754, y: 724))
    nib.curve(to: NSPoint(x: 610, y: 386),
              controlPoint1: NSPoint(x: 754, y: 558),
              controlPoint2: NSPoint(x: 692, y: 440))
    nib.curve(to: NSPoint(x: 292, y: 274),
              controlPoint1: NSPoint(x: 542, y: 341),
              controlPoint2: NSPoint(x: 449, y: 297))
    nib.close()
    ink.setFill()
    nib.fill()

    // Optical adjustment keeps the small icon's negative space open.
    let holeRadius = max(31, 1024 / CGFloat(pixels) * 0.58)
    let slit = NSBezierPath()
    slit.move(to: NSPoint(x: 289, y: 271))
    slit.line(to: NSPoint(x: 505, y: 487))
    slit.lineWidth = max(22, 1024 / CGFloat(pixels) * 0.75)
    slit.lineCapStyle = .round
    paper.setStroke()
    slit.stroke()
    paper.setFill()
    NSBezierPath(ovalIn: NSRect(x: 505 - holeRadius, y: 487 - holeRadius,
                               width: holeRadius * 2, height: holeRadius * 2)).fill()
}

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: representation) else { fatalError("Icon allocation failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon(pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return representation
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                       ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    guard let png = renderIcon(pixels: pixels).representation(using: .png, properties: [:])
    else { fatalError("Icon export failed") }
    try png.write(to: destination.appendingPathComponent(name + ".png"))
}
