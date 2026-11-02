// Renders Keno's app icon at every size macOS needs and packs it into AppIcon.icns.
// Usage: swift Resources/make-icon.swift   (writes Resources/AppIcon.icns and Resources/AppIcon.png)
//
// Design: κενό ("void") — an ensō, the open brush circle of Zen, around a single text caret,
// on a deep night-blue squircle.

import AppKit

let canvas: CGFloat = 1024

/// Apple's macOS icon grid: an 824pt continuous-corner squircle centred on a 1024pt canvas.
func squirclePath(in rect: CGRect) -> CGPath {
    // Superellipse (n≈5) closely matches Apple's continuous-curvature corners.
    let path = CGMutablePath()
    let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// A tapered arc band. `width(t)` gives the stroke width along t in [t0, t1] (0 = brush landing).
/// With `roundHead`, the start gets a semicircular cap like a brush pressed onto paper.
func brushArc(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat,
              t0: CGFloat, t1: CGFloat, roundHead: Bool, width: (CGFloat) -> CGFloat) -> CGPath {
    let samples = 600
    var outer: [CGPoint] = [], inner: [CGPoint] = []
    var headWidth: CGFloat = 0, headAngle: CGFloat = 0
    for i in 0...samples {
        let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(samples)
        let angle = start + sweep * t
        let w = max(0, width(t))
        if i == 0 { headWidth = w; headAngle = angle }
        let r = radius + 5 * sin(t * .pi * 2 + 0.6) // one gentle, hand-drawn wobble
        outer.append(CGPoint(x: center.x + (r + w / 2) * cos(angle), y: center.y + (r + w / 2) * sin(angle)))
        inner.append(CGPoint(x: center.x + (r - w / 2) * cos(angle), y: center.y + (r - w / 2) * sin(angle)))
    }
    let path = CGMutablePath()
    path.addLines(between: outer)
    for p in inner.reversed() { path.addLine(to: p) } // same subpath (addLines would start a new one)
    if roundHead {
        let u = CGPoint(x: cos(headAngle), y: sin(headAngle))
        let dir: CGFloat = sweep < 0 ? -1 : 1
        let tangent = CGPoint(x: -sin(headAngle) * dir, y: cos(headAngle) * dir)
        let p0 = CGPoint(x: (outer[0].x + inner[0].x) / 2, y: (outer[0].y + inner[0].y) / 2)
        for k in 1..<48 {
            let phi = CGFloat(k) / 48 * .pi
            path.addLine(to: CGPoint(x: p0.x + headWidth / 2 * (cos(phi) * -u.x + sin(phi) * -tangent.x),
                                     y: p0.y + headWidth / 2 * (cos(phi) * -u.y + sin(phi) * -tangent.y)))
        }
    }
    path.closeSubpath()
    return path
}

/// Smooth 0→1→0 envelope over [a, b] with soft shoulders.
func envelope(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
    guard t > a, t < b else { return 0 }
    let x = (t - a) / (b - a)
    return pow(sin(.pi * x), 0.6)
}

/// The ensō: a heavy body that is fullest along the bottom, then a dry-brush tail of fine strands.
func ensoPath(center: CGPoint, radius: CGFloat, maxWidth: CGFloat) -> CGPath {
    let start: CGFloat = .pi * 0.60      // brush lands at the top, slightly left
    let sweep: CGFloat = -.pi * 1.68     // travels clockwise ~300°, leaving an open gap
    let path = CGMutablePath()
    path.addPath(brushArc(center: center, radius: radius, start: start, sweep: sweep, t0: 0, t1: 0.86, roundHead: true) { t in
        let body = 0.70 + 0.30 * sin(.pi * min(t * 1.35, 1))            // heaviest around the bottom
        let taper: CGFloat = t < 0.55 ? 1 : pow(max(0, cos((t - 0.55) / 0.31 * .pi / 2)), 1.1)
        return maxWidth * body * taper
    })
    // Dry-brush strands that split off as the ink runs out.
    for (offset, w, a, b) in [(CGFloat(22), CGFloat(9), CGFloat(0.58), CGFloat(0.95)),
                              (-20, 8, 0.62, 0.99),
                              (4, 6, 0.70, 1.0),
                              (-6, 3.5, 0.74, 0.93)] {
        path.addPath(brushArc(center: center, radius: radius + offset, start: start, sweep: sweep,
                              t0: a, t1: b, roundHead: false) { t in w * envelope(t, a, b) })
    }
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(in: tile)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x10131C))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep night-blue vertical gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x2A3150), color(0x161A2B), color(0x0B0D16)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A faint glow in the centre — light in the void.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x7C8CFF, 0.30), color(0x7C8CFF, 0.0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 520), endRadius: 400, options: [])

    // The ensō, filled with a warm dawn gradient.
    let center = CGPoint(x: 512, y: 512)
    let enso = ensoPath(center: center, radius: 262, maxWidth: 84)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0xFF9A62, 0.45))
    ctx.addPath(enso)
    ctx.setFillColor(color(0xFFB27A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(enso)
    ctx.clip()
    let warm = CGGradient(colorsSpace: space,
                          colors: [color(0xFFD38A), color(0xFF9466), color(0xF2607E)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 300, y: 800), end: CGPoint(x: 760, y: 230), options: [])
    ctx.restoreGState()

    // The caret: a single cursor waiting in the empty space.
    let caret = CGRect(x: 512 - 17, y: 512 - 108, width: 34, height: 216)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: color(0xCFE0FF, 0.75))
    ctx.addPath(CGPath(roundedRect: caret, cornerWidth: 17, cornerHeight: 17, transform: nil))
    ctx.setFillColor(color(0xF4F7FF))
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle top highlight on the tile edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx)
    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let resources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote AppIcon.icns" : "iconutil failed")
