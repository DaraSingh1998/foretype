import AppKit
import ApplicationServices

/// Caret rectangle in AX coordinates (top-left origin) plus how it was found.
struct CaretInfo {
    var rect: CGRect
    var strategy: String
}

/// Finds a trustworthy caret rectangle. `AXBoundsForRange` with a zero-length range is
/// wrong in many apps: Phase 0 measured it one line too high in every TextKit field
/// (TextEdit, Safari's address bar), so both the zero-length rect and the previous
/// character's trailing edge are read and checked against each other.
/// Used on the AX thread only.
enum CaretResolver {
    /// Vertical correction learned per app when the two strategies disagreed by a line.
    private static var zeroLengthOffset: [String: CGFloat] = [:]

    /// Apps whose character rects the pixel caret locator found on screen although they lie
    /// outside the element's frame (LibreOffice reports paragraph frames about 100 pt off).
    /// Their rects skip the frame check. Written from the caret queue, read on the AX thread.
    private static let trustLock = NSLock()
    private static var outsideFrameMatches: [String: Int] = [:]

    static func trustsOutsideFrame(_ bundleId: String) -> Bool {
        trustLock.lock(); defer { trustLock.unlock() }
        return (outsideFrameMatches[bundleId] ?? 0) >= 2
    }

    /// The pixel caret agreed (`true`) or disagreed with a character rect that only the frame
    /// check rejected. Two agreements in a row make the app's rects trusted.
    @discardableResult
    static func notePixelCheck(_ bundleId: String, agreed: Bool) -> Bool {
        trustLock.lock(); defer { trustLock.unlock() }
        let wasTrusted = (outsideFrameMatches[bundleId] ?? 0) >= 2
        outsideFrameMatches[bundleId] = agreed ? (outsideFrameMatches[bundleId] ?? 0) + 1 : 0
        return !wasTrusted && (outsideFrameMatches[bundleId] ?? 0) >= 2
    }

    /// The previous character's trailing edge when it passes every check except lying inside
    /// `frame`; nil otherwise. For the pixel locator to confirm.
    static func edgeOutsideFrame(_ el: AXUIElement, caret: Int, frame: CGRect?) -> CGRect? {
        guard caret > 0, frame != nil,
              let prevText = AX.string(el, range: caret - 1, 1),
              !["\n", "\r", "\u{2028}", "\u{2029}"].contains(prevText),
              let p = AX.bounds(el, caret - 1, 1),
              !plausible(p, frame: frame, singleChar: true), plausible(p, frame: nil, singleChar: true) else { return nil }
        return CGRect(x: p.maxX, y: p.minY, width: 0, height: p.height)
    }

