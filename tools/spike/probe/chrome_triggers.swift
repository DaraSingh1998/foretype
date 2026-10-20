// Finds what makes a fresh Chrome expose its focused web element to an outside
// Accessibility client. Applies one trigger to a Chrome process (by pid), then reads the
// app's AXFocusedUIElement every 250 ms and prints one JSON line per read, plus a summary.
// Run by run_chrome_triggers.sh, which starts a separate throwaway-profile Chrome per trigger.
//
// usage: chrome_triggers PID TRIGGER [SECONDS]
//   none            only the reads (an outside client polling AXFocusedUIElement)
//   observer        AXObserver on the app first, as FocusTracker attaches it
//   window          read AXFocusedUIElement from the focused window instead of the app
//   walk            walk the focused window's AX tree once before reading
//   enhanced        set AXEnhancedUserInterface and keep it set
//   enhanced-blip   set it, then clear it after 0.5 s (what `axprobe --once --chromium-ax` did)
//   manual          set AXManualAccessibility and keep it
//   observer+enhanced  FocusTracker's order: observer, then the flag (kept)
//   clear           clear AXEnhancedUserInterface (to see whether a running Foretype
//                   notices the lost tree and primes again)
//   hittest         AXUIElementCopyElementAtPosition at the window's middle, then that
//                   element's AXRole (Chromium turns on web content when an AT reaches the
//                   web view, which a hit test does even before the web tree exists)
// The flags are cleared again at exit.
import AppKit
import ApplicationServices

func errName(_ e: AXError) -> String {
    switch e {
    case .success: return "ok"
    case .noValue: return "noValue"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .notImplemented: return "notImplemented"
    case .illegalArgument: return "illegalArgument"
    case .failure: return "failure"
    default: return "ax\(e.rawValue)"
    }
}

func copy(_ el: AXUIElement, _ attr: String) -> (AXError, CFTypeRef?) {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
    return (e, e == .success ? v : nil)
}

func element(_ v: CFTypeRef?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func string(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr).1 as? String }
func bool(_ el: AXUIElement, _ attr: String) -> Any {
    guard let v = copy(el, attr).1, CFGetTypeID(v) == CFBooleanGetTypeID() else { return NSNull() }
    return CFBooleanGetValue((v as! CFBoolean))
}

/// Counts AXWebArea elements under `root` (depth-limited) and returns the first text area.
func walk(_ root: AXUIElement, depth: Int = 0, webAreas: inout Int, nodes: inout Int) -> AXUIElement? {
    nodes += 1
    let role = string(root, kAXRoleAttribute) ?? ""
    if role == "AXWebArea" { webAreas += 1 }
    if role == "AXTextArea" { return root }
    guard depth < 30, nodes < 4000 else { return nil }
    var found: AXUIElement?
    for c in (copy(root, kAXChildrenAttribute).1 as? [AXUIElement]) ?? [] {
        if let t = walk(c, depth: depth + 1, webAreas: &webAreas, nodes: &nodes), found == nil { found = t }
    }
    return found
}

