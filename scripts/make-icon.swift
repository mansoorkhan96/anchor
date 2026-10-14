// Renders Anchor's icons to PNGs, with no drop shadow:
//   swift scripts/make-icon.swift <out-dir>               the app icon (icon_16.png … icon_1024.png)
//   swift scripts/make-icon.swift --extension <out-dir>   the browser extension's icons: the tile fills the canvas
//                                                         so it isn't small in the toolbar, plus status variants with
//                                                         a dot in the top left (green: Anchor running, grey: not)
import AppKit

let extensionMode = CommandLine.arguments.contains("--extension")
let out = URL(fileURLWithPath: CommandLine.arguments.last!)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

enum Dot { case running, stopped }

/// Top to bottom: the Swift icon's amber shades into `Brand.primary` (0xEB6840).
let gradientStops: [UInt32] = [0xE0A24A, 0xDF9946, 0xDE8741, 0xE4783F, 0xEB6840, 0xE95F40]
let gradientLocations: [CGFloat] = [0, 0.09, 0.25, 0.46, 0.7, 1]
let armTint: UInt32 = 0xFFE4D6

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
}

/// `fill`: the tile covers the whole canvas (toolbar icons) instead of the macOS app icon grid.
func render(_ px: Int, fill: Bool = false, dot: Dot? = nil) -> Data {
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
    ctx.saveGState()
    if fill {
        // Scale the 824-point tile up to the full 1024-point canvas.
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: 1024 / 824, y: 1024 / 824)
        ctx.translateBy(x: -512, y: -512)
    }

    // macOS icon grid: 824/1024 body with ~185 corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: gradientStops.map { color($0) } as CFArray, locations: gradientLocations)!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
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
    ctx.restoreGState()

    if let dot {
        // A status dot in the top left, ringed in white so it reads on light and dark toolbars.
        // Sized to sit in the corner, clear of the anchor's ring and crossbar.
        let center = CGPoint(x: 180, y: 180), ring: CGFloat = 175, inner: CGFloat = 122
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2))
        ctx.setFillColor(color(dot == .running ? 0x34C759 : 0x8E8E93))
        ctx.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if extensionMode {
    for size in [16, 32, 48, 128] {
        try! render(size, fill: true).write(to: out.appendingPathComponent("icon\(size).png"))
    }
    // The toolbar icon, swapped by the extension as Anchor starts and quits.
    for size in [16, 32] {
        try! render(size, fill: true, dot: .running).write(to: out.appendingPathComponent("icon\(size)-running.png"))
        try! render(size, fill: true, dot: .stopped).write(to: out.appendingPathComponent("icon\(size)-stopped.png"))
    }
} else {
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        try! render(size).write(to: out.appendingPathComponent("icon_\(size).png"))
    }
}
