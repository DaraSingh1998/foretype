import AppKit
import ApplicationServices
import IOKit

/// `Foretype --caret-selftest`: renders text fields with a caret in several fonts, colour
/// schemes and scales, and checks both detectors and the width advance. No permissions.
enum PixelCaretSelfTest {
    struct Scheme {
        var name: String
        var background: NSColor
        var text: NSColor
        var caret: NSColor
    }

    struct Scene {
        var font: NSFont
        var scale: CGFloat
        var scheme: Scheme
        var caretWidth: CGFloat
        var line: String
        var caretOn: Bool
    }

    static let size = CGSize(width: 420, height: 60)
    static let textOrigin = CGPoint(x: 16, y: 18)

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// The scene as a frame, plus the caret's centre x and the line's top (points).
    static func render(_ s: Scene) -> (PixelFrame, CGFloat, CGFloat) {
        let w = Int(size.width * s.scale), h = Int(size.height * s.scale)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let caretX = textOrigin.x + FontMatcher.width(s.line, s.font)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: s.scale, y: -s.scale)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            s.scheme.background.setFill()
            NSRect(origin: .zero, size: size).fill()
            (s.line as NSString).draw(at: textOrigin, withAttributes: [.font: s.font, .foregroundColor: s.scheme.text])
            if s.caretOn {
                s.scheme.caret.setFill()
                NSRect(x: caretX, y: textOrigin.y, width: s.caretWidth, height: lineHeight(s.font)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return (PixelFrame(width: w, height: h, bytes: buf, origin: .zero, scale: s.scale), caretX + s.caretWidth / 2, textOrigin.y)
    }

    static func run() -> Bool {
        let schemes = [
            Scheme(name: "light/accent", background: .white, text: .black, caret: NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)),
            Scheme(name: "light/black", background: .white, text: .black, caret: .black),
            Scheme(name: "dark/white", background: NSColor(white: 0.12, alpha: 1), text: NSColor(white: 0.9, alpha: 1), caret: .white),
        ]
        let fonts: [(NSFont?, CGFloat)] = [
            (NSFont(name: "Helvetica", size: 13), 2), (NSFont(name: "Georgia", size: 17), 2),
            (NSFont(name: "Menlo", size: 12), 1), (NSFont.systemFont(ofSize: 14), 2), (NSFont(name: "Times New Roman", size: 12), 1),
        ]
        let line = "Hill | file l1"
        let more = " will follow"
        var ok = true
        var worst: CGFloat = 0
        var cases = 0
        for scheme in schemes {
            for case let (font?, scale) in fonts {
                for caretWidth: CGFloat in [1, 2] {
                    cases += 1
                    let base = Scene(font: font, scale: scale, scheme: scheme, caretWidth: caretWidth, line: line, caretOn: true)
                    var off = base; off.caretOn = false
                    let (onFrame, x, top) = render(base)
                    let (offFrame, _, _) = render(off)
                    var acc = PixelCaret.BlinkAccumulator(onFrame)
                    _ = acc.add(offFrame)
                    _ = acc.add(onFrame)
                    let label = "\(scheme.name) \(font.fontName) \(Int(font.pointSize))pt @\(Int(scale))x caret \(Int(caretWidth))pt"
                    guard let (bar, look) = acc.bar(hint: nil) else {
                        print("\(label): blink NOT FOUND"); ok = false; continue
                    }
                    let r = onFrame.global(x0: bar.centerX, x1: bar.centerX, y0: bar.y0, y1: bar.y1)
                    let dx = abs(r.minX - x), dy = abs(r.minY - top)
                    worst = max(worst, dx)
                    var pass = dx <= 0.5 && dy <= 1 && abs(look.height - lineHeight(font)) <= 1
                    // Static: the line grew; the prediction is 7 pt off.
                    var grown = base; grown.line = line + more
                    let (gFrame, gx, _) = render(grown)
                    let sb = PixelCaret.staticBar(gFrame, look: look, near: CGPoint(x: gx + 7, y: top + look.height / 2), radius: 30)
                    let sdx = sb.map { abs(gFrame.global(x0: $0.centerX, x1: $0.centerX, y0: $0.y0, y1: $0.y1).minX - gx) }
                    worst = max(worst, sdx ?? 0)
                    pass = pass && (sdx ?? 99) <= 0.5
                    if ProcessInfo.processInfo.environment["CARET_DEBUG"] != nil, let b = sb {
                        let y = (b.y0 + b.y1) / 2
                        let cols = (max(0, b.x0 - 3)...min(gFrame.width - 1, b.x1 + 3)).map { x -> String in
                            let c = gFrame.rgb(x, y); return "\(x):\(c.r),\(c.g),\(c.b)"
                        }
                        print("  bar x\(b.x0)-\(b.x1) y\(b.y0)-\(b.y1) cx \(b.centerX) expected \(gx * scale) cols \(cols)")
                    }
                    // Negatives: caret off (glyph stems must not match), no toggle, typing between captures.
                    var gOff = grown; gOff.caretOn = false
                    let falseStatic = PixelCaret.staticBar(render(gOff).0, look: look, near: CGPoint(x: gx, y: top + look.height / 2), radius: 30)
                    var still = PixelCaret.BlinkAccumulator(offFrame); _ = still.add(offFrame)
                    var typed = PixelCaret.BlinkAccumulator(onFrame); _ = typed.add(gFrame)
                    let falseBlink = still.bar(hint: nil) != nil || typed.bar(hint: nil) != nil
                    pass = pass && falseStatic == nil && !falseBlink
                    ok = ok && pass
                    print(String(format: "%@: blink dx %.2f dy %.2f h %.1f/%.0f, static dx %@%@%@ %@", label, dx, dy, look.height,
                                 lineHeight(font), sdx.map { String(format: "%.2f", $0) } ?? "none",
                                 falseStatic != nil ? ", FALSE static" : "", falseBlink ? ", FALSE blink" : "", pass ? "ok" : "FAILED"))
                }
            }
        }
        // Advance: typed and deleted text moves the estimate by its rendered width.
        let f = NSFont(name: "Helvetica", size: 13)!
        let typedW = PixelCaretProvider.advance(from: "Thanks for the", to: "Thanks for the notes", font: f)
        let backW = PixelCaretProvider.advance(from: "Thanks for the notes", to: "Thanks for the no", font: f)
        let advanceOK = abs(typedW - FontMatcher.width(" notes", f)) < 0.01 && abs(backW + FontMatcher.width("tes", f)) < 0.5
        print(String(format: "advance: +%.2f / %.2f pt %@", typedW, backW, advanceOK ? "ok" : "FAILED"))
        ok = ok && advanceOK
        // CPU cost of one blink step on a field-sized and a window-sized region (2×).
        for (name, w, h) in [("field 656x384 pt", 1312, 768), ("window 1492x875 pt", 2984, 1750)] {
            let blank = PixelFrame(width: w, height: h, bytes: [UInt8](repeating: 255, count: w * h * 4), origin: .zero, scale: 2)
            var acc = PixelCaret.BlinkAccumulator(blank)
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = acc.add(blank)
            let t1 = CFAbsoluteTimeGetCurrent()
            _ = acc.bar(hint: nil)
            let t2 = CFAbsoluteTimeGetCurrent()
            print(String(format: "cost, %@: add a frame %.1f ms, search %.1f ms", name, (t1 - t0) * 1000, (t2 - t1) * 1000))
        }
        print(String(format: "%d cases, worst error %.2f pt", cases, worst))
        print(ok ? "caret self-test passed" : "caret self-test FAILED")
        return ok
    }
}

