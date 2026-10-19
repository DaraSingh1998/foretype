import AppKit
import ApplicationServices
import Carbon

/// What makes two snapshots "the same" for change detection.
struct Signature: Equatable {
    var pid: pid_t
    var elementHash: Int
    var selection: [Int]
    var marked: [Int]
    var valueLength: Int
}

/// Checks a candidate caret rect against the failure modes Tabber's CaretMath lists
/// (origin = "don't know", whole element frame, line-wide "character", off-screen, ...).
func caretIssues(_ r: CGRect?, frame: CGRect?, singleChar: Bool) -> [String] {
    guard let r else { return ["missing"] }
    var issues: [String] = []
    if r.origin == .zero { issues.append("originZero") }
    if r.height <= 0 { issues.append("zeroHeight") }
    if r.height > 200 { issues.append("tooTall") }
    if let f = frame, f.width > 0 {
        if abs(r.minX - f.minX) < 1, abs(r.minY - f.minY) < 1,
           abs(r.width - f.width) < 1, abs(r.height - f.height) < 1 {
            issues.append("equalsElementFrame")
        } else if !f.insetBy(dx: -4, dy: -4).contains(CGPoint(x: r.minX, y: r.midY)) {
            issues.append("outsideElementFrame")
        }
    }
    if singleChar, r.height > 0, r.width > max(4 * r.height, 60) { issues.append("wideForSingleChar") }
    let screens = displayBounds()
    if !screens.isEmpty, !screens.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.minX, y: r.midY)) }) {
        issues.append("offScreen")
    }
    return issues
}

enum Snapshot {
    static let systemWide = AXUIElementCreateSystemWide()

    static var timeoutMs = 80.0

    /// Frontmost app as an AX element. Tries the system-wide AXFocusedApplication first, as the
    /// clones do; on macOS 27.0.1 that call fails instantly with cannotComplete for this CLI
    /// while per-app AX works, so fall back to NSWorkspace's frontmost pid. `log.focusSource`
    /// records which path answered.
    static func focusedApp(_ log: CallLog) -> (AXUIElement, pid_t)? {
        if let app = asElement(log.copy(systemWide, "AXFocusedApplication", label: "AXFocusedApplication(systemWide)")) {
            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            log.focusSource = "systemWide"
            return (app, pid)
        }
        let t = Clock.nowNs()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        log.note("NSWorkspace.frontmostApplication", ok: pid != nil, ms: Clock.ms(since: t))
        guard let pid, pid > 0 else { return nil }
        log.focusSource = "NSWorkspace"
        return (AXUIElementCreateApplication(pid), pid)
    }

    static func appInfo(_ pid: pid_t) -> [String: Any] {
        let ra = NSRunningApplication(processIdentifier: pid)
        return ["pid": Int(pid), "bundleId": ra?.bundleIdentifier ?? NSNull(),
                "name": ra?.localizedName ?? NSNull(), "engine": WebAX.engine(for: pid).rawValue]
    }

    /// Cheap read used by the poll loop: focused element, selection and length only.
    static func quickSignature() -> Signature? {
        let log = CallLog()
        guard let (app, pid) = focusedApp(log) else { return nil }
        guard let el = asElement(log.copy(app, "AXFocusedUIElement")) else {
            return Signature(pid: pid, elementHash: 0, selection: [], marked: [], valueLength: -1)
        }
        let sel = axRange(log.copy(el, "AXSelectedTextRange"))
        let n = log.copy(el, "AXNumberOfCharacters") as? Int
        return Signature(pid: pid, elementHash: Int(CFHash(el)),
                         selection: sel.map { [$0.location, $0.length] } ?? [],
                         marked: [], valueLength: n ?? -1)
    }

