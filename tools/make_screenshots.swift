#!/usr/bin/env swift
// Generates Mac App Store screenshots (2880x1800, opaque PNG) into AppStoreScreenshots/.
// The interface is a faithful mock-up of the real player: control bar, menu panel, context
// menus (item names come from VPWindowController.m) and the Post-Processing window.
// Usage: swift tools/make_screenshots.swift   (run from the project root)
import AppKit

let W = 2880, H = 1800
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("AppStoreScreenshots")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let splash = NSImage(contentsOf: root.appendingPathComponent("vplay/vplay-splash.png"))

let cyan = NSColor(calibratedRed: 0.35, green: 0.87, blue: 1.0, alpha: 1)
let white = NSColor.white
let navyTop = NSColor(calibratedRed: 0.50, green: 0.58, blue: 0.76, alpha: 0.92)
let navyBottom = NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.40, alpha: 0.96)

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: y, width: w, height: h) }

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = white, center: CGFloat? = nil, right: CGFloat? = nil, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
    let a = NSAttributedString(string: s, attributes: attrs)
    if let c = center { a.draw(at: NSPoint(x: c - a.size().width / 2, y: y)) }
    else if let r = right { a.draw(at: NSPoint(x: r - a.size().width, y: y)) }
    else { a.draw(at: NSPoint(x: x, y: y)) }
}

func fill(_ r: NSRect, _ c: NSColor, radius: CGFloat = 0) {
    c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

func stroke(_ r: NSRect, _ c: NSColor, radius: CGFloat, width: CGFloat = 2) {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    p.lineWidth = width; c.setStroke(); p.stroke()
}

func gradient(_ r: NSRect, _ colors: [NSColor], angle: CGFloat) { NSGradient(colors: colors)?.draw(in: r, angle: angle) }

/// SF Symbol tinted and drawn centred in `r`.
func symbol(_ name: String, _ r: NSRect, _ color: NSColor = white, weight: NSFont.Weight = .semibold) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: r.height * 0.7, weight: weight)) else { return }
    let tinted = NSImage(size: base.size, flipped: false) { b in
        base.draw(in: b); color.set(); b.fill(using: .sourceAtop); return true }
    let s = min(r.width / base.size.width, r.height / base.size.height)
    let sz = NSSize(width: base.size.width * s, height: base.size.height * s)
    tinted.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

// MARK: - Video content

enum Look { case sunset, aurora }

