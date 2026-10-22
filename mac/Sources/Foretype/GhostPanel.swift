import AppKit

/// A panel that can never take focus from the app the user is typing in.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class GhostView: NSView {
    var text = NSAttributedString()
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
            text.draw(at: .zero)
        }
    }
}

/// Draws the suggestion as gray "ghost" text right after the caret, matching the host
/// field's font. When the caret position is unknown it falls back to a small "mirror"
/// card above the field, as Cotypist does for Firefox. Mid-line suggestions (text follows
/// the caret, so inline ghost text would overlap it) use a card just below the caret.
final class GhostPanel {
    private let panel: NSPanel
    private let view = GhostView()
    private var anchor: (caret: CGRect, font: NSFont)?
    /// What the panel last drew: `inline`, `card` (under the caret), `mirror` (above the
    /// field), `hint` or `hidden`. For the debug log.
    private(set) var mode = "hidden"

    init() {
        panel = NonActivatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
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
    }

    var isVisible: Bool { panel.isVisible }

    private static func cocoaRect(fromAX r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
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

    /// `tag` labels a fill of one of the user's details; it is drawn only when the whole text
    /// fits.
    func show(text: String, caret: CaretInfo?, frame: CGRect?, font: NSFont?, midLine: Bool = false, tag: String? = nil) {
        let caretRect = caret?.rect
        let baseFont = font ?? NSFont.systemFont(ofSize: max(11, (caretRect?.height ?? 16) * 0.78))
        if midLine, let caretRect {
            return showCard(text, font: baseFont, below: caretRect)
        }
        if let caretRect {
            let x = caretRect.minX + caretRect.width
            let limit = (frame.map { $0.maxX } ?? (displayBounds().first { $0.contains(caretRect.origin) }?.maxX ?? x + 600)) - 4
            var shown = GhostPanel.fitting(text, font: baseFont, width: max(0, limit - x))
            if shown.trimmingCharacters(in: .whitespaces).isEmpty {
                // No whole word fits before the field's edge (the line is about to wrap): the
                // first word may run past it, which beats a card away from the caret.
                let screenRight = (displayBounds().first { $0.contains(caretRect.origin) }?.maxX ?? x + 600) - 4
                shown = GhostPanel.fitting(GhostPanel.firstWord(text), font: baseFont, width: max(0, screenRight - x))
            }
            if !shown.trimmingCharacters(in: .whitespaces).isEmpty {
                var attr = GhostPanel.attributed(shown, font: baseFont, card: false)
                if shown == text, tag != nil {
                    let tagged = GhostPanel.attributed(shown, font: baseFont, card: false, tag: tag)
                    if tagged.size().width <= limit - x { attr = tagged }
                }
                let size = attr.size()
                let axRect = CGRect(x: x, y: caretRect.midY - size.height / 2, width: ceil(size.width) + 2, height: ceil(size.height))
                view.card = false
                view.text = attr
                anchor = (caretRect, baseFont)
                mode = "inline"
                place(GhostPanel.cocoaRect(fromAX: axRect))
                return
            }
        }
        // Mirror card: above the field (or below the caret line when the field is unknown).
        guard let anchorRect = frame ?? caretRect else { return hide() }
        let cardFont = NSFont.systemFont(ofSize: min(max(baseFont.pointSize, 12), 15))
        let attr = GhostPanel.attributed("\u{21E5} " + text.trimmingCharacters(in: .whitespaces), font: cardFont, card: true, tag: tag)
        let size = attr.size()
        let w = ceil(size.width) + view.padding.width * 2
        let h = ceil(size.height) + view.padding.height * 2
        var axRect = CGRect(x: anchorRect.minX, y: anchorRect.minY - h - 4, width: w, height: h)
        if axRect.minY < 0 { axRect.origin.y = anchorRect.maxY + 4 }
        view.card = true
        view.text = attr
        anchor = nil
        mode = "mirror"
        place(GhostPanel.cocoaRect(fromAX: axRect))
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
        if axRect.minY < 0 { axRect.origin.y = rect.minY + 8 }
        view.card = true
        view.text = attr
        anchor = nil
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
        mode = "card"
        place(GhostPanel.cocoaRect(fromAX: axRect))
    }

    /// After an accept: shift the ghost right by the inserted text and show what is left,
    /// so it stays put until the host app reports the new caret.
    func advance(inserted: String, remaining: String) {
        guard let anchor, panel.isVisible, !view.card, !remaining.trimmingCharacters(in: .whitespaces).isEmpty else {
            return hide()
        }
        let dx = GhostPanel.attributed(inserted, font: anchor.font, card: false).size().width
        var caret = anchor.caret
        caret.origin.x += dx
        show(text: remaining, caret: CaretInfo(rect: caret, strategy: "advanced"), frame: nil, font: anchor.font)
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
        mode = "hidden"
        if panel.isVisible { panel.orderOut(nil) }
    }
}