/// `Foretype --caret-measure PID TITLE [POSITIONS]`: compares the pixel caret with the
/// Accessibility caret in a document the caller opened (TextEdit has correct AX geometry).
/// Moves the caret by setting `AXSelectedTextRange` only (no keystrokes) and restores it.
/// Refuses to run unless FORETYPE_ONLY_APPS names the app, the app is frontmost and its
/// focused window's title contains TITLE; stops as soon as either changes.
enum CaretBench {
    struct Row {
        var pos: Int
        /// Which text element (apps with one element per paragraph); printed as field × 1000 + pos.
        var field: Int
        var kind: String
        var ax: CGRect?
        var axStrategy: String
        var raw: CGRect?
        var blink: PixelCaretHit?
        var verify: PixelCaretHit?
        var advance: CGFloat?
        /// The same advance measured in the fallback font (no AX font), raw and with the
        /// width scale learned from the previous lines, as PixelCaretProvider does.
        var generic: CGFloat?
        var learned: CGFloat?
    }

    static func say(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

    /// Seconds since the last keyboard or mouse input (IOHIDSystem's HIDIdleTime).
    static func hidIdle() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? NSNumber).map { $0.doubleValue / 1e9 }
    }

    static func run(pid: pid_t, title: String, positions wanted: Int) -> Bool {
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let only = AppSettings().onlyApps
        guard !only.isEmpty, only.contains(bundle) || only.contains(String(pid)) else {
            say("refusing: FORETYPE_ONLY_APPS must name \(bundle.isEmpty ? String(pid) : bundle)")
            return false
        }
        AXUIElementSetMessagingTimeout(AX.systemWide, 0.5)
        let app = AXUIElementCreateApplication(pid)
        let started = CFAbsoluteTimeGetCurrent()
        func guardFront() -> Bool {
            // Any keyboard or mouse input since the start means the user is back: stop.
            if let idle = hidIdle(), idle + 0.5 < CFAbsoluteTimeGetCurrent() - started {
                say("ABORT: the user is active again")
                return false
            }
            guard AX.bool(AX.copy(app, kAXFrontmostAttribute)) == true,
                  let w = AX.element(AX.copy(app, kAXFocusedWindowAttribute)),
                  (AX.string(w, kAXTitleAttribute) ?? "").contains(title) else {
                say("ABORT: \(bundle) is not frontmost with the test document (\(title)) in front")
                return false
            }
            return true
        }
        guard guardFront(), let win = AX.element(AX.copy(app, kAXFocusedWindowAttribute)) else { return false }
        struct Field { var el: AXUIElement; var value: NSString; var frame: CGRect? }
        var fields: [Field] = []
        var orig: CFRange?
        if let el = AX.element(AX.copy(app, kAXFocusedUIElementAttribute)),
           let sel = AX.range(AX.copy(el, kAXSelectedTextRangeAttribute)) {
            orig = sel
            fields = [Field(el: el, value: (AX.string(el, kAXValueAttribute) ?? "") as NSString, frame: AX.frame(el))]
        } else {
            // No focused element, e.g. LibreOffice right after opening a document: one text
            // element per paragraph; use the window's, top to bottom.
            func walk(_ e: AXUIElement, _ depth: Int) {
                if AX.string(e, kAXRoleAttribute) == "AXTextArea", let v = AX.string(e, kAXValueAttribute), v.count >= 16 {
                    fields.append(Field(el: e, value: v as NSString, frame: AX.frame(e)))
                }
                guard depth < 12 else { return }
                for c in (AX.copy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
            }
            walk(win, 0)
            fields.sort { ($0.frame?.minY ?? 0) < ($1.frame?.minY ?? 0) }
            say("no focused element: \(fields.count) paragraph elements in the window")
        }
        guard !fields.isEmpty else {
            say("no text element")
            return false
        }
        let windowFrame = AX.frame(win)
        say("\(bundle) pid \(pid) role \(AX.string(fields[0].el, kAXRoleAttribute) ?? "") chars \(fields[0].value.length) " +
            "field \(fields[0].frame.map { "\($0)" } ?? "none") window \(windowFrame.map { "\($0)" } ?? "none")")

        // Line ends and mid-line word boundaries of the first lines with some text.
        var targets: [(Int, String, Int)] = []   // (position, kind, field)
        for (fi, field) in fields.enumerated() {
            let value = field.value
            var start = 0
            while start < value.length, targets.count < wanted {
                var end = value.range(of: "\n", range: NSRange(location: start, length: value.length - start)).location
                if end == NSNotFound { end = value.length }
                if end - start >= 16 {
                    let mid = value.range(of: " ", range: NSRange(location: start + (end - start) * 2 / 5, length: (end - start) * 3 / 5)).location
                    if mid != NSNotFound, mid < end - 4 { targets.append((mid, "mid", fi)) }
                    targets.append((end, "end", fi))
                }
                start = end + 1
            }
        }
        let font = CaretResolver.font(fields[0].el, caret: targets.first?.0 ?? 1, length: fields[0].value.length)
        say("font \(font.map { "\($0.fontName) \($0.pointSize)" } ?? "none (system font fallback)")")

        func move(_ fi: Int, _ pos: Int) {
            var r = CFRange(location: pos, length: 0)
            AX.set(fields[fi].el, kAXSelectedTextRangeAttribute, AXValueCreate(.cfRange, &r)!)
        }
        func restore() { move(0, orig?.location ?? 0) }
        func searchRegion(_ fi: Int, whole: Bool) -> CGRect? {
            if !whole, let f = fields[fi].frame, f.width >= 20, f.height >= 8 { return f.insetBy(dx: -6, dy: -6) }
            return windowFrame
        }

        // Raw capture cost of the field region.
        var captureMs: [Double] = []
        if let region = searchRegion(0, whole: false) {
            for _ in 0..<8 {
                let t0 = CFAbsoluteTimeGetCurrent()
                if PixelCaret.capture(pid: pid, windowFrame: windowFrame, region: region) != nil {
                    captureMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                }
            }
        }

        var rows: [Row] = []
        var wholeWindow = false
        var prevMid: (pos: Int, field: Int, hit: PixelCaretHit)?
        var widthScale: CGFloat = 1
        for (pos, kind, fi) in targets {
            guard guardFront() else { restore(); return false }
            let el = fields[fi].el
            move(fi, pos)
            usleep(120_000)
            let ax = CaretResolver.resolve(el, caret: pos, frame: fields[fi].frame, bundleId: bundle)
            let raw = pos > 0 ? AX.bounds(el, pos - 1, 1) : nil
            var row = Row(pos: pos, field: fi, kind: kind, ax: ax?.rect, axStrategy: ax?.strategy ?? "none", raw: raw)
            for whole in wholeWindow ? [true] : [false, true] {
                guard let region = searchRegion(fi, whole: whole) else { continue }
                row.blink = PixelCaret.blink(pid: pid, windowFrame: windowFrame, region: region, hint: nil)
                if row.blink != nil { wholeWindow = whole; break }
            }
            if let hit = row.blink {
                // As after typing: arrive from elsewhere (restarts the blink, caret solid), one
                // capture 60 ms later, prediction 6 pt off.
                guard guardFront() else { restore(); return false }
                move(fi, max(0, pos - 1)); usleep(30_000); move(fi, pos); usleep(60_000)
                let near = CGPoint(x: (ax?.rect.minX ?? hit.rect.minX) + 6, y: hit.rect.midY)
                row.verify = PixelCaret.verify(pid: pid, windowFrame: windowFrame, near: near, look: hit.look, radius: 24)
                if kind == "end", let m = prevMid, m.field == fi {
                    let fallback = NSFont.systemFont(ofSize: max(11, m.hit.rect.height * 0.78))
                    let typed = fields[fi].value.substring(with: NSRange(location: m.pos, length: pos - m.pos))
                    row.advance = m.hit.rect.minX + FontMatcher.width(typed, font ?? fallback)
                    let measured = FontMatcher.width(typed, fallback)
                    row.generic = m.hit.rect.minX + measured
                    row.learned = m.hit.rect.minX + measured * widthScale
                    let ratio = (hit.rect.minX - m.hit.rect.minX) / measured
                    if measured >= 30, ratio > 0.6, ratio < 1.6 { widthScale = (widthScale + ratio) / 2 }
                }
                prevMid = kind == "mid" ? (pos, fi, hit) : nil
            } else {
                prevMid = nil
            }
            rows.append(row)
        }
        restore()

        func f(_ v: CGFloat?) -> String { v.map { String(format: "%7.1f", $0) } ?? "      -" }
        say("pos  kind  AX x / y / h (strategy)            raw prev-char x / y      pixel x / y / h  frames  ms     verify x   ms   advance x")
        for r in rows {
            say("\(String(format: "%4d", r.pos + 1000 * r.field)) \(r.kind.padding(toLength: 4, withPad: " ", startingAt: 0)) " +
                "\(f(r.ax?.minX))\(f(r.ax?.minY))\(f(r.ax?.height)) \(r.axStrategy.padding(toLength: 18, withPad: " ", startingAt: 0)) " +
                "\(f(r.raw?.maxX))\(f(r.raw?.minY))   \(f(r.blink?.rect.minX))\(f(r.blink?.rect.minY))\(f(r.blink?.rect.height)) " +
                "\(String(format: "%5d", r.blink?.frames ?? 0)) \(f(r.blink.map { CGFloat($0.ms) }))  \(f(r.verify?.rect.minX)) " +
                "\(f(r.verify.map { CGFloat($0.ms) }))  \(f(r.advance))")
        }
        func stats(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "n/a" }
            let s = v.sorted()
            return String(format: "median %.2f, p90 %.2f, max %.2f (n=%d)", s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))], s.last!, s.count)
        }
        let found = rows.filter { $0.blink != nil }
        let withAX = rows.filter { $0.blink != nil && $0.ax != nil }
        say("blink found \(found.count)/\(rows.count); verify found \(rows.filter { $0.verify != nil }.count)/\(found.count)")
        say("blink x error vs AX (pt): " + stats(withAX.map { Double(abs($0.blink!.rect.minX - $0.ax!.minX)) }))
        say("blink signed x error vs AX (pt): " + stats(withAX.map { Double($0.blink!.rect.minX - $0.ax!.minX) }))
        say("blink centre y error vs AX (pt): " + stats(withAX.map { Double(abs($0.blink!.rect.midY - $0.ax!.midY)) }))
        say("verify x error vs AX (pt): " + stats(rows.compactMap { r in r.verify.flatMap { v in r.ax.map { Double(abs(v.rect.minX - $0.minX)) } } }))
        say("verify x vs blink x (pt): " + stats(rows.compactMap { r in r.verify.flatMap { v in r.blink.map { Double(abs(v.rect.minX - $0.rect.minX)) } } }))
        say("advance x error vs AX (pt): " + stats(rows.compactMap { r in r.advance.flatMap { a in r.ax.map { Double(abs(a - $0.minX)) } } }))
        say("advance x error vs blink (pt): " + stats(rows.compactMap { r in r.advance.flatMap { a in r.blink.map { Double(abs(a - $0.rect.minX)) } } }))
        say("advance in the fallback font, error vs blink (pt): raw " +
            stats(rows.compactMap { r in r.generic.flatMap { a in r.blink.map { Double(abs(a - $0.rect.minX)) } } }) + "; learned width scale " +
            stats(rows.compactMap { r in r.learned.flatMap { a in r.blink.map { Double(abs(a - $0.rect.minX)) } } }) +
            String(format: " (final scale %.3f)", widthScale))
        say("raw prev-char edge minus pixel (pt): dx " +
            stats(rows.compactMap { r in r.raw.flatMap { raw in r.blink.map { Double(raw.maxX - $0.rect.minX) } } }) + "; dy " +
            stats(rows.compactMap { r in r.raw.flatMap { raw in r.blink.map { Double(raw.midY - $0.rect.midY) } } }))
        say("blink latency (ms): " + stats(found.map { $0.blink!.ms }) + "; frames " + stats(found.map { Double($0.blink!.frames) }))
        say("verify latency (ms): " + stats(rows.compactMap { $0.verify?.ms }) + "; captures " +
            stats(rows.compactMap { $0.verify.map { Double($0.frames) } }))
        say("capture of the search region (ms): " + stats(captureMs))
        return !rows.isEmpty && found.count * 10 >= rows.count * 8
    }
}
