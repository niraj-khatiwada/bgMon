import AppKit
let destination = CommandLine.arguments[1]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let shape = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.17, blue: 0.28, alpha: 1), ending: NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.08, alpha: 1))!.draw(in: shape, angle: -90)
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 200, y: 510))
        for point in [NSPoint(x: 350,y: 510), NSPoint(x: 420,y: 690), NSPoint(x: 500,y: 310), NSPoint(x: 580,y: 610), NSPoint(x: 640,y: 510), NSPoint(x: 824,y: 510)] { wave.line(to: point) }
        wave.lineWidth = 50
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        NSColor(calibratedRed: 0.23, green: 0.73, blue: 1, alpha: 1).setStroke()
        wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size)x\(size)\(suffix).png"))
    }
}
