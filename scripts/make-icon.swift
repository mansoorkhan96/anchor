// Renders Drift's app icon to PNGs: swift scripts/make-icon.swift <out-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Brand orange, light to dark, matching `Brand.primary` in Theme.swift.
let gradientStops: [UInt32] = [0xFE9208, 0xFD5E06, 0xD03501]
/// The anchor's arms: a pale tint of the orange.
let armTint: UInt32 = 0xFFE3D0

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Draw in a 1024-point, y-down space so the coordinates match the design canvas.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: s / 1024, y: -s / 1024)

    // macOS icon grid: 824/1024 body with ~185 corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: color(0xD03501, 0.30))
    ctx.addPath(path)
    ctx.setFillColor(color(gradientStops[1]))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: gradientStops.map { color($0) } as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
    // Soft sheen over the top half.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.2), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 512), options: [])
    ctx.restoreGState()

    // The anchor sits at 86% of the tile's drawing area, centered, for breathing room.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 0.86, y: 0.86)
    ctx.translateBy(x: -512, y: -515)

    // Small sizes get bolder strokes and drop the fluke tips, which blur below 64 px.
    let small = px <= 64
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(small ? 54 : 48)

    // Ring, crossbar and the down-arrow shank, in white.
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.strokeEllipse(in: CGRect(x: 512 - 46, y: 258 - 46, width: 92, height: 92))
    ctx.move(to: CGPoint(x: 412, y: 390)); ctx.addLine(to: CGPoint(x: 612, y: 390))
    ctx.move(to: CGPoint(x: 512, y: 306)); ctx.addLine(to: CGPoint(x: 512, y: 700))
    ctx.move(to: CGPoint(x: 432, y: 624)); ctx.addLine(to: CGPoint(x: 512, y: 704)); ctx.addLine(to: CGPoint(x: 592, y: 624))
    ctx.strokePath()

    // Arms, in the pale tint.
    ctx.setStrokeColor(color(armTint))
    ctx.move(to: CGPoint(x: 296, y: 560))
    ctx.addCurve(to: CGPoint(x: 512, y: 772), control1: CGPoint(x: 312, y: 704), control2: CGPoint(x: 418, y: 772))
    ctx.addCurve(to: CGPoint(x: 728, y: 560), control1: CGPoint(x: 606, y: 772), control2: CGPoint(x: 712, y: 704))
    if !small {
        ctx.move(to: CGPoint(x: 252, y: 608)); ctx.addLine(to: CGPoint(x: 296, y: 556)); ctx.addLine(to: CGPoint(x: 348, y: 596))
        ctx.move(to: CGPoint(x: 676, y: 596)); ctx.addLine(to: CGPoint(x: 728, y: 556)); ctx.addLine(to: CGPoint(x: 772, y: 608))
    }
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size).png"))
}