/// A procedural film frame. `grade` > 1 boosts saturation (used to show enhancement presets).
func scene(_ r: NSRect, look: Look = .sunset, grade: CGFloat = 1) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: r).addClip()
    func c(_ rr: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        let base = NSColor(calibratedRed: rr, green: g, blue: b, alpha: 1)
        return NSColor(calibratedHue: base.hueComponent, saturation: min(1, base.saturationComponent * grade),
                       brightness: min(1, base.brightnessComponent * (1 + (grade - 1) * 0.15)), alpha: 1)
    }
    switch look {
    case .sunset:
        gradient(r, [c(0.10, 0.12, 0.35), c(0.75, 0.30, 0.45), c(1.0, 0.70, 0.35)], angle: -90)
        let sun = rect(r.midX - r.width * 0.16, r.minY + r.height * 0.36, r.width * 0.16, r.width * 0.16)
        c(1.0, 0.93, 0.7).setFill(); NSBezierPath(ovalIn: sun).fill()
        let layers: [(CGFloat, CGFloat, NSColor)] = [
            (0.52, 0.10, c(0.45, 0.25, 0.45)), (0.62, 0.14, c(0.27, 0.15, 0.38)),
            (0.74, 0.12, c(0.14, 0.09, 0.26)), (0.86, 0.10, c(0.05, 0.04, 0.12))]
        for (i, l) in layers.enumerated() {
            let p = NSBezierPath(); p.move(to: NSPoint(x: r.minX, y: r.maxY))
            var x = r.minX
            while x <= r.maxX {
                let t = (x - r.minX) / r.width
                p.line(to: NSPoint(x: x, y: r.minY + r.height * (l.0 + l.1 * 0.5 * sin(t * 9 + CGFloat(i) * 2.1) * cos(t * 3.7 + CGFloat(i)))))
                x += 8
            }
            p.line(to: NSPoint(x: r.maxX, y: r.maxY)); p.close(); l.2.setFill(); p.fill()
        }
    case .aurora:
        gradient(r, [c(0.01, 0.02, 0.10), c(0.02, 0.10, 0.22), c(0.03, 0.04, 0.12)], angle: -90)
        for (i, col) in [c(0.1, 0.9, 0.6), c(0.3, 0.6, 1.0), c(0.7, 0.3, 0.9)].enumerated() {
            let p = NSBezierPath(); p.move(to: NSPoint(x: r.minX, y: r.minY))
            var x = r.minX
            while x <= r.maxX {
                let t = (x - r.minX) / r.width
                p.line(to: NSPoint(x: x, y: r.minY + r.height * (0.18 + 0.07 * CGFloat(i) + 0.10 * sin(t * 6 + CGFloat(i) * 1.7))))
                x += 8
            }
            p.line(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.5)); p.line(to: NSPoint(x: r.minX, y: r.minY + r.height * 0.5)); p.close()
            NSGradient(colors: [col.withAlphaComponent(0.0), col.withAlphaComponent(0.65)])?.draw(in: p, angle: 90)
        }
        white.setFill()
        for i in 0..<140 {
            let x = r.minX + CGFloat((i * 7919) % 1000) / 1000 * r.width, y = r.minY + CGFloat((i * 104729) % 1000) / 1000 * r.height * 0.7
            NSBezierPath(ovalIn: rect(x, y, 4, 4)).fill()
        }
        let hill = NSBezierPath(); hill.move(to: NSPoint(x: r.minX, y: r.maxY))
        var x = r.minX
        while x <= r.maxX { hill.line(to: NSPoint(x: x, y: r.minY + r.height * (0.88 + 0.04 * sin((x - r.minX) / r.width * 7)))); x += 8 }
        hill.line(to: NSPoint(x: r.maxX, y: r.maxY)); hill.close(); NSColor.black.setFill(); hill.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Real UI pieces

/// Light macOS title bar + dark stage. Returns (content rect, video rect letterboxed to 16:9).
func playerWindow(_ r: NSRect, title: String) -> (NSRect, NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.65)
    sh.shadowBlurRadius = 90; sh.shadowOffset = NSSize(width: 0, height: -34); sh.set()
    fill(r, NSColor(white: 0.93, alpha: 1), radius: 30)
    NSGraphicsContext.restoreGraphicsState()
    let bar: CGFloat = 76
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: 30, yRadius: 30).addClip()
    gradient(rect(r.minX, r.minY, r.width, bar), [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.88, alpha: 1)], angle: -90)
    NSColor.black.setFill(); NSBezierPath(rect: rect(r.minX, r.minY + bar, r.width, r.height - bar)).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (i, col) in [NSColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                     NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
        col.setFill(); NSBezierPath(ovalIn: rect(r.minX + 34 + CGFloat(i) * 46, r.minY + 26, 24, 24)).fill()
    }
    text(title, 0, r.minY + 20, size: 34, weight: .semibold, color: NSColor(white: 0.32, alpha: 1), center: r.midX)
    let content = rect(r.minX, r.minY + bar, r.width, r.height - bar)
    let vh = content.width * 9 / 16
    let video = rect(content.minX, content.minY + (content.height - vh) / 2, content.width, vh)
    return (content, video)
}

/// Navy translucent rounded button/panel exactly like the player's glass controls.
func glass(_ r: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius); p.addClip()
    gradient(r, [navyTop, navyBottom], angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    stroke(r, NSColor(white: 1, alpha: 0.35), radius: radius, width: 2)
}

