// Dev tool: drives the frontmost app with synthetic keystrokes for end-to-end tests.
// Events are posted at the HID tap, so they pass through Foretype's session taps exactly
// like real typing. Typing pauses while another app is frontmost and aborts if the app that
// was frontmost at the start does not come back within 2 s.
//
// usage: ftdrive type TEXT [interval_ms]
//        ftdrive key tab|esc|opt-tab|accept-all|cmd-down|return|force|snooze|ctrl-c
//        ftdrive front   (prints the frontmost app's bundle ID)
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

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: ftdrive type TEXT [interval_ms] | key NAME | front\n".data(using: .utf8)!)
    exit(2)
}
switch args[1] {
case "front":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
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
default:
    exit(2)
}
