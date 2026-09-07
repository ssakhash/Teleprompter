import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let box = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202)
        NSGradient(starting: NSColor(red: 0.13, green: 0.19, blue: 0.2, alpha: 1),
                   ending: NSColor(red: 0.035, green: 0.055, blue: 0.067, alpha: 1))!.draw(in: box, angle: -90)
        NSColor(white: 1, alpha: 0.12).setStroke(); box.lineWidth = 4; box.stroke()
        let mint = NSColor(red: 0.49, green: 0.94, blue: 0.79, alpha: 1)
        mint.setStroke()
        for (x, y, dx, dy) in [(240.0, 730.0, 120.0, -115.0), (784.0, 730.0, -120.0, -115.0),
                               (240.0, 280.0, 120.0, 115.0), (784.0, 280.0, -120.0, 115.0)] {
            let bracket = NSBezierPath(); bracket.move(to: NSPoint(x: x + dx, y: y)); bracket.line(to: NSPoint(x: x, y: y)); bracket.line(to: NSPoint(x: x, y: y + dy))
            bracket.lineWidth = 31; bracket.lineJoinStyle = .round; bracket.lineCapStyle = .round; bracket.stroke()
        }
        for (y, width, alpha) in [(609.0, 314.0, 0.5), (504.0, 388.0, 1.0), (399.0, 265.0, 0.3)] {
            mint.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: 335, y: y, width: width, height: 29), xRadius: 14.5, yRadius: 14.5).fill()
        }
        mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 490, y: 806, width: 44, height: 44)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
