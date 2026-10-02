// Renders Drift's app icon to PNGs: swift scripts/make-icon.swift <out-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with ~185 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1).cgColor,
        NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Soft accent glow behind the glyph.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.36, green: 0.80, blue: 0.92, alpha: 0.35).cgColor,
        NSColor(red: 0.36, green: 0.80, blue: 0.92, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s / 2, y: s * 0.42), startRadius: 0,
                           endCenter: CGPoint(x: s / 2, y: s * 0.42), endRadius: s * 0.42, options: [])

    // Segment bars: four flowing lines that converge into an arrow.
    let accent = NSColor(red: 0.36, green: 0.80, blue: 0.92, alpha: 1).cgColor
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let w = s * 0.06
    ctx.setLineWidth(w)
    ctx.setStrokeColor(accent)

    let cx = s / 2
    // Arrow shaft
    ctx.move(to: CGPoint(x: cx, y: s * 0.72))
    ctx.addLine(to: CGPoint(x: cx, y: s * 0.36))
    ctx.strokePath()
    // Arrow head
    ctx.move(to: CGPoint(x: cx - s * 0.15, y: s * 0.49))
    ctx.addLine(to: CGPoint(x: cx, y: s * 0.34))
    ctx.addLine(to: CGPoint(x: cx + s * 0.15, y: s * 0.49))
    ctx.strokePath()

    // Segmented baseline (the "connections")
    let y = s * 0.245
    let segs: [(CGFloat, CGFloat, CGFloat)] = [(0.29, 0.35, 1), (0.45, 0.55, 1), (0.65, 0.71, 0.4)]
    for (a, b, alpha) in segs {
        ctx.setStrokeColor(NSColor(red: 0.36, green: 0.80, blue: 0.92, alpha: alpha).cgColor)
        ctx.move(to: CGPoint(x: s * a, y: y))
        ctx.addLine(to: CGPoint(x: s * b, y: y))
        ctx.strokePath()
    }

    // Top highlight
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(s * 0.004)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size).png"))
}