    /// Full read of the focused text field. Every AX call is timed and listed in `calls`.
    static func take(reason: String) -> (json: [String: Any], signature: Signature?) {
        let log = CallLog()
        let t0 = Clock.nowNs()
        var o: [String: Any] = ["type": "snapshot", "reason": reason,
                                "secureInput": IsSecureEventInputEnabled()]
        func finish(_ sig: Signature?) -> ([String: Any], Signature?) {
            o["calls"] = log.json
            o["axTotalMs"] = r3(log.totalMs)
            o["wallMs"] = r3(Clock.ms(since: t0))
            o["axCallCount"] = log.calls.count
            o["cannotCompleteCount"] = log.calls.filter { $0.err == .cannotComplete }.count
            o["timeouts"] = log.calls.filter { $0.err == .cannotComplete && $0.ms >= timeoutMs * 0.9 }.count
            o["focusSource"] = orNull(log.focusSource)
            return (o, sig)
        }

        guard let (app, pid) = focusedApp(log) else {
            o["error"] = "noFocusedApplication"
            return finish(nil)
        }
        o["app"] = appInfo(pid)
        // Diagnostic only: Tabber reads the focused element straight from the system-wide
        // element. Record whether that path answers in this launch context.
        o["systemWideFocusedElementOK"] = asElement(log.copy(systemWide, "AXFocusedUIElement",
                                                             label: "AXFocusedUIElement(systemWide)")) != nil

        guard let el = asElement(log.copy(app, "AXFocusedUIElement")) else {
            o["error"] = "noFocusedElement"
            return finish(Signature(pid: pid, elementHash: 0, selection: [], marked: [], valueLength: -1))
        }

        o["role"] = log.copy(el, "AXRole") as? String ?? NSNull()
        o["subrole"] = log.copy(el, "AXSubrole") as? String ?? NSNull()
        o["roleDescription"] = log.copy(el, "AXRoleDescription") as? String ?? NSNull()

        // AXValue: only the length leaves this process, never the text.
        let rawValue = log.copy(el, "AXValue")
        var valueLength = -1
        if let s = rawValue as? String {
            valueLength = (s as NSString).length
            o["valueType"] = "string"
        } else if let rawValue {
            o["valueType"] = CFCopyTypeIDDescription(CFGetTypeID(rawValue)) as String
        } else {
            o["valueType"] = NSNull()
        }
        o["valueLength"] = valueLength >= 0 ? valueLength : NSNull()
        let numChars = log.copy(el, "AXNumberOfCharacters") as? Int
        o["numberOfCharacters"] = numChars ?? NSNull()

        let sel = axRange(log.copy(el, "AXSelectedTextRange"))
        let marked = axRange(log.copy(el, "AXTextInputMarkedRange"))
        o["selectedTextRange"] = rangeJSON(sel)
        o["markedRange"] = rangeJSON(marked)

        let pos = axPoint(log.copy(el, "AXPosition"))
        let size = axSize(log.copy(el, "AXSize"))
        let frame: CGRect? = (pos != nil && size != nil) ? CGRect(origin: pos!, size: size!) : nil
        o["elementFrame"] = rectJSON(frame)

        // Caret: zero-length bounds first, then the previous character's trailing edge.
        var caret: [String: Any] = [:]
        var chosen: (String, CGRect)?
        if let sel {
            let zero = axRect(log.copyParam(el, "AXBoundsForRange", makeRange(sel.location, 0),
                                            label: "AXBoundsForRange(caret,0)"))
            let zeroIssues = caretIssues(zero, frame: frame, singleChar: false)
            caret["zeroLength"] = ["rect": rectJSON(zero), "issues": zeroIssues]
            if zeroIssues.isEmpty, let zero { chosen = ("zeroLength", zero) }

            if sel.location > 0 {
                let prevRange = makeRange(sel.location - 1, 1)
                let prev = axRect(log.copyParam(el, "AXBoundsForRange", prevRange,
                                                label: "AXBoundsForRange(prev,1)"))
                let prevText = log.copyParam(el, "AXStringForRange", prevRange,
                                             label: "AXStringForRange(prev,1)") as? String
                var prevIssues = caretIssues(prev, frame: frame, singleChar: true)
                let prevClass: String
                switch prevText {
                case nil: prevClass = "unknown"
                case "\n", "\r", "\u{2028}", "\u{2029}": prevClass = "newline"
                case " ", "\t": prevClass = "space"
                default: prevClass = "other"
                }
                if prevClass == "newline" { prevIssues.append("prevIsNewline") }
                let edge = prev.map { CGRect(x: $0.maxX, y: $0.minY, width: 0, height: $0.height) }
                caret["prevCharTrailingEdge"] = ["charRect": rectJSON(prev), "caret": rectJSON(edge),
                                                 "prevCharClass": prevClass, "issues": prevIssues]
                if chosen == nil, prevIssues.isEmpty, let edge { chosen = ("prevCharTrailingEdge", edge) }
                if let zero, let edge, zeroIssues.isEmpty, prevIssues.isEmpty {
                    caret["strategiesDisagreeByPx"] = r3(Double(hypot(zero.minX - edge.minX, zero.minY - edge.minY)))
                }
            }
        }
        caret["chosen"] = chosen.map { ["strategy": $0.0, "rect": rectJSON($0.1)] } ?? NSNull()
        o["caret"] = caret

        // AXFont from the attributed string around the caret.
        var font: Any = NSNull()
        var attrKeys: [String] = []
        let fontLoc: Int? = sel.flatMap { s in s.location > 0 ? s.location - 1 : ((numChars ?? valueLength) > 0 ? 0 : nil) }
        if let fontLoc,
           let raw = log.copyParam(el, "AXAttributedStringForRange", makeRange(fontLoc, 1),
                                   label: "AXAttributedStringForRange(1)"),
           CFGetTypeID(raw) == CFAttributedStringGetTypeID() {
            let attributed = raw as! NSAttributedString
            if attributed.length > 0 {
                let attrs = attributed.attributes(at: 0, effectiveRange: nil)
                attrKeys = attrs.keys.map { $0.rawValue }.sorted()
                if let f = attrs[NSAttributedString.Key("AXFont")] { font = jsonSafe(f) }
            }
        }
        o["axFont"] = font
        o["attributedStringKeys"] = attrKeys

        if WebAX.engine(for: pid) != .other {
            o["web"] = ["AXManualAccessibility": orNull(boolValue(log.copy(app, "AXManualAccessibility"))),
                        "AXEnhancedUserInterface": orNull(boolValue(log.copy(app, "AXEnhancedUserInterface")))]
        }

        let sig = Signature(pid: pid, elementHash: Int(CFHash(el)),
                            selection: sel.map { [$0.location, $0.length] } ?? [],
                            marked: marked.map { [$0.location, $0.length] } ?? [],
                            valueLength: numChars ?? valueLength)
        return finish(sig)
    }
}
