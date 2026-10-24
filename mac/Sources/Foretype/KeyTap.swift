import ApplicationServices
import Carbon
import Foundation

enum KeyAction {
    case acceptWord
    case acceptAll
    case dismiss
    /// Option+Tab: the user wants a real Tab even though a suggestion is showing.
    case passTab
}

/// Two session event taps on one dedicated thread (Cotabby's design):
/// - a permanent listen-only tap that notices typing and can never stall input;
/// - a consuming tap that is enabled only while a suggestion is visible and swallows
///   Tab (next word), the key above Tab (everything) and Esc (dismiss, unless the user chose
///   to leave Esc alone: `escBehavior`).
/// Callbacks never block and never call Accessibility.
final class KeyTap {
    /// Tap thread: the user pressed a key (not one of ours).
    var onKeyDown: (() -> Void)?
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
    private let escKey: Int64 = 53
    /// The physical key above Tab: ` on ANSI keyboards, § on ISO.
    let acceptAllKey: Int64 = Int(KBGetLayoutType(Int16(LMGetKbdType()))) == Int(kKeyboardISO) ? 10 : 50

    private var isVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return visible
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
            me.onKeyDown?()
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
        let action: KeyAction?
        switch (code, mods) {
        case (me.tabKey, []): action = .acceptWord
        case (me.tabKey, [.maskAlternate]): action = .passTab
        case (me.acceptAllKey, []): action = .acceptAll
        case (me.escKey, []) where EscState.consumes(me.escBehavior, suggestionVisible: true): action = .dismiss
        default: action = nil
        }
        guard let action else { return Unmanaged.passUnretained(event) }
        me.swallowedUps.insert(code)
        me.onAction?(action)
        return nil
    }
}
