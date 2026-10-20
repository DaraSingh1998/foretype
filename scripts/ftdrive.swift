// Dev tool: drives the frontmost app with synthetic keystrokes for end-to-end tests.
// Events are posted at the HID tap, so they pass through Foretype's session taps exactly
// like real typing. Typing pauses while another app is frontmost and aborts if the app that
// was frontmost at the start does not come back within 2 s.
//
// usage: ftdrive type TEXT [interval_ms]
//        ftdrive key tab|esc|opt-tab|accept-all|cmd-down|return|force|snooze|ctrl-c
//        ftdrive front   (prints the frontmost app's bundle ID)
//        ftdrive front-pid (prints the frontmost app's pid)
//        ftdrive raise PID (makes that process frontmost through AXFrontmost)
//
// Accessibility commands for testing an app's own windows without keystrokes (they work
// for menu-bar apps, which screen-control tools often cannot target):
//        ftdrive windows BUNDLE_ID            window titles, buttons and texts, plus each
//                                             window's CGWindowID for `screencapture -l`
//        ftdrive press BUNDLE_ID TITLE        AXPress the first button, checkbox or radio
//                                             button (toolbar tab) titled TITLE
//        ftdrive menu BUNDLE_ID [ITEM ...]    open the app's menu-bar extra: list its items,
//                                             or walk ITEM (submenus) and press the last one
//                                             (a last ITEM with a submenu lists that instead);
//                                             FTDRIVE_HOLD=SECONDS keeps a listed menu open
import AppKit
import Carbon

func frontPid() -> pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }

func post(_ key: CGKeyCode, flags: CGEventFlags = [], unicode: [UniChar]? = nil) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
        ev.flags = flags
        if var u = unicode { ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u) }
        ev.post(tap: .cghidEventTap)
        usleep(8000)
    }
}

// MARK: - Accessibility helpers

/// BUNDLE_ID, or a numeric pid to target one process of an app that runs several.
func axApp(_ bundle: String) -> (AXUIElement, pid_t) {
    if let pid = pid_t(bundle) { return (AXUIElementCreateApplication(pid), pid) }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        FileHandle.standardError.write("\(bundle) is not running\n".data(using: .utf8)!)
        exit(1)
    }
    return (AXUIElementCreateApplication(app.processIdentifier), app.processIdentifier)
}

func axAttr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func axChildren(_ e: AXUIElement) -> [AXUIElement] { axAttr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func axRole(_ e: AXUIElement) -> String { axAttr(e, kAXRoleAttribute) as? String ?? "" }
func axTitle(_ e: AXUIElement) -> String {
    for a in [kAXTitleAttribute, kAXDescriptionAttribute] {
        if let s = axAttr(e, a) as? String, !s.isEmpty { return s }
    }
    return ""
}

/// Titles compare without a trailing ellipsis ("Check for Updates…" == "Check for Updates").
/// A wanted title ending in `*` matches by prefix (titles with live progress in them).
func sameTitle(_ a: String, _ b: String) -> Bool {
    let t = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: ".…").union(.whitespaces)).lowercased() }
    if b.hasSuffix("*") { return t(a).hasPrefix(t(String(b.dropLast()))) }
    return t(a) == t(b)
}

func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(e, depth) { return true }
    guard depth < 12 else { return false }
    for c in axChildren(e) where walk(c, depth: depth + 1, visit) { return true }
    return false
}