func cornerButtons(_ c: NSRect, sidebar: Bool = true) {
    let s = rect(c.minX + 36, c.minY + 40, 110, 110)
    if sidebar { glass(s, radius: 26); symbol("sidebar.left", rect(s.minX + 25, s.minY + 25, 60, 60)) }
    let a = rect(c.maxX - 36 - 128, c.minY + 40, 128, 128)
    glass(a, radius: 30); symbol("airplayvideo", rect(a.minX + 28, a.minY + 28, 72, 72))
}

/// The real bottom control bar: title, scrubber, transport, time, volume, and right-hand buttons.
func controlBar(_ c: NSRect, name: String, progress: CGFloat, time: String, volume: CGFloat = 0.8) {
    let b = rect(c.minX + 52, c.maxY - 290, c.width - 104, 250)
    glass(b, radius: 34)
    text(name, b.minX + 40, b.minY + 24, size: 40, weight: .semibold)
    let tl = rect(b.minX + 40, b.minY + 100, b.width - 80, 12)
    fill(tl, NSColor(white: 0, alpha: 0.35), radius: 6)
    fill(rect(tl.minX, tl.minY, tl.width * progress, 12), NSColor(white: 1, alpha: 0.55), radius: 6)
    fill(rect(tl.minX + tl.width * progress - 24, tl.midY - 17, 48, 34), white, radius: 17)
    let y = b.minY + 140, h: CGFloat = 70
    var x = b.minX + 40
    for n in ["backward.end.fill", "pause.fill", "forward.end.fill", "stop.fill"] {
        symbol(n, rect(x, y, 60, h)); x += 100
    }
    var rx = b.maxX - 40
    let compact = b.width < 1800   // narrow window: drop the volume slider and a few buttons
    text(time, 0, y + 14, size: 40, weight: .medium, center: compact ? b.minX + 640 : b.midX - 150)
    for n in ["line.3.horizontal", "arrow.up.left.and.arrow.down.right", "list.bullet", "airplayvideo", "captions.bubble", "repeat", "shuffle"].suffix(compact ? 3 : 7) {
        rx -= 70; symbol(n, rect(rx, y, 64, h)); rx -= 14
    }
    if compact { return }
    rx -= 20
    let vt = rect(rx - 260, y + h / 2 - 5, 260, 10)
    fill(vt, NSColor(white: 0, alpha: 0.35), radius: 5)
    fill(rect(vt.minX + vt.width * volume - 22, vt.midY - 17, 44, 34), white, radius: 17)
    symbol("speaker.wave.2.fill", rect(vt.minX - 90, y, 70, h))
}

/// On-screen display pill (the player shows these when a setting changes).
func osd(_ s: String, symbolName: String, centerX: CGFloat, y: CGFloat) {
    let w = CGFloat(s.count) * 25 + 190
    let r = rect(centerX - w / 2, y, w, 110)
    fill(r, NSColor(white: 0.05, alpha: 0.78), radius: 55)
    symbol(symbolName, rect(r.minX + 36, r.minY + 25, 60, 60), cyan)
    text(s, r.minX + 120, r.minY + 28, size: 44, weight: .semibold)
}

func infoCard(_ c: NSRect, lines: [String]) {
    let r = rect(c.minX + 190, c.minY + 40, 760, 60 + CGFloat(lines.count) * 52 + 20)
    fill(r, NSColor(white: 0.05, alpha: 0.75), radius: 30)
    text(lines[0], r.minX + 36, r.minY + 24, size: 46, weight: .bold)
    for (i, l) in lines.dropFirst().enumerated() { text(l, r.minX + 36, r.minY + 92 + CGFloat(i) * 52, size: 34, color: NSColor(white: 0.85, alpha: 1)) }
}

// MARK: - macOS context menus

struct MenuItem { var title: String; var checked = false; var submenu = false; var highlighted = false; var separator = false }
func sep() -> MenuItem { MenuItem(title: "", separator: true) }