    static func plausible(_ r: CGRect?, frame: CGRect?, singleChar: Bool) -> Bool {
        guard let r else { return false }
        if r.origin == .zero || r.height <= 0 || r.height > 200 { return false }
        if let f = frame, f.width > 0 {
            if abs(r.minX - f.minX) < 1, abs(r.minY - f.minY) < 1,
               abs(r.width - f.width) < 1, abs(r.height - f.height) < 1 {
                return false
            }
            if !f.insetBy(dx: -4, dy: -4).contains(CGPoint(x: r.minX, y: r.midY)) { return false }
        }
        if singleChar, r.width > max(4 * r.height, 60) { return false }
        let screens = displayBounds()
        if !screens.isEmpty,
           !screens.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.minX, y: r.midY)) }) {
            return false
        }
        return true
    }

    static func resolve(_ el: AXUIElement, caret: Int, frame fieldFrame: CGRect?, bundleId: String) -> CaretInfo? {
        let frame = trustsOutsideFrame(bundleId) ? nil : fieldFrame
        let zero = AX.bounds(el, caret, 0)
        let zeroOK = plausible(zero, frame: frame, singleChar: false)

        var edge: CGRect?
        var prevIsNewline = false
        if caret > 0 {
            let prevText = AX.string(el, range: caret - 1, 1)
            prevIsNewline = prevText.map { ["\n", "\r", "\u{2028}", "\u{2029}"].contains($0) } ?? false
            let prev = AX.bounds(el, caret - 1, 1)
            if !prevIsNewline, plausible(prev, frame: frame, singleChar: true), let p = prev {
                edge = CGRect(x: p.maxX, y: p.minY, width: 0, height: p.height)
            }
        }

        if let edge, zeroOK, let zero {
            let dy = edge.minY - zero.minY
            if dy > edge.height * 0.5 {
                // Zero-length rect sits a line above the text: the TextKit bug. Learn it.
                zeroLengthOffset[bundleId] = dy
                return CaretInfo(rect: edge, strategy: "prevEdge(zeroHigh)")
            }
            if dy < -edge.height * 0.5 {
                // Caret wrapped to a new visual line; the previous character is on the line above.
                return CaretInfo(rect: CGRect(x: zero.minX, y: zero.minY, width: 0, height: zero.height),
                                 strategy: "zero(wrapped)")
            }
            return CaretInfo(rect: edge, strategy: "prevEdge")
        }
        if let edge {
            return CaretInfo(rect: edge, strategy: "prevEdge")
        }
        if zeroOK, var z = zero {
            if let dy = zeroLengthOffset[bundleId] {
                z.origin.y += dy
                return CaretInfo(rect: z, strategy: prevIsNewline ? "zero+offset(newline)" : "zero+offset")
            }
            return CaretInfo(rect: z, strategy: "zero")
        }
        return nil
    }

    private static let axFont = NSAttributedString.Key("AXFont")
    private static let runBreaks = CharacterSet.newlines.union(CharacterSet(charactersIn: "\t"))

    /// Characters just before the caret and their rectangle on screen.
    struct MeasuredRun {
        var text: String
        var rect: CGRect
    }

    /// The host field's font as drawn, from `AXAttributedStringForRange`: the font of the
    /// character before the caret (of the first one, at the start), scaled when the document
    /// is zoomed.
    static func font(_ el: AXUIElement, caret: Int, length: Int) -> NSFont? {
        guard let (before, start) = attributedBefore(el, caret: caret, length: length),
              let dict = before.attribute(axFont, at: before.length - 1, effectiveRange: nil) as? [String: Any]
        else { return nil }
        let run = caret > 0 ? measurableRun(before, start: start) { AX.bounds(el, $0, $1) } : nil
        return zoomed(reportedFont(dict, run: run), run: run)
    }

    /// Up to 24 characters before the caret with their attributes, and where they start (the
    /// first character when the caret is at the start). Just the one before the caret when the
    /// app can't give the longer range.
    private static func attributedBefore(_ el: AXUIElement, caret: Int, length: Int) -> (NSAttributedString, Int)? {
        func read(_ location: Int, _ count: Int) -> NSAttributedString? {
            guard let raw = AX.copyParam(el, "AXAttributedStringForRange", AX.makeRange(location, count)),
                  CFGetTypeID(raw) == CFAttributedStringGetTypeID() else { return nil }
            let s = raw as! NSAttributedString
            return s.length > 0 ? s : nil
        }
        guard caret > 0 else { return length > 0 ? read(0, 1).map { ($0, 0) } : nil }
        let k = min(caret, 24)
        if let s = read(caret - k, k), s.length == k { return (s, caret - k) }
        return read(caret - 1, 1).map { ($0, caret - 1) }
    }

    /// The characters before the caret whose width on screen says how the font is drawn: those
    /// after the last newline or tab (a tab's width depends on where it starts), in the font of
    /// the one before the caret (text typed at 12 pt after 20 pt text is measured alone), and
    /// on the caret's visual line (a range across a soft wrap is as wide as the line: TextEdit
    /// gave 773 pt for 24 characters, which read as a 3.9× zoom). `before` holds the
    /// characters from `start` to the caret; `bounds` reads a range's rectangle (AX
    /// coordinates). Nil when there are none.
    static func measurableRun(_ before: NSAttributedString, start: Int, bounds: (Int, Int) -> CGRect?) -> MeasuredRun? {
        let s = before.string as NSString
        let n = s.length
        let lastBreak = s.rangeOfCharacter(from: runBreaks, options: .backwards)
        var from = lastBreak.location == NSNotFound ? 0 : lastBreak.location + lastBreak.length
        guard from < n else { return nil }
        var sameFont = NSRange()
        _ = before.attribute(axFont, at: n - 1, longestEffectiveRange: &sameFont, in: NSRange(location: from, length: n - from))
        from = max(from, sameFont.location)
        guard let last = bounds(start + n - 1, 1), last.height > 0,
              var rect = bounds(start + from, n - from), rect.width > 0 else { return nil }
        if rect.height >= last.height * 1.5 {
            // Across a soft wrap: keep the characters on the caret's line.
            func onCaretLine(_ i: Int) -> Bool {
                bounds(start + i, 1).map { abs($0.midY - last.midY) < last.height / 2 } ?? false
            }
            var lo = from, hi = n - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if onCaretLine(mid) { hi = mid } else { lo = mid + 1 }
            }
            from = lo
            guard let r = bounds(start + from, n - from), r.width > 0, r.height < last.height * 1.5 else { return nil }
            rect = r
        }
        return MeasuredRun(text: s.substring(from: from), rect: rect)
    }

    /// LibreOffice reports the document's font size, not the zoomed one on screen (12 pt for
    /// text drawn with a 29 pt line). When the run before the caret (6 characters or more) is
    /// more than 25% wider or narrower on screen than in the font, scale it to match, unless
    /// the result would not fit the run's line.
    static func zoomed(_ font: NSFont, run: MeasuredRun?) -> NSFont {
        guard let run, run.text.utf16.count >= 6 else { return font }
        let w = FontMatcher.width(run.text, font)
        guard w > 0 else { return font }
        let zoom = run.rect.width / w
        guard zoom > 1.25 || zoom < 0.8, zoom > 0.3, zoom < 4,
              font.pointSize * zoom <= run.rect.height * 1.25 else { return font }
        return NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * zoom).rounded()) ?? font
    }

    /// The font an `AXFont` dictionary names. Chrome reports only a size: the family whose
    /// rendering of the run before the caret matches its width on screen, else the system font.
    static func reportedFont(_ dict: [String: Any], run: MeasuredRun?) -> NSFont {
        let size = (dict["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 13
        if let name = dict["AXFontName"] as? String, !name.hasPrefix("."), let f = NSFont(name: name, size: size) {
            // Word reports a fake name that disagrees with the family; trust the family then.
            if let family = dict["AXFontFamily"] as? String, f.familyName != family,
               let byFamily = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
                return byFamily
            }
            return f
        }
        if let family = dict["AXFontFamily"] as? String, !family.hasPrefix("."),
           let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return f
        }
        if let run, run.text.utf16.count >= 4 {
            return FontMatcher.best(text: run.text, width: run.rect.width, size: size)
        }
        return NSFont.systemFont(ofSize: size)
    }
}

