import ApplicationServices
import Carbon
import Foundation

enum KeyAction: Equatable {
    case acceptWord
    case acceptAll
    case dismiss
    /// Option+Tab: the user wants a real Tab even though a suggestion is showing.
    case passTab
    /// Word alternatives (D50): Option+1 to Option+3 take that alternative's next word.
    case acceptAlternative(Int)
    /// Option+0: show the alternatives card now (asking the core if none came), or close it.
    case showAlternatives
    /// Esc over the alternatives card: it closes; the suggestion stays.
    case closeAlternatives
}

/// Two session event taps on one dedicated thread (Cotabby's design):
/// - a permanent listen-only tap that notices typing and can never stall input;
/// - a consuming tap that is enabled only while a suggestion is visible and swallows
///   Tab (next word), the key above Tab (everything) and Esc (dismiss, unless the user chose
///   to leave Esc alone: `escBehavior`); with word alternatives on (`picker`), Option+0 and,
///   while their card shows, Option+1 to Option+3 and Esc (which then closes only the card).
/// Callbacks never block and never call Accessibility.
final class KeyTap {
    /// Tap thread: the user pressed a key (not one of ours); its key code.
    var onKeyDown: ((Int64) -> Void)?
    /// Tap thread: a suggestion key was consumed.
    var onAction: ((KeyAction) -> Void)?

    private var listenPort: CFMachPort?
    private var activePort: CFMachPort?
    private var thread: Thread?
    private let lock = NSLock()
    private var visible = false
    /// Paused (`stop`): both taps off, and a timeout does not turn the listen tap back on.
    private var stopped = false
    private var disableGeneration = 0
    /// Key codes whose keyDown we swallowed; their keyUp is swallowed too.
    private var swallowedUps = Set<Int64>()

    private let tabKey: Int64 = 48
    let escKey: Int64 = 53
    /// The number row's 0, 1, 2 and 3 (kVK_ANSI_0…3), whatever they type on the layout.
    private let digitKeys: [Int64: Int] = [29: 0, 18: 1, 19: 2, 20: 3]
    /// The physical key above Tab: ` on ANSI keyboards, § on ISO.
    let acceptAllKey: Int64 = Int(KBGetLayoutType(Int16(LMGetKbdType()))) == Int(kKeyboardISO) ? 10 : 50

    private var isVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return visible
    }

    /// The word alternatives card's keys (D50).
    struct Picker: Equatable {
        /// Option+0 is taken: alternatives are on and the suggestion is the model's own text.
        var onDemand = false
        /// The card is up, with `items` alternatives for Option+1 to Option+`items`.
        var card = false
        var items = 0
    }

    private var _picker = Picker()
    /// Which picker keys to take. Any thread.
    var picker: Picker {
        get { lock.lock(); defer { lock.unlock() }; return _picker }
        set { lock.lock(); _picker = newValue; lock.unlock() }
    }

    private var _escBehavior = EscBehavior.pauseField
    /// What Esc does over a suggestion (Settings ▸ Typing). Any thread.
    var escBehavior: EscBehavior {
        get { lock.lock(); defer { lock.unlock() }; return _escBehavior }
        set { lock.lock(); _escBehavior = newValue; lock.unlock() }
    }

    /// Creates the taps, or after `stop` turns the listen tap back on. Returns false if the
    /// taps could not be created (no Accessibility grant). Main thread.
    func start() -> Bool {
        if thread != nil {
            lock.lock(); stopped = false; lock.unlock()
            if let p = listenPort { CGEvent.tapEnable(tap: p, enable: true) }
            return listenPort != nil && activePort != nil
        }
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let thread = Thread { [unowned self] in
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let keys = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
            self.listenPort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                                eventsOfInterest: keys, callback: KeyTap.listenCallback, userInfo: refcon)
            self.activePort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                                eventsOfInterest: keys, callback: KeyTap.activeCallback, userInfo: refcon)
            ok = self.listenPort != nil && self.activePort != nil
            for port in [self.listenPort, self.activePort].compactMap({ $0 }) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            }
            if let p = self.listenPort { CGEvent.tapEnable(tap: p, enable: true) }
            if let p = self.activePort { CGEvent.tapEnable(tap: p, enable: false) }
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        thread.name = "foretype.keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        return ok
    }

    /// Turns both taps off: macOS delivers no key events to Foretype until `start`. Main thread.
    func stop() {
        lock.lock()
        stopped = true
        visible = false
        _picker = Picker()
        disableGeneration += 1
        lock.unlock()
        for port in [listenPort, activePort].compactMap({ $0 }) { CGEvent.tapEnable(tap: port, enable: false) }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Main thread. Enabling is immediate; disabling waits 50 ms so the last synthetic
    /// keystroke of an accept drains through the tap first.
    func setSuggestionVisible(_ v: Bool) {
        lock.lock()
        visible = v && !stopped
        disableGeneration += 1
        let gen = disableGeneration
        lock.unlock()
        guard let port = activePort, !isStopped else { return }
        if v {
            CGEvent.tapEnable(tap: port, enable: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillHidden = !self.visible && gen == self.disableGeneration
                self.lock.unlock()
                if stillHidden { CGEvent.tapEnable(tap: port, enable: false) }
            }
        }
    }

    private static let listenCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !me.isStopped, let p = me.listenPort { CGEvent.tapEnable(tap: p, enable: true) }
        } else if type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != Inserter.marker {
            me.onKeyDown?(event.getIntegerValueField(.keyboardEventKeycode))
        }
        return Unmanaged.passUnretained(event)
    }

    private static let activeCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if me.isVisible, let p = me.activePort { CGEvent.tapEnable(tap: p, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Inserter.marker {
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            return me.swallowedUps.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, me.isVisible else { return Unmanaged.passUnretained(event) }
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let picker = me.picker
        let action: KeyAction?
        switch (code, mods) {
        case (me.tabKey, []): action = .acceptWord
        case (me.tabKey, [.maskAlternate]): action = .passTab
        case (me.acceptAllKey, []): action = .acceptAll
        case (me.escKey, []) where EscState.consumes(me.escBehavior, suggestionVisible: true):
            action = picker.card ? .closeAlternatives : .dismiss
        case (_, [.maskAlternate]) where me.digitKeys[code] != nil:
            let n = me.digitKeys[code]!
            if n == 0 {
                action = picker.onDemand ? .showAlternatives : nil
            } else {
                action = picker.card && n <= picker.items ? .acceptAlternative(n) : nil
            }
        default: action = nil
        }
        guard let action else { return Unmanaged.passUnretained(event) }
        me.swallowedUps.insert(code)
        me.onAction?(action)
        return nil
    }
}
