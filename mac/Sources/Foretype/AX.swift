import AppKit
import ApplicationServices

/// Thin, typed wrappers over the HIServices Accessibility C API.
enum AX {
    static let systemWide = AXUIElementCreateSystemWide()

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func copyParam(_ el: AXUIElement, _ attr: String, _ param: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, param, &v) == .success ? v : nil
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, attr as CFString, value)
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr) as? String
    }

    static func bool(_ v: CFTypeRef?) -> Bool? {
        guard let v, CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    private static func value(_ v: CFTypeRef?, _ type: AXValueType) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let av = v as! AXValue
        return AXValueGetType(av) == type ? av : nil
    }

    static func range(_ v: CFTypeRef?) -> CFRange? {
        guard let av = value(v, .cfRange) else { return nil }
        var r = CFRange()
        return AXValueGetValue(av, .cfRange, &r) ? r : nil
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let av = value(v, .cgRect) else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(av, .cgRect, &r) ? r : nil
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let av = value(v, .cgPoint) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(av, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let av = value(v, .cgSize) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(av, .cgSize, &s) ? s : nil
    }

    static func makeRange(_ location: Int, _ length: Int) -> AXValue {
        var r = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &r)!
    }

    static func string(_ el: AXUIElement, range location: Int, _ length: Int) -> String? {
        guard length > 0 else { return length == 0 ? "" : nil }
        return copyParam(el, "AXStringForRange", makeRange(location, length)) as? String
    }

    static func bounds(_ el: AXUIElement, _ location: Int, _ length: Int) -> CGRect? {
        rect(copyParam(el, "AXBoundsForRange", makeRange(location, length)))
    }

    /// Text around the caret through WebKit/Chromium text markers, for web fields whose
    /// `AXValue` and `AXStringForRange` fail (some contenteditable editors). Returns the text
    /// before the caret (at most `maxBefore` characters), the rest of the caret's line, the
    /// selection's length and the caret rect, or nil when the field has no text markers.
    static func viaTextMarkers(_ el: AXUIElement, maxBefore: Int) -> (before: String, after: String, selection: Int, caret: CGRect?)? {
        guard let sel = copy(el, "AXSelectedTextMarkerRange"),
              let caret = copyParam(el, "AXStartTextMarkerForTextMarkerRange", sel),
              let selEnd = copyParam(el, "AXEndTextMarkerForTextMarkerRange", sel),
              let field = copyParam(el, "AXTextMarkerRangeForUIElement", el),
              let start = copyParam(el, "AXStartTextMarkerForTextMarkerRange", field),
              let end = copyParam(el, "AXEndTextMarkerForTextMarkerRange", field) else { return nil }
        func text(_ a: CFTypeRef, _ b: CFTypeRef) -> String? {
            guard let r = copyParam(el, "AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) else { return nil }
            return copyParam(el, "AXStringForTextMarkerRange", r) as? String
        }
        guard let before = text(start, caret) else { return nil }
        let after = text(selEnd, end)?.components(separatedBy: .newlines).first ?? ""
        let selection = (copyParam(el, "AXLengthForTextMarkerRange", sel) as? Int) ?? 0
        // The caret is the trailing edge of the character before it.
        var rect: CGRect?
        if let prev = copyParam(el, "AXPreviousTextMarkerForTextMarker", caret),
           let r = copyParam(el, "AXTextMarkerRangeForUnorderedTextMarkers", [prev, caret] as CFArray),
           let b = self.rect(copyParam(el, "AXBoundsForTextMarkerRange", r)), b.height > 0 {
            rect = CGRect(x: b.maxX, y: b.minY, width: 1, height: b.height)
        }
        return (String(before.suffix(maxBefore)), String(after.prefix(160)), selection, rect)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(copy(el, "AXPosition")), let s = size(copy(el, "AXSize")) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

/// Global display bounds in AX coordinates (origin at the top-left of the main display).
func displayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}

enum Log {
    static let enabled = ProcessInfo.processInfo.environment["FORETYPE_DEBUG"] != nil
    private static let start = Date()
    private static let lock = NSLock()
    private static var masked: [String] = []

    /// Pieces of the user's About You details (`AboutYou.logMasks`), shown as "***" in every
    /// message: a model suggestion can echo a detail it read in the document.
    static func mask(_ pieces: [String]) {
        lock.lock(); masked = pieces; lock.unlock()
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let t = String(format: "%8.3f", Date().timeIntervalSince(start))
        lock.lock(); let pieces = masked; lock.unlock()
        let text = pieces.reduce(message()) { $0.replacingOccurrences(of: $1, with: "***", options: .caseInsensitive) }
        FileHandle.standardError.write("[\(t)] \(text)\n".data(using: .utf8)!)
    }
}