/// Guesses a font from a measured text width (Tabber's approach for Chromium, which
/// reports a font size but no name).
enum FontMatcher {
    static let families = [
        "Helvetica Neue", "Helvetica", "Arial", "Times New Roman", "Times", "Georgia", "Verdana",
        "Tahoma", "Trebuchet MS", "Menlo", "Courier New", "Courier", "Palatino",
    ]

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    static func best(text: String, width measured: CGFloat, size: CGFloat) -> NSFont {
        var candidates = [NSFont.systemFont(ofSize: size)]
        candidates += families.compactMap { NSFont(name: $0, size: size) ?? NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
        return candidates.min { abs(width(text, $0) - measured) < abs(width(text, $1) - measured) }!
    }

    /// `Foretype --font-selftest`: each family must be recovered from its own width.
    static func selfTest() -> Bool {
        let sample = "Thanks for sending the notes"
        var ok = true
        for family in ["Georgia", "Menlo", "Times New Roman", "Verdana", "Helvetica Neue"] {
            guard let font = NSFont(name: family, size: 17) else { continue }
            let picked = best(text: sample, width: width(sample, font), size: 17)
            let pass = picked.familyName == font.familyName
            ok = ok && pass
            print("\(family): picked \(picked.familyName ?? "?") \(pass ? "ok" : "WRONG")")
        }
        let sys = NSFont.systemFont(ofSize: 15)
        let picked = best(text: sample, width: width(sample, sys), size: 15)
        print("system: picked \(picked.familyName ?? "?") \(picked.familyName == sys.familyName ? "ok" : "WRONG")")
        ok = CaretResolver.runSelfTest() && ok
        print(ok ? "font self-test passed" : "font self-test FAILED")
        return ok
    }
}

extension CaretResolver {
    /// Part of `--font-selftest`: the ghost's font from the text before the caret of a fake
    /// field, laid out as TextEdit and LibreOffice report it.
    static func runSelfTest() -> Bool {
        /// `parts` (text, font name, size) laid out from x `x0` on lines `lineHeight` tall, each
        /// character advancing as in its font times `zoom` (a tab 36 pt); the line wraps before
        /// character `wrap` and after a newline, and starts again at x 100.
        func check(_ label: String, _ parts: [(String, String, CGFloat)], zoom: CGFloat = 1, wrap: Int? = nil,
                   x0: CGFloat = 100, lineHeight: CGFloat, expect: (String, CGFloat)) -> Bool {
            let s = NSMutableAttributedString()
            var rects: [CGRect] = []
            var x = x0, y: CGFloat = 300
            for (text, name, size) in parts {
                guard let font = NSFont(name: name, size: size) else { print("\(label): no \(name)"); return false }
                var prefix = ""
                for ch in text {
                    if rects.count == wrap { x = 100; y += lineHeight }
                    let advance = FontMatcher.width(prefix + String(ch), font) - FontMatcher.width(prefix, font)
                    prefix = ch == "\n" || ch == "\t" ? "" : prefix + String(ch)
                    let w = ch == "\n" ? 0 : ch == "\t" ? 36 * zoom : advance * zoom
                    rects.append(CGRect(x: x, y: y, width: w, height: lineHeight))
                    x += w
                    if ch == "\n" { x = 100; y += lineHeight }
                }
                let dict: [String: Any] = ["AXFontName": name, "AXFontSize": size, "AXFontFamily": font.familyName ?? name]
                s.append(NSAttributedString(string: text, attributes: [axFont: dict]))
            }
            let start = 500
            let run = measurableRun(s, start: start) { location, length in
                let i = location - start
                guard i >= 0, length > 0, i + length <= rects.count else { return nil }
                return rects[i..<(i + length)].reduce(rects[i]) { $0.union($1) }
            }
            let dict = s.attribute(axFont, at: s.length - 1, effectiveRange: nil) as? [String: Any] ?? [:]
            let font = zoomed(reportedFont(dict, run: run), run: run)
            let pass = font.fontName == expect.0 && font.pointSize == expect.1
            print("\(label): \(font.fontName) \(font.pointSize), run \(run.map { "\"\($0.text)\"" } ?? "none") \(pass ? "ok" : "WRONG")")
            return pass
        }
        var ok = true
        // TextEdit, short window: the 24 characters before the caret wrap after "really " (the
        // whole range is 773 pt wide on screen, which read as a 3.9× zoom).
        ok = check("wrapped", [("nd it reads really well.", "Helvetica-Light", 20)], wrap: 19, x0: 700,
                   lineHeight: 24, expect: ("Helvetica-Light", 20)) && ok
        // Plain text whose text a script set to 20 pt; typing goes on at 12 pt.
        ok = check("typed smaller", [("reads really well.", "Menlo-Regular", 20), (" I'll go", "Menlo-Regular", 12)],
                   lineHeight: 24, expect: ("Menlo-Regular", 12)) && ok
        ok = check("first typed", [("it reads really well.", "Menlo-Regular", 20), (" I", "Menlo-Regular", 12)],
                   lineHeight: 24, expect: ("Menlo-Regular", 12)) && ok
        ok = check("typed larger", [("Hi Sam, thanks", "Menlo-Regular", 12), (" for the", "Menlo-Regular", 20)],
                   lineHeight: 24, expect: ("Menlo-Regular", 20)) && ok
        // LibreOffice: reports 12 pt for text drawn twice as wide.
        ok = check("zoomed", [("Thanks for the notes", "Helvetica", 12)], zoom: 2, lineHeight: 29,
                   expect: ("Helvetica", 24)) && ok
        ok = check("zoomed, wrapped", [("the notes from today.", "Helvetica", 12)], zoom: 2, wrap: 15, x0: 600,
                   lineHeight: 29, expect: ("Helvetica", 24)) && ok
        ok = check("zoomed, after a tab", [("Dear Sam,\n\tThanks again", "Helvetica", 13)], zoom: 2, lineHeight: 31,
                   expect: ("Helvetica", 26)) && ok
        ok = check("zoomed, line start", [("Dear Sam,\nThe", "Helvetica", 12)], zoom: 2, lineHeight: 29,
                   expect: ("Helvetica", 12)) && ok
        return ok
    }
}
