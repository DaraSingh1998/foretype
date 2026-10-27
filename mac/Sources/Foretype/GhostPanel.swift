import AppKit

/// A panel that can never take focus from the app the user is typing in.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class GhostView: NSView {
    var text = NSAttributedString()
    /// Inline ghost text: each line and where it starts in the view.
    var lines: [(text: NSAttributedString, at: NSPoint)] = []
    var card = false
    let padding = NSSize(width: 6, height: 3)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if card {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            text.draw(at: NSPoint(x: padding.width, y: padding.height))
        } else {
            for line in lines { line.text.draw(at: line.at) }
        }
    }
}

/// Draws the suggestion as gray "ghost" text right after the caret, matching the host
/// field's font. In a multi-line field with nothing below the caret's line, words that don't
/// fit before the field's edge wrap onto the next lines, from where its text starts (`Wrap`).
/// When the caret position is unknown it falls back to a small "mirror"
/// card above the field, as Cotypist does for Firefox. Mid-line suggestions (text follows
/// the caret, so inline ghost text would overlap it) use a card just below the caret. Word
/// alternatives (D50) get a numbered card of their own under the suggestion (`showPicker`).
final class GhostPanel {
    private let panel: NSPanel
    private let view = GhostView()
    private let pickerPanel: NSPanel
    private let pickerView = GhostView()
    /// What the inline text was laid out with, so an accept can move it (`advance`).
    private var anchor: (caret: CGRect, font: NSFont, limit: CGFloat, left: CGFloat?, bottom: CGFloat)?
    /// Where each multi-line field's text starts (left edge, global x), measured on a line
    /// that fits on one row; used for lines that are already wrapped.
    private var leftEdges: [UInt64: CGFloat] = [:]

    /// A multi-line field the ghost text may wrap in: nothing follows the caret's line, the
    /// caret is inside `field`, and `lineText` is the text from the line's start to the caret.
    struct Wrap {
        var fieldKey: UInt64
        var lineText: String
        var field: CGRect
        /// The lowest y a wrapped line may reach (the field's or the window's bottom).
        var bottom: CGFloat
    }
    /// Where the suggestion is drawn (global coordinates), the caret it follows (none for the
    /// mirror card) and its font: the alternatives card goes next to it.
    private var drawn: (rect: CGRect, caret: CGRect?, font: NSFont)?
    /// What the panel last drew: `inline`, `card` (under the caret), `mirror` (above the
    /// field), `hint` or `hidden`. For the debug log.
    private(set) var mode = "hidden"
    /// Rows the inline text takes (more than 1 when it wraps). For the debug log.
    private(set) var rows = 0

    init() {
        panel = GhostPanel.makePanel(view)
        pickerPanel = GhostPanel.makePanel(pickerView)
        pickerView.card = true
    }

    private static func makePanel(_ view: NSView) -> NSPanel {
        let panel = NonActivatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.setAccessibilityElement(false)
        panel.contentView = view
        return panel
    }

    var isVisible: Bool { panel.isVisible }
    var isPickerVisible: Bool { pickerPanel.isVisible }

    /// Where the panel is on screen, in global coordinates (as AppKit placed it), for the
    /// debug log; nil while hidden.
    var globalFrame: CGRect? {
        panel.isVisible ? ScreenGeometry.globalRect(fromCocoa: panel.frame, primaryHeight: ScreenGeometry.primaryHeight()) : nil
    }

    private static func cocoaRect(fromAX r: CGRect) -> CGRect {
        ScreenGeometry.cocoaRect(fromGlobal: r, primaryHeight: ScreenGeometry.primaryHeight())
    }

    private static func attributed(_ text: String, font: NSFont, card: Bool, tag: String? = nil) -> NSAttributedString {
        let color = card ? NSColor.secondaryLabelColor : NSColor(white: 0.5, alpha: 0.85)
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        if let tag, !tag.isEmpty {
            // What a fill is ("your email"): smaller and fainter than the text Tab inserts.
            let small = NSFont.systemFont(ofSize: max(9, font.pointSize * 0.72))
            s.append(NSAttributedString(string: "  \(tag)", attributes: [.font: small, .foregroundColor: color.withAlphaComponent(0.55),
                                                                         .baselineOffset: (font.pointSize - small.pointSize) * 0.15]))
        }
        return s
    }

