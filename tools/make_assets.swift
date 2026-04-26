// Generates vplay's app icon (AppIcon.icns) and splash artwork (vplay-splash.png).
// Usage: swift tools/make_assets.swift   (run from the repository root)
import AppKit
import CoreGraphics

let cs = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorSpace: cs, colorComponents: stops.flatMap { s -> [CGFloat] in
        [CGFloat((s.0 >> 16) & 255) / 255, CGFloat((s.0 >> 8) & 255) / 255, CGFloat(s.0 & 255) / 255, s.1]
    }, locations: stops.map { $0.2 }, count: stops.count)!
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ ctx: CGContext, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// Rounded play triangle centred on (cx, cy) with the given circumscribed radius.
func trianglePath(cx: CGFloat, cy: CGFloat, r: CGFloat, corner: CGFloat) -> CGPath {
    let pts = (0..<3).map { i -> CGPoint in
        let a = CGFloat(i) * 2 * .pi / 3
        return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
    let p = CGMutablePath()
    for i in 0..<3 {
        let prev = pts[(i + 2) % 3], cur = pts[i], next = pts[(i + 1) % 3]
        let a = CGPoint(x: cur.x + (prev.x - cur.x) * 0.22, y: cur.y + (prev.y - cur.y) * 0.22)
        let b = CGPoint(x: cur.x + (next.x - cur.x) * 0.22, y: cur.y + (next.y - cur.y) * 0.22)
        if i == 0 { p.move(to: a) } else { p.addLine(to: a) }
        p.addQuadCurve(to: b, control: cur)
    }
    p.closeSubpath()
    return p
}

/// Draws the glowing emblem (chrome ring, orbit arcs, neon play triangle) inside a square of side `s` at origin.
func drawEmblem(_ ctx: CGContext, center c: CGPoint, size s: CGFloat) {
    let ringR = s * 0.40
    // Outer chrome ring.
    ctx.saveGState()
    ctx.setLineWidth(s * 0.032)
    ctx.addArc(center: c, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xF7FAFF, 1, 0), (0x7F90AE, 1, 0.35), (0xEAF1FB, 1, 0.55), (0x5E6F90, 1, 1)]),
                           start: CGPoint(x: c.x - ringR, y: c.y + ringR), end: CGPoint(x: c.x + ringR, y: c.y - ringR), options: [])
    ctx.restoreGState()

    // Neon orbit arcs with glow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: color(0x35E0FF, 0.9))
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x6FF0FF))
    ctx.setLineWidth(s * 0.018)
    let orbit = ringR * 0.86
    for (start, end) in [(20.0, 100.0), (140.0, 200.0), (230.0, 320.0)] {
        ctx.addArc(center: c, radius: orbit, startAngle: CGFloat(start) * .pi / 180, endAngle: CGFloat(end) * .pi / 180, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Tick marks around the ring.
    ctx.saveGState()
    ctx.setStrokeColor(color(0xBFD6F5, 0.55))
    ctx.setLineWidth(s * 0.006)
    for i in 0..<72 {
        let a = CGFloat(i) * .pi / 36
        let r1 = ringR * 1.08, r2 = ringR * (i % 6 == 0 ? 1.17 : 1.12)
        ctx.move(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
        ctx.addLine(to: CGPoint(x: c.x + r2 * cos(a), y: c.y + r2 * sin(a)))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Play triangle: glow, gradient fill, chrome edge.
    let tri = trianglePath(cx: c.x + s * 0.02, cy: c.y, r: s * 0.26, corner: s * 0.04)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.09, color: color(0x2FD6FF, 0.95))
    ctx.addPath(tri); ctx.setFillColor(color(0x2FA8FF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tri); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xE9FDFF, 1, 0), (0x62D7FF, 1, 0.45), (0x1B6BE0, 1, 1)]),
                           start: CGPoint(x: c.x, y: c.y + s * 0.26), end: CGPoint(x: c.x, y: c.y - s * 0.26), options: [])
    // Gloss on the upper half of the triangle.
    ctx.setFillColor(color(0xFFFFFF, 0.22))
    ctx.fill(CGRect(x: c.x - s * 0.3, y: c.y, width: s * 0.6, height: s * 0.3))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tri); ctx.setStrokeColor(color(0xFFFFFF, 0.85)); ctx.setLineWidth(s * 0.008); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Icon