func emit(_ o: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    print(String(data: d, encoding: .utf8)!)
    fflush(stdout)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: chrome_triggers PID TRIGGER [SECONDS]\n".data(using: .utf8)!)
    exit(2)
}
let trigger = args[2]
let seconds = args.count > 3 ? Double(args[3]) ?? 10 : 10
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("not trusted for Accessibility\n".data(using: .utf8)!)
    exit(2)
}
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
let app = AXUIElementCreateApplication(pid)
let start = CFAbsoluteTimeGetCurrent()
func now() -> Double { ((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded() / 1000 }

var notifications: [String: Int] = [:]
var observer: AXObserver?
func attachObserver() {
    let cb: AXObserverCallback = { _, _, name, _ in notifications[name as String, default: 0] += 1 }
    guard AXObserverCreate(pid, cb, &observer) == .success, let obs = observer else {
        emit(["t": now(), "event": "observerCreateFailed"]); return
    }
    var added: [String: String] = [:]
    for n in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
              kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
        added[n] = errName(AXObserverAddNotification(obs, app, n as CFString, nil))
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    emit(["t": now(), "event": "observer", "added": added])
}
func setFlag(_ name: String, _ on: Bool) {
    let e = AXUIElementSetAttributeValue(app, name as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    emit(["t": now(), "event": "set", "attr": name, "value": on, "err": errName(e), "readBack": bool(app, name)])
}

emit(["t": now(), "event": "start", "pid": Int(pid), "trigger": trigger,
      "enhancedBefore": bool(app, "AXEnhancedUserInterface"), "manualBefore": bool(app, "AXManualAccessibility"),
      "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid])

var setFlags: [String] = []
switch trigger {
case "none", "window": break
case "observer": attachObserver()
case "walk":
    if let w = element(copy(app, kAXFocusedWindowAttribute).1) {
        var webAreas = 0, nodes = 0
        let ta = walk(w, webAreas: &webAreas, nodes: &nodes)
        emit(["t": now(), "event": "walk", "nodes": nodes, "webAreas": webAreas, "textArea": ta != nil])
    }
case "enhanced": setFlag("AXEnhancedUserInterface", true); setFlags.append("AXEnhancedUserInterface")
case "enhanced-blip":
    setFlag("AXEnhancedUserInterface", true)
    CFRunLoopRunInMode(.defaultMode, 0.5, false)
    setFlag("AXEnhancedUserInterface", false)
case "hittest":
    let w = element(copy(app, kAXFocusedWindowAttribute).1)
    var pos = CGPoint.zero, size = CGSize.zero
    if let w, let p = copy(w, kAXPositionAttribute).1, let z = copy(w, kAXSizeAttribute).1 {
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(z as! AXValue, .cgSize, &size)
    }
    let pt = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height * 0.6)
    var hit: AXUIElement?
    let e = AXUIElementCopyElementAtPosition(app, Float(pt.x), Float(pt.y), &hit)
    emit(["t": now(), "event": "hittest", "x": pt.x, "y": pt.y, "err": errName(e),
          "role": hit.flatMap { string($0, kAXRoleAttribute) } ?? NSNull()])
case "clear": setFlag("AXEnhancedUserInterface", false)
case "manual": setFlag("AXManualAccessibility", true); setFlags.append("AXManualAccessibility")
case "observer+enhanced":
    attachObserver()
    setFlag("AXEnhancedUserInterface", true); setFlags.append("AXEnhancedUserInterface")
default:
    FileHandle.standardError.write("unknown trigger \(trigger)\n".data(using: .utf8)!)
    exit(2)
}

var firstReadable: Double?
var reads = 0
while now() < seconds {
    CFRunLoopRunInMode(.defaultMode, 0.25, false)
    reads += 1
    var source = app
    var line: [String: Any] = ["t": now()]
    if trigger == "window" {
        let (we, w) = copy(app, kAXFocusedWindowAttribute)
        line["window"] = errName(we)
        if let w = element(w) { source = w }
    }
    let (e, v) = copy(source, kAXFocusedUIElementAttribute)
    line["focused"] = errName(e)
    if let el = element(v) {
        let role = string(el, kAXRoleAttribute) ?? ""
        line["role"] = role
        line["valueLen"] = (string(el, kAXValueAttribute) as NSString?)?.length ?? NSNull()
        if role == "AXTextArea", firstReadable == nil { firstReadable = now() }
        // The caret rect Foretype needs: AXBoundsForRange of the character before the caret.
        if role == "AXTextArea", let r = copy(el, kAXSelectedTextRangeAttribute).1 {
            var sel = CFRange()
            AXValueGetValue(r as! AXValue, .cfRange, &sel)
            var q = CFRange(location: max(0, sel.location - 1), length: 1)
            var b: CFTypeRef?
            let be = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                AXValueCreate(.cfRange, &q)!, &b)
            var rect = CGRect.zero
            if be == .success, let b { AXValueGetValue(b as! AXValue, .cgRect, &rect) }
            line["caret"] = sel.location
            line["bounds"] = be == .success ? [rect.minX, rect.minY, rect.width, rect.height].map { $0.rounded() } : errName(be) as Any
        }
    }
    line["enhanced"] = bool(app, "AXEnhancedUserInterface")
    emit(line)
}

// After the timeline: does the window's tree contain web content at all?
var webAreas = 0, nodes = 0, textArea = false
if let w = element(copy(app, kAXFocusedWindowAttribute).1) {
    textArea = walk(w, webAreas: &webAreas, nodes: &nodes) != nil
}
for f in setFlags { setFlag(f, false) }
emit(["t": now(), "event": "summary", "trigger": trigger, "reads": reads,
      "firstTextAreaAt": firstReadable ?? NSNull(), "notifications": notifications,
      "finalWalk": ["nodes": nodes, "webAreas": webAreas, "textArea": textArea]])
