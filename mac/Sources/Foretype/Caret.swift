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

    /// The host field's font as drawn: the reported font, scaled when the document is zoomed.
    static func font(_ el: AXUIElement, caret: Int, length: Int) -> NSFont? {
        reportedFont(el, caret: caret, length: length).map { zoomed($0, el, caret: caret) }
    }

    /// LibreOffice reports the document's font size, not the zoomed one on screen (12 pt for
    /// text drawn with a 29 pt line). When the last few characters are more than 25% wider or
    /// narrower on screen than in the font, scale it to match.
    static func zoomed(_ font: NSFont, _ el: AXUIElement, caret: Int) -> NSFont {
        let k = min(caret, 24)
        guard k >= 6, let text = AX.string(el, range: caret - k, k), !text.contains(where: \.isNewline),
              let r = AX.bounds(el, caret - k, k), r.width > 0 else { return font }
        let w = FontMatcher.width(text, font)
        guard w > 0 else { return font }
        let zoom = r.width / w
        guard zoom > 1.25 || zoom < 0.8, zoom > 0.3, zoom < 4,
              r.height < font.pointSize * zoom * 2.2 else { return font }  // one line only
        return NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * zoom).rounded()) ?? font
    }

    /// The host field's font, from `AXAttributedStringForRange` around the caret. Chrome
    /// reports only a size; that falls back to the system font at that size.
    private static func reportedFont(_ el: AXUIElement, caret: Int, length: Int) -> NSFont? {
        let loc = caret > 0 ? caret - 1 : (length > 0 ? 0 : -1)
        guard loc >= 0,
              let raw = AX.copyParam(el, "AXAttributedStringForRange", AX.makeRange(loc, 1)),
              CFGetTypeID(raw) == CFAttributedStringGetTypeID() else { return nil }
        let attributed = raw as! NSAttributedString
        guard attributed.length > 0,
              let dict = attributed.attributes(at: 0, effectiveRange: nil)[NSAttributedString.Key("AXFont")] as? [String: Any]
        else { return nil }
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
        // Size only (Chrome): pick the font family whose rendering of the last few
        // characters matches their on-screen width.
        let k = min(caret, 24)
        if k >= 4, let text = AX.string(el, range: caret - k, k), !text.contains(where: \.isNewline),
           let r = AX.bounds(el, caret - k, k), r.width > 0, r.height < size * 2.2 {
            return FontMatcher.best(text: text, width: r.width, size: size)
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
        print(ok ? "font self-test passed" : "font self-test FAILED")
        return ok
    }
}
