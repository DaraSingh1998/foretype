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

    private static func attributed(_ text: String, font: NSFont, card: Bool) -> NSAttributedString {
        let color = card ? NSColor.secondaryLabelColor : NSColor(white: 0.5, alpha: 0.85)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
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

    func show(text: String, caret: CaretInfo?, frame: CGRect?, font: NSFont?, midLine: Bool = false) {
        let caretRect = caret?.rect
        let baseFont = font ?? NSFont.systemFont(ofSize: max(11, (caretRect?.height ?? 16) * 0.78))
        if midLine, let caretRect {
            return showCard(text, font: baseFont, below: caretRect)
        }
        if let caretRect {
            let x = caretRect.minX + caretRect.width
            let limit = (frame.map { $0.maxX } ?? (displayBounds().first { $0.contains(caretRect.origin) }?.maxX ?? x + 600)) - 4
            let shown = GhostPanel.fitting(text, font: baseFont, width: max(0, limit - x))
            if !shown.trimmingCharacters(in: .whitespaces).isEmpty {
                let attr = GhostPanel.attributed(shown, font: baseFont, card: false)
                let size = attr.size()
                let axRect = CGRect(x: x, y: caretRect.midY - size.height / 2, width: ceil(size.width) + 2, height: ceil(size.height))
                view.card = false
                view.text = attr
                anchor = (caretRect, baseFont)
                place(GhostPanel.cocoaRect(fromAX: axRect))
                return
            }
        }
        // Mirror card: above the field (or below the caret line when the field is unknown).
        guard let anchorRect = frame ?? caretRect else { return hide() }
        let cardFont = NSFont.systemFont(ofSize: min(max(baseFont.pointSize, 12), 15))
        let attr = GhostPanel.attributed("\u{21E5} " + text.trimmingCharacters(in: .whitespaces), font: cardFont, card: true)
        let size = attr.size()
        let w = ceil(size.width) + view.padding.width * 2
        let h = ceil(size.height) + view.padding.height * 2
        var axRect = CGRect(x: anchorRect.minX, y: anchorRect.minY - h - 4, width: w, height: h)
        if axRect.minY < 0 { axRect.origin.y = anchorRect.maxY + 4 }
        view.card = true
        view.text = attr
        anchor = nil
        place(GhostPanel.cocoaRect(fromAX: axRect))
    }

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
        panel.setFrame(rect, display: false)
        view.frame = NSRect(origin: .zero, size: rect.size)
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        anchor = nil
        if panel.isVisible { panel.orderOut(nil) }
    }
}
