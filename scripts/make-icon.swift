#!/usr/bin/env swift
// Draws the Foretype app icon and writes mac/Resources/AppIcon.icns, plus a 256 px PNG of it
// for the README (docs/images/icon.png).
//
//   swift scripts/make-icon.swift            # both files
//   swift scripts/make-icon.swift out.icns   # only the .icns, elsewhere
//
// The icon is the product in one picture: a white caret on a dark ink tile with a light-gray
// "ghost" word trailing it. The tile follows Apple's macOS icon template: an 824 px rounded
// square centred on the 1024 px canvas, with a soft shadow. macOS 14 and 15 show it as drawn;
// macOS 26 and later recognise the shape and scale the tile up to fill their own mask, so it
// is not boxed into a gray tile (checked on macOS 27 with NSWorkspace.icon(forFile:)). Each
// iconset size is drawn on its own: at 16 and 32 px the word becomes two bars and the caret
// gets heavier, since letters there would be a gray smudge.
//
// Needs only the Command Line Tools (CoreGraphics, CoreText, iconutil); no Xcode, no actool.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("mac/Resources/AppIcon.icns")
let preview = root.appendingPathComponent("docs/images/icon.png")

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

/// The tile: a superellipse (|x|^5 + |y|^5 = 1), close to Apple's continuous-corner icon shape.
func tilePath(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0, steps = 720
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = copysign(pow(abs(c), 2 / n), c), y = copysign(pow(abs(s), 2 / n), s)
        let p = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// Glyph outlines of `text`, its baseline starting at `origin`, and the text's width.
func textPath(_ text: String, font: CTFont, origin: CGPoint) -> (CGPath, CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for (g, p) in zip(glyphs, positions) {
            guard let outline = CTFontCreatePathForGlyph(font, g, nil) else { continue }
            path.addPath(outline, transform: CGAffineTransform(translationX: origin.x + p.x, y: origin.y + p.y))
        }
    }
    return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

func roundedFont(size: CGFloat) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    return (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
}

/// The tile's contents, in tile units: (0, 0)-(1024, 1024) is the whole tile. `small` is the
/// simplified art for 16 and 32 px.
func drawTile(_ ctx: CGContext, small: Bool) {
    let tile = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    ctx.addPath(tilePath(tile))
    ctx.clip()
    // Dark ink, a little lighter at the top, with a faint light from the upper left.
    let ink = CGGradient(colorsSpace: srgb, colors: [color(0x2D323D), color(0x14171C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ink, start: CGPoint(x: 0, y: 1024), end: .zero, options: [])
    let light = CGGradient(colorsSpace: srgb, colors: [color(0xFFFFFF, 0.07), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(light, startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 820), endRadius: 760, options: [])

    // The ghost word, gray and fading out to the right like a suggestion not yet taken.
    let caretX: CGFloat, caret: CGRect, ghost: CGPath, ghostStart: CGFloat, ghostEnd: CGFloat
    if small {
        caretX = 260
        caret = CGRect(x: caretX - 55, y: 222, width: 110, height: 580)
        let bars = CGMutablePath()
        for (x, w) in [(380.0, 290.0), (710.0, 170.0)] {
            bars.addRoundedRect(in: CGRect(x: x, y: 437, width: w, height: 150), cornerWidth: 75, cornerHeight: 75)
        }
        (ghost, ghostStart, ghostEnd) = (bars, 380, 880)
    } else {
        caretX = 205
        caret = CGRect(x: caretX - 22, y: 290, width: 44, height: 490)
        let (word, width) = textPath("type", font: roundedFont(size: 320), origin: CGPoint(x: 257, y: 430))
        (ghost, ghostStart, ghostEnd) = (word, 257, 257 + width)
    }
    ctx.saveGState()
    ctx.addPath(ghost)
    ctx.clip()
    let fade = CGGradient(colorsSpace: srgb, colors: [color(0xB4BAC6, 0.95), color(0x8A909C, 0.55)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: ghostStart, y: 0), end: CGPoint(x: ghostEnd, y: 0), options: [])
    ctx.restoreGState()

    // The caret: a plain round-ended bar (an I-beam's serifs make it read as the letter I),
    // white, with a soft glow.
    if !small { ctx.setShadow(offset: .zero, blur: 30 * ctx.ctm.a, color: color(0xFFFFFF, 0.35)) }
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(CGPath(roundedRect: caret, cornerWidth: caret.width / 2, cornerHeight: caret.width / 2, transform: nil))
    ctx.fillPath()
}

func icon(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = CGFloat(px) / 1024
    // Apple's template: the tile is 824 of the canvas's 1024 px, with a shadow below it.
    let tile = CGRect(x: 0, y: 0, width: px, height: px).insetBy(dx: 100 * u, dy: 100 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 20 * u, color: color(0x000000, 0.3))
    ctx.setFillColor(color(0x14171C))
    ctx.addPath(tilePath(tile))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    drawTile(ctx, small: px <= 32)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Foretype-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(icon(px: points * scale), to: iconset.appendingPathComponent(name))
    }
}
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("icon: \(output.path)")
if CommandLine.arguments.count == 1 {
    try fm.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
    write(icon(px: 256), to: preview)
    print("preview: \(preview.path)")
}