    /// The leading spaces and first word of `text`.
    private static func firstWord(_ text: String) -> String {
        let start = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
        let end = text[start...].firstIndex { $0.isWhitespace } ?? text.endIndex
        return String(text[..<end])
    }

    /// Words of `text` that fit in `width` points.
    private static func fitting(_ text: String, font: NSFont, width: CGFloat) -> String {
        var fit = ""
        var i = text.startIndex
        while i < text.endIndex {
            var j = i
            while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let candidate = fit + text[i..<j]
            if attributed(candidate, font: font, card: false).size().width > width { break }
            fit = candidate
            i = j
        }
        return fit
    }

    /// Most rows the ghost text takes in a multi-line field, the caret's included.
    static let maxRows = 3

    /// `text` laid out from the caret at `x`: the words that fit before `limit` on the caret's
    /// row, then, given the field's `left` edge, rows starting there, up to `rows` in all.
    /// Each line is its text (wrapped lines without their leading spaces), where it starts and
    /// its row. A new word that doesn't fit on the caret's row starts on the next one; the rest
    /// of a word being typed never moves down (the app would move the whole word).
    static func layout(_ text: String, font: NSFont, x: CGFloat, limit: CGFloat, left: CGFloat?, rows: Int) -> [(text: String, x: CGFloat, row: Int)] {
        var lines: [(text: String, x: CGFloat, row: Int)] = []
        var rest = Substring(text)
        var row = 0, start = x
        while !rest.isEmpty, row < max(1, rows) {
            let fit = fitting(String(rest), font: font, width: max(0, limit - start))
            if !fit.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append((fit, start, row))
                rest = rest.dropFirst(fit.count)
            } else if row > 0 || !(rest.first?.isWhitespace ?? false) {
                break  // a word wider than the field, or the rest of the word at the caret
            }
            guard let left, !rest.isEmpty else { break }
            rest = rest.drop { $0.isWhitespace }
            row += 1
            start = left
        }
        return lines
    }

    /// The field's left text edge for `wrap`: measured from the caret's line when that line
    /// fits on one row (and remembered for the field), else the remembered one.
    private func leftEdge(_ wrap: Wrap, caret: CGRect, font: NSFont) -> CGFloat? {
        let measured = caret.minX - GhostPanel.attributed(wrap.lineText, font: font, card: false).size().width
        if measured >= wrap.field.minX - 2, measured <= wrap.field.minX + wrap.field.width / 4 {
            if leftEdges.count > 64 { leftEdges.removeAll() }
            leftEdges[wrap.fieldKey] = measured
            return measured
        }
        return leftEdges[wrap.fieldKey]
    }

    /// `tag` labels a fill of one of the user's details; it is drawn only when the whole text
    /// fits on the caret's row. `wrap` lets the text go on below the caret's line.
    func show(text: String, caret: CaretInfo?, frame: CGRect?, font: NSFont?, midLine: Bool = false, tag: String? = nil, wrap: Wrap? = nil) {
        let caretRect = caret?.rect
        let baseFont = font ?? NSFont.systemFont(ofSize: max(11, (caretRect?.height ?? 16) * 0.78))
        if midLine, let caretRect {
            return showCard(text, font: baseFont, below: caretRect)
        }
        if let caretRect {
            let x = caretRect.minX + caretRect.width
            let limit = (frame.map { $0.maxX } ?? (displayBounds().first { $0.contains(caretRect.origin) }?.maxX ?? x + 600)) - 4
            let left = wrap.flatMap { leftEdge($0, caret: caretRect, font: baseFont) }
            let screenBottom = displayBounds().first { $0.contains(caretRect.origin) }?.maxY ?? .greatestFiniteMagnitude
            let bottom = min(wrap?.bottom ?? caretRect.maxY, screenBottom)
            if showInline(text, caret: caretRect, font: baseFont, limit: limit, left: left, bottom: bottom, tag: tag) { return }
        }
        // Mirror card: above the field (or below the caret line when the field is unknown).
        guard let anchorRect = frame ?? caretRect else { return hide() }
        let cardFont = NSFont.systemFont(ofSize: min(max(baseFont.pointSize, 12), 15))
        let attr = GhostPanel.attributed("\u{21E5} " + text.trimmingCharacters(in: .whitespaces), font: cardFont, card: true, tag: tag)
        let size = attr.size()
        let w = ceil(size.width) + view.padding.width * 2
        let h = ceil(size.height) + view.padding.height * 2
        // Above the field unless that leaves its display (which may be above the primary,
        // where every y is negative).
        let display = ScreenGeometry.display(for: anchorRect, in: displayBounds())
        let axRect = CGRect(x: anchorRect.minX, y: ScreenGeometry.cardY(nextTo: anchorRect, height: h, gap: 4, display: display),
                            width: w, height: h)
        view.card = true
        view.text = attr
        anchor = nil
        drawn = (axRect, nil, cardFont)
        mode = "mirror"
        place(GhostPanel.cocoaRect(fromAX: axRect))
    }

    /// The inline ghost text from `caret`; false when nothing fits there.
    private func showInline(_ text: String, caret caretRect: CGRect, font: NSFont, limit: CGFloat, left: CGFloat?,
                            bottom: CGFloat, tag: String?) -> Bool {
        let x = caretRect.minX + caretRect.width
        let lineHeight = max(caretRect.height, NSLayoutManager().defaultLineHeight(for: font))
        let rowLimit = left == nil ? 1 : min(GhostPanel.maxRows, 1 + max(0, Int(((bottom - caretRect.maxY) / lineHeight).rounded(.down))))
        var lines = GhostPanel.layout(text, font: font, x: x, limit: limit, left: left, rows: rowLimit)
        if lines.isEmpty {
            // No whole word fits before the field's edge (the line is about to wrap): the
            // first word may run past it, which beats a card away from the caret.
            let screenRight = (displayBounds().first { $0.contains(caretRect.origin) }?.maxX ?? x + 600) - 4
            let first = GhostPanel.fitting(GhostPanel.firstWord(text), font: font, width: max(0, screenRight - x))
            if !first.trimmingCharacters(in: .whitespaces).isEmpty { lines = [(first, x, 0)] }
        }
        guard !lines.isEmpty else { return false }
        var attrs = lines.map { GhostPanel.attributed($0.text, font: font, card: false) }
        if lines.count == 1, lines[0].text == text, tag != nil {
            let tagged = GhostPanel.attributed(text, font: font, card: false, tag: tag)
            if tagged.size().width <= limit - x { attrs[0] = tagged }
        }
        let height = ceil(attrs[0].size().height)
        let top = caretRect.midY - height / 2
        let rects = zip(lines, attrs).map { line, attr in
            CGRect(x: line.x, y: top + CGFloat(line.row) * lineHeight, width: ceil(attr.size().width) + 2, height: height)
        }
        let axRect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        view.card = false
        view.lines = zip(attrs, rects).map { ($0, NSPoint(x: $1.minX - axRect.minX, y: $1.minY - axRect.minY)) }
        anchor = (caretRect, font, limit, left, bottom)
        drawn = (axRect, caretRect, font)
        mode = "inline"
        rows = (lines.last?.row ?? 0) + 1
        place(GhostPanel.cocoaRect(fromAX: axRect))
        return true
    }

    /// Shows a tip card above `rect` (a field or window) for 8 seconds. It doesn't count as
    /// a suggestion: the key tap stays off, and any suggestion replaces it.
    func showHint(_ text: String, near rect: CGRect) {
        let font = NSFont.systemFont(ofSize: 13)
        let attr = GhostPanel.attributed("\u{24D8} " + text, font: font, card: true)
        let size = attr.size()
        let w = ceil(size.width) + view.padding.width * 2
        let h = ceil(size.height) + view.padding.height * 2
        var axRect = CGRect(x: rect.minX, y: rect.minY - h - 4, width: w, height: h)
        if let display = ScreenGeometry.display(for: rect, in: displayBounds()), axRect.minY < display.minY {
            axRect.origin.y = rect.minY + 8
        }
        view.card = true
        view.text = attr
        anchor = nil
        drawn = nil
        hidePicker()
        mode = "hint"
        place(GhostPanel.cocoaRect(fromAX: axRect))
        hintGeneration += 1
        let gen = hintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if let self, self.hintGeneration == gen { self.hide() }
        }
    }

    /// Bumped by every show, so an expiring hint never hides a newer suggestion.
    private var hintGeneration = 0

    /// A card under the caret line, starting at the caret (above it near the screen bottom).
    private func showCard(_ text: String, font: NSFont, below caretRect: CGRect) {
        let cardFont = NSFont.systemFont(ofSize: min(max(font.pointSize, 12), 15))
        let attr = GhostPanel.attributed("\u{21E5} " + text.trimmingCharacters(in: .whitespaces), font: cardFont, card: true)
        let size = attr.size()
        let w = ceil(size.width) + view.padding.width * 2
        let h = ceil(size.height) + view.padding.height * 2
        var axRect = CGRect(x: caretRect.minX, y: caretRect.maxY + 3, width: w, height: h)
        let screenBottom = displayBounds().first { $0.contains(caretRect.origin) }?.maxY ?? .greatestFiniteMagnitude
        if axRect.maxY > screenBottom { axRect.origin.y = caretRect.minY - h - 3 }
        view.card = true
        view.text = attr
        anchor = nil
        drawn = (axRect, caretRect, cardFont)
        mode = "card"
        place(GhostPanel.cocoaRect(fromAX: axRect))
    }

    /// After an accept: shift the ghost right by the inserted text and show what is left,
    /// so it stays put until the host app reports the new caret.
    func advance(inserted: String, remaining: String) {
        guard let anchor, panel.isVisible, !view.card, !remaining.trimmingCharacters(in: .whitespaces).isEmpty else {
            return hide()
        }
        // Where the inserted words ended in the layout (it fills rows greedily, so laying out
        // a prefix gives the same rows): the caret is there now, on a lower row if they wrapped.
        let x = anchor.caret.minX + anchor.caret.width
        let lineHeight = max(anchor.caret.height, NSLayoutManager().defaultLineHeight(for: anchor.font))
        let placed = GhostPanel.layout(inserted, font: anchor.font, x: x, limit: anchor.limit, left: anchor.left,
                                       rows: anchor.left == nil ? 1 : GhostPanel.maxRows).last
        var caret = anchor.caret
        if let placed, placed.row > 0 {
            caret.origin.x = placed.x + GhostPanel.attributed(placed.text, font: anchor.font, card: false).size().width - caret.width
            caret.origin.y += CGFloat(placed.row) * lineHeight
        } else {
            caret.origin.x += GhostPanel.attributed(inserted, font: anchor.font, card: false).size().width
        }
        if !showInline(remaining, caret: caret, font: anchor.font, limit: anchor.limit, left: anchor.left, bottom: anchor.bottom, tag: nil) {
            hide()
        }
    }

    private func place(_ rect: CGRect) {
        hintGeneration += 1
        panel.setFrame(rect, display: false)
        view.frame = NSRect(origin: .zero, size: rect.size)
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        anchor = nil
        drawn = nil
        mode = "hidden"
        hidePicker()
        if panel.isVisible { panel.orderOut(nil) }
    }

    // MARK: Word alternatives (D50)

    /// The alternatives card: a row per alternative (`items`, as they read with the word being
    /// typed: `PickerState.display`) numbered with the key that takes it, the word that key
    /// inserts first set apart; with no items, a line saying there are none. It sits under the
    /// suggestion (under the caret line, or the mid-line card), above it when that would leave
    /// the screen, and above a mirror card, which already sits over the field. Shown only
    /// while a suggestion is.
    func showPicker(_ items: [String]) {
        guard let drawn, panel.isVisible else { return hidePicker() }
        let font = NSFont.systemFont(ofSize: min(max(drawn.font.pointSize, 12), 15))
        let attr = GhostPanel.pickerText(items, font: font)
        let size = attr.size()
        let w = ceil(size.width) + pickerView.padding.width * 2
        let h = ceil(size.height) + pickerView.padding.height * 2
        let line = drawn.caret.map { $0.union(drawn.rect) } ?? drawn.rect
        let display = ScreenGeometry.display(for: line, in: displayBounds())
        let below = line.maxY + 3, above = line.minY - h - 3
        var y = mode == "mirror" ? above : below
        if let display {
            if y == below, below + h > display.maxY { y = above }
            if y == above, above < display.minY { y = below }
        }
        let axRect = CGRect(x: drawn.caret?.minX ?? drawn.rect.minX, y: y, width: w, height: h)
        pickerView.text = attr
        let rect = GhostPanel.cocoaRect(fromAX: axRect)
        pickerPanel.setFrame(rect, display: false)
        pickerView.frame = NSRect(origin: .zero, size: rect.size)
        pickerView.needsDisplay = true
        if !pickerPanel.isVisible { pickerPanel.orderFrontRegardless() }
    }

    func hidePicker() {
        if pickerPanel.isVisible { pickerPanel.orderOut(nil) }
    }

    /// Where the alternatives card is (global coordinates), for the debug log; nil while hidden.
    var pickerFrame: CGRect? {
        pickerPanel.isVisible ? ScreenGeometry.globalRect(fromCocoa: pickerPanel.frame, primaryHeight: ScreenGeometry.primaryHeight()) : nil
    }

    /// The alternatives card as a PNG, as `showPicker` draws it (`--alternatives-selftest DIR`).
    static func pickerPNG(_ items: [String], fontSize: CGFloat, dark: Bool) -> Data? {
        let view = GhostView()
        view.card = true
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        var data: Data?
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            let attr = pickerText(items, font: .systemFont(ofSize: fontSize))
            let size = attr.size()
            view.text = attr
            view.frame = NSRect(x: 0, y: 0, width: ceil(size.width) + view.padding.width * 2,
                                height: ceil(size.height) + view.padding.height * 2)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    /// The card's rows: "⌥1  word rest", the key faint, the word it takes first in full color.
    static func pickerText(_ items: [String], font: NSFont) -> NSAttributedString {
        let rows = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let faint = NSColor.tertiaryLabelColor, rest = NSColor.secondaryLabelColor
        let keyFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
        guard !items.isEmpty else {
            return NSAttributedString(string: L("No alternatives"), attributes: [.font: font, .foregroundColor: rest])
        }
        for (i, item) in items.enumerated() {
            if i > 0 { rows.append(NSAttributedString(string: "\n")) }
            rows.append(NSAttributedString(string: "\u{2325}\(i + 1)  ", attributes: [.font: keyFont, .foregroundColor: faint]))
            let first = PickerState.firstWord(item)
            rows.append(NSAttributedString(string: String(first), attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            rows.append(NSAttributedString(string: String(item[first.endIndex...]), attributes: [.font: font, .foregroundColor: rest]))
        }
        rows.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: rows.length))
        return rows
    }

    // MARK: Self-test (--ghost-selftest)

    /// The wrapping layout on made-up fields; with `dir`, PNGs of a field with the ghost text
    /// drawn as `showInline` draws it.
    static func selfTest(dir: String?) -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("FAIL: \(what)") }
        }
        let font = NSFont.systemFont(ofSize: 13)
        func width(_ s: String) -> CGFloat { attributed(s, font: font, card: false).size().width }
        let text = " the quarterly numbers before the meeting on Thursday"
        let x: CGFloat = 300, left: CGFloat = 100

        // Everything fits: one line at the caret.
        var l = layout(text, font: font, x: x, limit: x + width(text) + 1, left: left, rows: 3)
        check(l.count == 1 && l[0].text == text && l[0].x == x, "fits on the caret's row: \(l)")
        // Too long: the rest goes on the next rows, from the left edge, without its leading space.
        let limit = x + width(" the quarterly numbers") + 1
        l = layout(text, font: font, x: x, limit: limit, left: left, rows: 3)
        check(l.count >= 2 && l[0].text == " the quarterly numbers" && l[0].row == 0, "first row: \(l)")
        check(l.count >= 2 && l[1].x == left && l[1].row == 1 && l[1].text.first == "b", "second row from the left edge: \(l)")
        check(l.map(\.text).joined(separator: " ") == text, "no word lost or doubled: \(l)")
        check(l.allSatisfy { $0.x + width($0.text) <= limit }, "every row within the edge")
        // Rows are capped; without a left edge only the caret's row.
        check(layout(text, font: font, x: x, limit: x + width(" the") + 1, left: left, rows: 2).count == 2, "capped at 2 rows")
        l = layout(text, font: font, x: x, limit: limit, left: nil, rows: 3)
        check(l.count == 1 && l[0].text == " the quarterly numbers", "no wrap without a left edge: \(l)")
        // A new word that doesn't fit at the caret starts on the next row...
        l = layout(text, font: font, x: x, limit: x + 4, left: left, rows: 3)
        check(l.first?.row == 1 && l.first?.x == left && l.first?.text.hasPrefix("the") == true, "new word moves down: \(l)")
        // ...but the rest of a word being typed doesn't (the app moves the whole word).
        check(layout("ly numbers", font: font, x: x, limit: x + 4, left: left, rows: 3).isEmpty, "rest of a word stays")
        // A word wider than a whole row stops the layout.
        l = layout(" a " + String(repeating: "x", count: 80), font: font, x: x, limit: x + 60, left: left, rows: 3)
        check(l.count == 1 && l[0].text == " a", "too-wide word: \(l)")
        // A prefix lays out on the same rows (what `advance` relies on).
        let full = layout(text, font: font, x: x, limit: limit, left: left, rows: 3)
        let prefix = layout(" the quarterly numbers before", font: font, x: x, limit: limit, left: left, rows: 3)
        check(prefix.last?.row == 1 && full.count > 1 && full[1].text.hasPrefix(prefix.last!.text), "prefix layout: \(prefix) vs \(full)")

        if let dir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (name, dark) in [("light", false), ("dark", true)] {
                let typed = "Hi Sam, could you send me"
                let field = CGRect(x: 0, y: 0, width: 360, height: 90)
                let caretX = 8 + width(typed)
                let lines = layout(text, font: font, x: caretX, limit: field.maxX - 4, left: 8, rows: 3)
                let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
                let image = NSImage(size: field.size, flipped: true) { _ in
                    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
                    appearance.performAsCurrentDrawingAppearance {
                        NSColor.textBackgroundColor.setFill()
                        field.fill()
                        NSColor.separatorColor.setStroke()
                        NSBezierPath(rect: field.insetBy(dx: 0.5, dy: 0.5)).stroke()
                        NSAttributedString(string: typed, attributes: [.font: font, .foregroundColor: NSColor.textColor])
                            .draw(at: NSPoint(x: 8, y: 8))
                        for line in lines {
                            attributed(line.text, font: font, card: false)
                                .draw(at: NSPoint(x: line.x, y: 8 + CGFloat(line.row) * lineHeight))
                        }
                    }
                    return true
                }
                guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { check(false, "render \(name)"); continue }
                let path = (dir as NSString).appendingPathComponent("ghost-wrap-\(name).png")
                check(FileManager.default.createFile(atPath: path, contents: png), "write \(path)")
            }
        }
        print(failures == 0 ? "ghost self-test passed" : "ghost self-test: \(failures) failure(s)")
        return failures == 0
    }
}