func makeIcon(path: String) {
    let N = 1024
    let ctx = makeContext(N, N)
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.55))
    ctx.addPath(squircle); ctx.setFillColor(color(0x07102A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([(0x24508F, 1, 0), (0x0C1E45, 1, 0.55), (0x030818, 1, 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(gradient([(0x2FD6FF, 0.55, 0), (0x2FD6FF, 0, 1)]),
                           startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])
    // Perspective grid floor for a sci-fi feel.
    ctx.setStrokeColor(color(0x5FD0FF, 0.16)); ctx.setLineWidth(2)
    for i in 0...12 {
        let x = 100 + CGFloat(i) * 824 / 12
        ctx.move(to: CGPoint(x: 512 + (x - 512) * 0.25, y: 330)); ctx.addLine(to: CGPoint(x: x, y: 100))
    }
    for i in 0..<6 {
        let t = CGFloat(i) / 5
        let y = 330 - (230 * t * t)
        ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y))
    }
    ctx.strokePath()
    drawEmblem(ctx, center: CGPoint(x: 512, y: 520), size: 760)
    // Upper gloss.
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.20, 0), (0xFFFFFF, 0.0, 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    // Chrome bezel.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setLineWidth(12)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 1, 0), (0x8798B6, 1, 0.4), (0xE9F0FA, 1, 0.6), (0x55688C, 1, 1)]),
                           start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    ctx.restoreGState()
    savePNG(ctx, path)
}

// MARK: - Splash

func makeSplash(path: String) {
    let W = 1600, H = 900
    let ctx = makeContext(W, H)
    ctx.setFillColor(color(0x000000)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.drawRadialGradient(gradient([(0x1F7BFF, 0.28, 0), (0x1F7BFF, 0, 1)]),
                           startCenter: CGPoint(x: 800, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 800, y: 520), endRadius: 560, options: [])
    drawEmblem(ctx, center: CGPoint(x: 800, y: 520), size: 560)

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, kern: CGFloat, y: CGFloat, color c: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c, .kern: kern]
        let str = NSAttributedString(string: s, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        let b = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: 800 - b.width / 2, y: y)
        CTLineDraw(line, ctx)
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: color(0x35E0FF, 0.8))
    text("Mac Video Player", size: 84, weight: .light, kern: 6, y: 130, color: NSColor(calibratedRed: 0.86, green: 0.96, blue: 1, alpha: 1))
    ctx.restoreGState()
    text("P R E M I E R   M A C   M E D I A   P L A Y E R", size: 20, weight: .light, kern: 4, y: 84, color: NSColor(calibratedRed: 0.62, green: 0.74, blue: 0.92, alpha: 0.9))
    ctx.setStrokeColor(color(0x6FF0FF, 0.5)); ctx.setLineWidth(2)
    ctx.move(to: CGPoint(x: 480, y: 60)); ctx.addLine(to: CGPoint(x: 1120, y: 60)); ctx.strokePath()
    savePNG(ctx, path)
}

// MARK: - Run

let fm = FileManager.default
let out = "vplay"
let work = NSTemporaryDirectory() + "vplay-icon-work"
try? fm.removeItem(atPath: work)
try! fm.createDirectory(atPath: work + "/AppIcon.iconset", withIntermediateDirectories: true)
let master = work + "/master.png"
makeIcon(path: master)
makeSplash(path: out + "/vplay-splash.png")

let sizes: [(Int, String)] = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                              (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
for (px, name) in sizes {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(px)", "\(px)", master, "--out", "\(work)/AppIcon.iconset/icon_\(name).png"]
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
}
let it = Process(); it.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
it.arguments = ["-c", "icns", work + "/AppIcon.iconset", "-o", out + "/AppIcon.icns"]
try! it.run(); it.waitUntilExit()
try? fm.copyItem(atPath: master, toPath: "tools/icon-1024.png")
print("Wrote \(out)/AppIcon.icns and \(out)/vplay-splash.png")