func menuItems(_ menuOwner: AXUIElement, tries: Int = 20) -> [AXUIElement] {
    for _ in 0..<tries {
        if let menu = axChildren(menuOwner).first(where: { axRole($0) == kAXMenuRole }) {
            return axChildren(menu).filter { axRole($0) == kAXMenuItemRole }
        }
        usleep(50_000)
    }
    return []
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: ftdrive type TEXT [interval_ms] | key NAME | front\n".data(using: .utf8)!)
    exit(2)
}
switch args[1] {
case "front":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
case "front-pid":
    print(frontPid())
case "raise" where args.count == 3:
    guard let pid = pid_t(args[2]) else { exit(2) }
    let r = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    exit(r == .success ? 0 : 1)
case "type":
    let text = args.count > 2 ? args[2] : ""
    let interval = args.count > 3 ? (Double(args[3]) ?? 120) : 120
    let target = frontPid()
    for ch in text {
        // A notification or another app can take focus for a moment; pause (never type
        // into it) and give up only if the target does not come back within 2 s.
        var waited = 0
        while frontPid() != target {
            if waited >= 2000 {
                FileHandle.standardError.write("aborted: focus left the target app\n".data(using: .utf8)!)
                exit(3)
            }
            usleep(100_000)
            waited += 100
        }
        if ch == "\n" { post(36) } else { post(0, unicode: Array(String(ch).utf16)) }
        usleep(useconds_t(interval * 1000))
    }
case "key":
    let iso = Int(KBGetLayoutType(Int16(LMGetKbdType()))) == Int(kKeyboardISO)
    switch args.count > 2 ? args[2] : "" {
    case "tab": post(48)
    case "opt-tab": post(48, flags: .maskAlternate)
    case "esc": post(53)
    case "accept-all": post(iso ? 10 : 50)
    case "cmd-down": post(125, flags: .maskCommand)
    case "return": post(36)
    case "force": post(iso ? 10 : 50, flags: .maskControl)
    case "snooze": post(iso ? 10 : 50, flags: [.maskControl, .maskAlternate, .maskCommand])
    case "ctrl-c": post(8, flags: .maskControl)
    default: exit(2)
    }
case "windows" where args.count == 3:
    let (app, pid) = axApp(args[2])
    for w in axAttr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        print("window: \(axTitle(w))")
        _ = walk(w) { e, d in
            let role = axRole(e)
            let pad = String(repeating: "  ", count: min(d, 6))
            if role == kAXButtonRole || role == kAXCheckBoxRole || role == kAXPopUpButtonRole || role == kAXRadioButtonRole {
                let state = role == kAXCheckBoxRole ? " [\((axAttr(e, kAXValueAttribute) as? Int) == 1 ? "x" : " ")]" : ""
                print("\(pad)\(role.dropFirst(2).lowercased()): \(axTitle(e))\(state)")
            } else if role == kAXStaticTextRole, let v = axAttr(e, kAXValueAttribute) as? String, !v.isEmpty {
                print("\(pad)text: \(v.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            }
            return false
        }
    }
    let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for i in infos where (i[kCGWindowOwnerPID as String] as? pid_t) == pid {
        let b = i[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let on = (i[kCGWindowIsOnscreen as String] as? Bool) == true ? "on" : "off"
        print("cgwindow \(i[kCGWindowNumber as String] ?? 0) layer \(i[kCGWindowLayer as String] ?? 0) \(on) " +
              "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
    }
case "press" where args.count == 4:
    let (app, _) = axApp(args[2])
    var pressed = false
    for w in axAttr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] where !pressed {
        pressed = walk(w) { e, _ in
            let role = axRole(e)
            guard role == kAXButtonRole || role == kAXCheckBoxRole || role == kAXRadioButtonRole,
                  sameTitle(axTitle(e), args[3]) else { return false }
            let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
            // No reply in time: the button opened a modal alert (runModal blocks the app's
            // reply). It was pressed; don't go on to press the next button with this title.
            if r == .cannotComplete { print("pressed; the app is busy (a modal alert?)") }
            return r == .success || r == .cannotComplete
        }
    }
    if !pressed {
        FileHandle.standardError.write("no button titled \(args[3])\n".data(using: .utf8)!)
        exit(1)
    }
case "menu" where args.count >= 3:
    let (app, _) = axApp(args[2])
    guard let extras = axAttr(app, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID(),
          let item = axChildren(extras as! AXUIElement).first else {
        FileHandle.standardError.write("no menu-bar extra\n".data(using: .utf8)!)
        exit(1)
    }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    var owner = item
    var items = menuItems(owner)
    let path = Array(args.dropFirst(3))
    func list(_ items: [AXUIElement]) {
        for i in items {
            let t = axTitle(i)
            let mark = (axAttr(i, "AXMenuItemMarkChar") as? String).map { "\($0) " } ?? ""
            let off = (axAttr(i, kAXEnabledAttribute) as? Bool) == false ? " (disabled)" : ""
            print(t.isEmpty ? "---" : "\(mark)\(t)\(axChildren(i).isEmpty ? "" : " ▸")\(off)")
        }
    }
    if path.isEmpty {
        list(items)
        // FTDRIVE_HOLD=SECONDS keeps the menu open that long (for a screenshot).
        if let hold = ProcessInfo.processInfo.environment["FTDRIVE_HOLD"].flatMap(Double.init) {
            usleep(useconds_t(hold * 1_000_000))
        }
        if let menu = axChildren(item).first(where: { axRole($0) == kAXMenuRole }) {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
        exit(0)
    }
    for (n, title) in path.enumerated() {
        guard let next = items.first(where: { sameTitle(axTitle($0), title) }) else {
            FileHandle.standardError.write("no menu item \(title); have: \(items.map(axTitle))\n".data(using: .utf8)!)
            if let menu = axChildren(item).first(where: { axRole($0) == kAXMenuRole }) {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
            exit(1)
        }
        AXUIElementPerformAction(next, kAXPressAction as CFString)
        if n < path.count - 1 {
            owner = next
            items = menuItems(owner)
        } else if !axChildren(next).isEmpty {
            list(menuItems(next, tries: 5))
            if let menu = axChildren(item).first(where: { axRole($0) == kAXMenuRole }) {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
        }
    }
default:
    exit(2)
}