/// Draws a macOS-style menu; returns the rect of each item row (for attaching submenus).
@discardableResult
func menu(_ items: [MenuItem], at origin: NSPoint, width: CGFloat) -> [NSRect] {
    let rowH: CGFloat = 52, sepH: CGFloat = 24, pad: CGFloat = 12
    let total = items.reduce(pad * 2) { $0 + ($1.separator ? sepH : rowH) }
    let r = rect(origin.x, origin.y, width, total)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.55); sh.shadowBlurRadius = 40; sh.shadowOffset = NSSize(width: 0, height: -14); sh.set()
    fill(r, NSColor(white: 0.97, alpha: 0.98), radius: 22)
    NSGraphicsContext.restoreGraphicsState()
    stroke(r, NSColor(white: 0, alpha: 0.14), radius: 22, width: 2)
    var y = r.minY + pad; var rows: [NSRect] = []
    for it in items {
        if it.separator { fill(rect(r.minX + 20, y + sepH / 2 - 1, width - 40, 2), NSColor(white: 0, alpha: 0.12)); y += sepH; rows.append(.zero); continue }
        let row = rect(r.minX + 10, y, width - 20, rowH); rows.append(row)
        if it.highlighted { fill(row, NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.98, alpha: 1), radius: 12) }
        let col = it.highlighted ? white : NSColor(white: 0.1, alpha: 1)
        if it.checked { symbol("checkmark", rect(row.minX + 14, row.minY + 10, 32, 32), col) }
        text(it.title, row.minX + 58, row.minY + 7, size: 31, color: col)
        if it.submenu { symbol("chevron.right", rect(row.maxX - 48, row.minY + 11, 24, 30), col) }
        y += rowH
    }
    return rows
}

// MARK: - Page chrome

func background(headline: String, sub: String) {
    gradient(rect(0, 0, CGFloat(W), CGFloat(H)),
             [NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.12, alpha: 1), NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.28, alpha: 1)], angle: -35)
    text(headline, 0, 62, size: 112, weight: .bold, center: CGFloat(W) / 2)
    text(sub, 0, 210, size: 50, color: cyan, center: CGFloat(W) / 2)
}

let winRect = rect(300, 320, 2280, 1400)

func clip(_ r: NSRect, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: r).addClip(); body(); NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Screens

func shot1() {
    background(headline: "Plays Almost Anything", sub: "Native macOS playback plus FFmpeg for MKV, AVI, DVD and Blu-ray")
    let (c, v) = playerWindow(winRect, title: "vplay — Sunset Ridge.mp4")
    clip(c) {
        scene(v)
        infoCard(c, lines: ["Sunset Ridge", "3:20  ·  MP4  ·  8.0 Mbps", "H.264 1920×1080  ·  AAC stereo"])
        cornerButtons(c)
        controlBar(c, name: "Sunset Ridge.mp4", progress: 0.46, time: "01:32 / 03:20")
    }
}

