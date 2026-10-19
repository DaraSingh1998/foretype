import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Marker placed in eventSourceUserData of keystrokes this probe synthesises (`--type`).
let syntheticMarker: Int64 = 0x4158_5052 // "AXPR"

/// Shared between the tap thread and the AX (main) thread.
enum KeyState {
    private static let lock = NSLock()
    private static var _lastKeyDownNs: UInt64 = 0
    private static var _keyDowns = 0

    static func noteKeyDown() {
        lock.lock(); _lastKeyDownNs = Clock.nowNs(); _keyDowns += 1; lock.unlock()
    }

    static var msSinceLastKeyDown: Double? {
        lock.lock(); defer { lock.unlock() }
        return _lastKeyDownNs == 0 ? nil : Clock.ms(since: _lastKeyDownNs)
    }

    static var keyDowns: Int { lock.lock(); defer { lock.unlock() }; return _keyDowns }
}

/// Permanent listen-only session tap on its own CFRunLoop thread. It can never stall
/// input: listen-only taps ignore the callback's return value.
enum KeyTap {
    static var logChars = false
    private static var port: CFMachPort?
    private static var stopping = false

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Our own tapEnable(false) at shutdown arrives as tapDisabledByUserInput.
            if KeyTap.stopping { return Unmanaged.passUnretained(event) }
            if let port = KeyTap.port { CGEvent.tapEnable(tap: port, enable: true) }
            Out.emit(["type": "tapDisabled", "cause": type == .tapDisabledByTimeout ? "timeout" : "userInput",
                      "reenabled": true, "secureInput": IsSecureEventInputEnabled()])
            return Unmanaged.passUnretained(event)
        }
        let kind: String
        switch type {
        case .keyDown: kind = "down"; KeyState.noteKeyDown()
        case .keyUp: kind = "up"
        case .flagsChanged: kind = "flags"
        default: kind = "other\(type.rawValue)"
        }
        var line: [String: Any] = [
            "type": "key", "kind": kind,
            "keyCode": event.getIntegerValueField(.keyboardEventKeycode),
            "autorepeat": event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            "flags": String(format: "0x%llx", event.flags.rawValue),
            "sourcePid": event.getIntegerValueField(.eventSourceUnixProcessID),
            "sourceStateId": event.getIntegerValueField(.eventSourceStateID),
            "synthetic": event.getIntegerValueField(.eventSourceUserData) == syntheticMarker,
            "secureInput": IsSecureEventInputEnabled(),
            "tapLagMs": Clock.eventLagMs(event.timestamp).map { r3($0) } ?? NSNull(),
        ]
        if type != .flagsChanged {
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
            line["charCount"] = len
            if logChars { line["chars"] = String(utf16CodeUnits: buf, count: len) }
        }
        Out.emit(line)
        return Unmanaged.passUnretained(event)
    }

    static func start() {
        let thread = Thread {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                               callback: callback, userInfo: nil) else {
                Out.emit(["type": "tap", "created": false,
                          "listenEventAccess": CGPreflightListenEventAccess(),
                          "note": "CGEvent.tapCreate returned nil (needs Accessibility or Input Monitoring)"])
                return
            }
            KeyTap.port = port
            let src = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            Out.emit(["type": "tap", "created": true, "enabled": CGEvent.tapIsEnabled(tap: port),
                      "location": "cgSessionEventTap", "options": "listenOnly",
                      "listenEventAccess": CGPreflightListenEventAccess()])
            CFRunLoopRun()
        }
        thread.name = "axprobe.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    static func stop() {
        stopping = true
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
    }
}

/// `--type TEXT`: synthesises keystrokes into the frontmost app so the probe can measure
/// keystroke -> AX latency unattended. Unicode payload on virtual key 0, Return for
/// newlines, posted at the HID tap so our own session tap sees them. Aborts if focus
/// leaves the app that was frontmost when typing started.
enum Typer {
    static func run(text: String, startDelayMs: Int, intervalMs: Int, gotoEnd: Bool, onlyIn bundleId: String?,
                    onDone: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(startDelayMs)) {
            let src = CGEventSource(stateID: .hidSystemState)
            src?.userData = syntheticMarker
            let log = CallLog()
            guard let (_, targetPid) = Snapshot.focusedApp(log) else {
                Out.emit(["type": "typer", "status": "aborted", "why": "noFocusedApplication"])
                return onDone()
            }
            // Never type into an app other than the one the caller opened for the test.
            func expected(_ pid: pid_t) -> Bool {
                guard let bundleId else { return true }
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleId
            }
            guard expected(targetPid) else {
                Out.emit(["type": "typer", "status": "aborted", "why": "frontmostNotExpectedApp",
                          "expected": bundleId ?? NSNull(), "frontmost": Snapshot.appInfo(targetPid)])
                return onDone()
            }
            Out.emit(["type": "typer", "status": "start", "target": Snapshot.appInfo(targetPid),
                      "chars": text.count, "intervalMs": intervalMs])

            func post(_ key: CGKeyCode, flags: CGEventFlags = [], unicode: [UniChar]? = nil) {
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
                    ev.flags = flags
                    if var u = unicode { ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u) }
                    ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                    ev.post(tap: .cghidEventTap)
                }
            }

            if gotoEnd {
                post(125, flags: .maskCommand) // Cmd+Down: end of document
                Thread.sleep(forTimeInterval: 0.3)
            }
            var typed = 0
            for ch in text {
                let check = CallLog()
                guard let (_, pid) = Snapshot.focusedApp(check), pid == targetPid, expected(pid) else {
                    Out.emit(["type": "typer", "status": "aborted", "why": "focusLeftTargetApp", "typed": typed])
                    return onDone()
                }
                if ch == "\n" { post(36) } else { post(0, unicode: Array(String(ch).utf16)) }
                typed += 1
                Thread.sleep(forTimeInterval: Double(intervalMs) / 1000)
            }
            Out.emit(["type": "typer", "status": "done", "typed": typed])
            onDone()
        }
    }
}
