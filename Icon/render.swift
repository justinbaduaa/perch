// Draws an SVG squircle onto macOS's icon grid (824 of 1024, with a drop shadow) at every iconset size.
// Usage: swift render.swift Perch.svg AppIcon.iconset
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOf: URL(filePath: args[1])) else { fatalError("usage: render.swift in.svg out.iconset") }
let out = URL(filePath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let unit = CGFloat(px) / 1024
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
        shadow.shadowBlurRadius = 10 * unit
        shadow.set()
        svg.draw(in: NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: name))
    }
}