func shot2() {
    background(headline: "Every Feature, One Panel", sub: "Files, discs, playlists, tracks, AirPlay and more, one Tab away")
    let (c, _) = playerWindow(winRect, title: "vplay")
    clip(c) {
        if let s = splash { s.draw(in: rect(c.minX + 560, c.minY + 20, c.width - 560, (c.width - 560) * 9 / 16 + 120), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        let p = rect(c.minX + 36, c.minY + 36, 800, c.height - 72)
        glass(p, radius: 34)
        let btns: [(String, String)] = [("doc", "Open File…"), ("link", "Open URL…"), ("folder", "Open Folder…"), ("opticaldisc", "Open Disc…"),
                                        ("list.bullet", "Playlist"), ("shuffle", "Shuffle"), ("captions.bubble", "Tracks"), ("airplayvideo", "AirPlay"),
                                        ("waveform", "Visualizer"), ("speedometer", "FPS"), ("slider.horizontal.3", "Post-Process"), ("wand.and.stars", "Shaders")]
        let bw: CGFloat = 236, bh: CGFloat = 120
        for (i, b) in btns.enumerated() {
            let r = rect(p.minX + 30 + CGFloat(i % 3) * (bw + 14), p.minY + 30 + CGFloat(i / 3) * (bh + 14), bw, bh)
            fill(r, NSColor(white: 1, alpha: 0.14), radius: 22); stroke(r, NSColor(white: 1, alpha: 0.25), radius: 22, width: 1.5)
            symbol(b.0, rect(r.midX - 22, r.minY + 14, 44, 44))
            text(b.1, 0, r.minY + 70, size: 27, weight: .medium, center: r.midX)
        }
        // File browser
        let bt = p.minY + 30 + 4 * (bh + 14) + 8
        text("Movies", p.minX + 34, bt, size: 38, weight: .bold)
        symbol("opticaldisc", rect(p.maxX - 150, bt - 2, 50, 50)); symbol("play.rectangle.on.rectangle", rect(p.maxX - 90, bt - 2, 56, 50))
        let files = [("folder.fill", "Holiday 2026"), ("folder.fill", "Concert Films"), ("film", "Sunset Ridge.mp4"), ("film", "Neon Cells.mkv"),
                     ("film", "Fractal Voyage.avi"), ("music.note", "Midnight Circuit.m4a")]
        for (i, f) in files.enumerated() {
            let r = rect(p.minX + 24, bt + 62 + CGFloat(i) * 70, p.width - 48, 62)
            if i == 2 { fill(r, NSColor(white: 1, alpha: 0.22), radius: 14) }
            symbol(f.0, rect(r.minX + 16, r.minY + 10, 44, 42), i < 2 ? cyan : white, weight: .regular)
            text(f.1, r.minX + 80, r.minY + 12, size: 32)
        }
    }
}

func aiVideoMenu() {
    let (c, v) = playerWindow(winRect, title: "vplay — Sunset Ridge.mp4")
    clip(c) {
        scene(v, grade: 1.4)
        cornerButtons(c, sidebar: false)
        osd("AI Video: Cinema HDR", symbolName: "sparkles", centerX: c.midX, y: c.minY + 50)
    }
    let ox = c.minX + 120, oy = c.minY + 170
    let parent = menu([MenuItem(title: "Play"), MenuItem(title: "Next"), MenuItem(title: "Previous"), MenuItem(title: "Mute"),
                       MenuItem(title: "Speed", submenu: true), sep(), MenuItem(title: "Tracks & Subtitles…"), MenuItem(title: "Playlist…"),
                       MenuItem(title: "AirPlay…"), MenuItem(title: "Show Menu Panel"), sep(), MenuItem(title: "Video", submenu: true),
                       MenuItem(title: "AI Video Enhancement", submenu: true, highlighted: true), MenuItem(title: "AI Audio", submenu: true), sep(),
                       MenuItem(title: "Shuffle"), MenuItem(title: "Visualizer"), MenuItem(title: "FPS Display"), MenuItem(title: "Take Snapshot"),
                       MenuItem(title: "Media Info")], at: NSPoint(x: ox, y: oy), width: 560)
    let hi = parent[12]
    let sub = menu([MenuItem(title: "Off"), sep(), MenuItem(title: "Vivid & Crisp"), MenuItem(title: "Cinema HDR", checked: true), MenuItem(title: "Anime Pop"),
                    MenuItem(title: "Super Resolution 2×"), MenuItem(title: "Clean Restore (Denoise)"), sep(),
                    MenuItem(title: "AI Upscaling", submenu: true, highlighted: true), MenuItem(title: "Clarity"), MenuItem(title: "Sharpen"), MenuItem(title: "Denoise"),
                    MenuItem(title: "Micro Contrast"), MenuItem(title: "Vivid Color"), MenuItem(title: "HDR Tone Mapping", checked: true),
                    MenuItem(title: "Cinema Color Grade"), MenuItem(title: "Subject Focus (Vision)")],
                   at: NSPoint(x: hi.maxX + 14, y: oy), width: 600)
    let up = sub[8]
    menu([MenuItem(title: "Off"), MenuItem(title: "1.5×"), MenuItem(title: "2×"), MenuItem(title: "3×"), MenuItem(title: "4×", checked: true)],
         at: NSPoint(x: up.maxX + 14, y: up.minY - 12), width: 340)
}

func shot3() {
    background(headline: "AI Video Enhancement", sub: "Cinema HDR, vivid color, denoise, clarity and up to 4× upscaling")
    aiVideoMenu()
}

func shot4() {
    background(headline: "Hi-Res Audio & Surround Upmix", sub: "Upsample to 384 kHz, 5.1 / 7.1 upmix, dialogue boost and night mode")
    let (c, v) = playerWindow(winRect, title: "vplay — Midnight Circuit.m4a")
    clip(c) {
        scene(v, look: .aurora)
        // Spectrum bars like the built-in visualizer
        for i in 0..<64 {
            let t = CGFloat(i) / 64
            let h = 60 + 300 * abs(sin(t * 11 + 1.3)) * (0.5 + 0.5 * cos(t * 3))
            let r = rect(c.minX + 140 + CGFloat(i) * 31, v.maxY - 100 - h, 20, h)
            NSGradient(colors: [cyan, NSColor(calibratedRed: 0.55, green: 0.4, blue: 1, alpha: 1)])?.draw(in: NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8), angle: 90)
        }
        cornerButtons(c, sidebar: false)
        osd("Sample Rate: 384 kHz", symbolName: "waveform.badge.magnifyingglass", centerX: c.midX, y: c.minY + 50)
    }
    let ox = c.minX + 120, oy = c.minY + 170
    let parent = menu([MenuItem(title: "Play"), MenuItem(title: "Next"), MenuItem(title: "Previous"), MenuItem(title: "Mute"),
                       MenuItem(title: "Speed", submenu: true), sep(), MenuItem(title: "Video", submenu: true),
                       MenuItem(title: "AI Video Enhancement", submenu: true), MenuItem(title: "AI Audio", submenu: true, highlighted: true), sep(),
                       MenuItem(title: "Visualizer", checked: true), MenuItem(title: "Media Info")], at: NSPoint(x: ox, y: oy), width: 560)
    let hi = parent[8]
    let sub = menu([MenuItem(title: "Off"), sep(), MenuItem(title: "Clear Dialogue"), MenuItem(title: "Spatial 3D"), MenuItem(title: "Surround 5.1 Upmix", checked: true),
                    MenuItem(title: "Surround 7.1 Upmix"), MenuItem(title: "Studio Master"), MenuItem(title: "Night Mode"), MenuItem(title: "Loudness Normalize"),
                    MenuItem(title: "Bass Punch"), sep(), MenuItem(title: "Upsample to Surround", submenu: true),
                    MenuItem(title: "Upsample Sample Rate", submenu: true, highlighted: true), sep(), MenuItem(title: "Dialogue Boost"),
                    MenuItem(title: "Harmonic Crystalizer"), MenuItem(title: "Bass Impact"), MenuItem(title: "Treble Sparkle")],
                   at: NSPoint(x: hi.maxX + 14, y: oy), width: 560)
    let rate = sub[12]
    menu([MenuItem(title: "Source Rate"), MenuItem(title: "48 kHz"), MenuItem(title: "96 kHz"), MenuItem(title: "192 kHz"), MenuItem(title: "384 kHz", checked: true)],
         at: NSPoint(x: rate.maxX + 14, y: rate.minY - 12), width: 380)
}

func slider(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ label: String, _ v: CGFloat, _ shown: String) {
    text(label, x, y, size: 30, color: NSColor(white: 0.15, alpha: 1))
    text(shown, 0, y, size: 30, color: NSColor(white: 0.45, alpha: 1), right: x + w)
    let tl = rect(x, y + 50, w, 10)
    fill(tl, NSColor(white: 0.78, alpha: 1), radius: 5)
    fill(rect(tl.minX, tl.minY, w * v, 10), NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.98, alpha: 1), radius: 5)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.35); sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -2); sh.set()
    white.setFill(); NSBezierPath(ovalIn: rect(tl.minX + w * v - 17, tl.midY - 17, 34, 34)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func shot5() {
    background(headline: "Shape the Picture", sub: "Post-processing sliders, filter chains and your own Core Image shaders")
    let pw = rect(300, 320, 1750, 1400)
    let (c, v) = playerWindow(pw, title: "vplay — Sunset Ridge.mp4")
    clip(c) {
        scene(v, grade: 1.5)
        cornerButtons(c, sidebar: false)
        // FPS pill
        let f = rect(c.minX + 40, c.minY + 40, 290, 70); fill(f, NSColor(white: 0, alpha: 0.65), radius: 35)
        text("FPS 30.0 / 30", f.minX + 28, f.minY + 15, size: 32, weight: .semibold)
        controlBar(c, name: "Sunset Ridge.mp4", progress: 0.46, time: "01:32 / 03:20", volume: 0.7)
    }
    // Post-Processing window (light AppKit window)
    let w = rect(1760, 440, 820, 1230)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.6); sh.shadowBlurRadius = 70; sh.shadowOffset = NSSize(width: 0, height: -26); sh.set()
    fill(w, NSColor(white: 0.93, alpha: 1), radius: 26)
    NSGraphicsContext.restoreGraphicsState()
    for (i, col) in [NSColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1), NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
        col.setFill(); NSBezierPath(ovalIn: rect(w.minX + 30 + CGFloat(i) * 42, w.minY + 24, 22, 22)).fill()
    }
    text("Post-Processing", 0, w.minY + 20, size: 32, weight: .semibold, color: NSColor(white: 0.3, alpha: 1), center: w.midX)
    let rows: [(String, CGFloat, String)] = [("Level", 0.8, "80%"), ("Brightness", 0.55, "+0.05"), ("Contrast", 0.62, "1.25"), ("Saturation", 0.75, "1.50"),
                                            ("Hue", 0.5, "0°"), ("Gamma", 0.5, "1.00"), ("Exposure", 0.5, "0.0"), ("Warmth", 0.6, "+0.20"),
                                            ("Sharpness", 0.6, "0.60"), ("Noise Reduction", 0.2, "0.20"), ("Blur", 0.0, "0.0"), ("Vignette", 0.35, "0.35")]
    for (i, r) in rows.enumerated() { slider(w.minX + 50, w.minY + 100 + CGFloat(i) * 83, w.width - 100, r.0, r.1, r.2) }
    // checkbox + buttons
    fill(rect(w.minX + 50, w.maxY - 120, 40, 40), NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.98, alpha: 1), radius: 10); symbol("checkmark", rect(w.minX + 56, w.maxY - 114, 28, 28), white)
    text("Enabled", w.minX + 110, w.maxY - 118, size: 30, color: NSColor(white: 0.15, alpha: 1))
    for (i, t) in ["Shader Editor…", "Reset"].enumerated() {
        let b = i == 0 ? rect(w.maxX - 50 - 190 - 20 - 280, w.maxY - 126, 280, 54) : rect(w.maxX - 50 - 190, w.maxY - 126, 190, 54)
        fill(b, NSColor(white: 0.84, alpha: 1), radius: 14); text(t, 0, b.minY + 9, size: 29, color: NSColor(white: 0.1, alpha: 1), center: b.midX)
    }
}

// MARK: - Render

let shots: [(String, () -> Void)] = [("01-plays-almost-anything", shot1), ("02-every-feature-one-panel", shot2),
                                    ("03-ai-video-enhancement", shot3), ("04-hi-res-audio-surround-upmix", shot4),
                                    ("05-shape-the-picture", shot5)]
for (name, draw) in shots {
    // hasAlpha: false => no alpha channel, as App Store Connect requires.
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 3,
                                     hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("bitmap") }
    let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = flipped
    ctx.cgContext.translateBy(x: 0, y: CGFloat(H)); ctx.cgContext.scaleBy(x: 1, y: -1)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}
