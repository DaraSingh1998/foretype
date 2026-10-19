import ApplicationServices
import Foundation

/// Types accepted text into the focused app as synthetic Unicode keystrokes, so the host
/// sees ordinary typing (undo, styling and web input events behave naturally).
///
/// Details from espanso and Tabber: at most 20 UTF-16 units per event, virtual key 0
/// (pages read 49/52 as Space/Enter and Chrome drops unassigned codes), real Return for
/// newlines, and posting at the annotated session tap so session taps (ours included)
/// skip the events. Every event carries `marker` in its user data.
enum Inserter {
    static let marker: Int64 = 0x4654_5950 // "FTYP"

    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = marker
        return s
    }()

    private static func post(key: CGKeyCode, unicode: [UniChar]? = nil) {
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            ev.flags = []
            if var u = unicode {
                ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            }
            ev.setIntegerValueField(.eventSourceUserData, value: marker)
            ev.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    static func type(_ text: String) {
        var chunk: [UniChar] = []
        func flush() {
            if !chunk.isEmpty { post(key: 0, unicode: chunk) }
            chunk.removeAll()
        }
        for ch in text {
            if ch == "\n" || ch == "\r\n" {
                flush()
                post(key: 36)
                continue
            }
            let units = Array(String(ch).utf16)
            if chunk.count + units.count > 20 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }

    /// Re-sends a plain key press (used to give back a key the tap swallowed).
    static func press(key: CGKeyCode) {
        post(key: key)
    }
}
