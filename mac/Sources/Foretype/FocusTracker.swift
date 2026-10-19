import AppKit
import ApplicationServices
import Carbon

/// One read of the focused text field.
struct FieldSnapshot {
    var revision: UInt64 = 0
    var fieldKey: UInt64 = 0
    var pid: pid_t = 0
    var bundleId = ""
    var appName = ""
    var windowTitle = ""
    var role = ""
    var subrole = ""
    var roleDescription = ""
    var textBefore = ""
    var textAfter = ""
    var caretIndex = 0
    var selectionLength = 0
    var markedLength = 0
    var secureInput = false
    var frame: CGRect?
    var windowFrame: CGRect?
    var caret: CaretInfo?
    var font: NSFont?
    /// OCR of the focused window near the field, filled in by the controller.
    var screenContext = ""

    /// The JSON shape the core's `Snapshot` expects.
    func coreJSON() -> String {
        let o: [String: Any] = [
            "revision": revision, "field_key": fieldKey, "bundle_id": bundleId, "app_name": appName,
            "window_title": windowTitle, "role": role, "subrole": subrole,
            "role_description": roleDescription, "text_before": textBefore, "text_after": textAfter,
            "selection_len": selectionLength, "marked_len": markedLength, "secure_input": secureInput,
            "field_width": Double(frame?.width ?? 0), "field_height": Double(frame?.height ?? 0),
            "screen_context": screenContext,
        ]
        let data = try! JSONSerialization.data(withJSONObject: o)
        return String(data: data, encoding: .utf8)!
    }

    /// What makes two reads "the same" for change detection.
    var signature: [AnyHashable] {
        [fieldKey, caretIndex, selectionLength, markedLength, textBefore.utf16.count, textBefore.hashValue,
         textAfter.hashValue, role, secureInput]
    }
}

/// Tracks the focused text field on a dedicated Accessibility thread.
///
/// No single change signal is reliable across apps, so three are combined (as in Tabber):
/// AXObserver notifications, a short burst of re-reads after every keystroke, and an idle
/// poll. Reads are coalesced; a snapshot is emitted only when something changed.
final class FocusTracker {
    /// Called on the AX thread for every changed read.
    var onSnapshot: ((FieldSnapshot) -> Void)?
    /// Called on the AX thread when focus moves to a different field.
    var onFocusChange: ((FieldSnapshot) -> Void)?
    /// Returns the compatibility rule's `prime` value for a bundle ID ("chromium" | "electron").
    var primeKind: ((String) -> String?)?
    /// When non-empty, fields of other apps are never read (FORETYPE_ONLY_APPS).
    var onlyApps: Set<String> = []

    /// Text window before the caret, in UTF-16 units; its start moves in aligned steps so
    /// the core's prompt prefix stays byte-stable.
    private let windowSize = 3000
    private let windowAlign = 1024

    private var runLoop: CFRunLoop!
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var observedApp: AXUIElement?
    private var observedElement: AXUIElement?
    private var frontPid: pid_t = 0
    private var lastSignature: [AnyHashable] = []
    private var lastFieldKey: UInt64 = 0
    private var revision: UInt64 = 0
    private var readPending = false
    private var fontCache: (key: UInt64, line: Int, font: NSFont?) = (0, -1, nil)
    private var titleCache: (pid: pid_t, title: String, frame: CGRect?) = (0, "", nil)
    private var primed: [pid_t: (manual: Bool?, enhanced: Bool?)] = [:]
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            AXUIElementSetMessagingTimeout(AX.systemWide, 0.08)
            self.schedulePoll()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "foretype.ax"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self?.perform { self?.activate(pid) }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            perform { self.activate(pid) }
        }
    }

    // MARK: - Scheduling on the AX thread

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func perform(afterMs ms: Double, _ block: @escaping () -> Void) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + ms / 1000, 0, 0, 0) { _ in block() }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    private func schedulePoll() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0) { [unowned self] _ in
            self.read(reason: "poll")
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    /// From the key tap thread: the user typed something; re-read shortly after.
    func keyDown() {
        perform(afterMs: 8) { self.requestRead() }
        perform(afterMs: 45) { self.requestRead() }
    }

    /// Coalesces bursts of notifications (Safari sends ~6 per keystroke) into one read.
    private func requestRead() {
        guard !readPending else { return }
        readPending = true
        perform(afterMs: 2) {
            self.readPending = false
            self.read(reason: "change")
        }
    }

    // MARK: - Observers

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let me = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        if name == kAXFocusedUIElementChangedNotification || name == kAXFocusedWindowChangedNotification {
            me.read(reason: "focus")
        } else {
            me.requestRead()
        }
    }

    private func activate(_ pid: pid_t) {
        frontPid = pid
        guard pid != ownPid else { return }
        if pid != observedPid {
            detachObserver()
            attachObserver(pid)
            primeIfNeeded(pid)
        }
        read(reason: "focus")
    }

    private func detachObserver() {
        if let obs = observer {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedApp = nil
        observedElement = nil
        observedPid = 0
    }

    private func attachObserver(_ pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, FocusTracker.callback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                  kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedApp = app
        observedPid = pid
    }

    /// Some apps only deliver value/selection notifications to observers registered on the
    /// element itself, so follow the focused element too.
    private func observeElement(_ el: AXUIElement) {
        guard let obs = observer else { return }
        if let old = observedElement, CFEqual(old, el) { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = observedElement {
            AXObserverRemoveNotification(obs, old, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(obs, old, kAXSelectedTextChangedNotification as CFString)
        }
        AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, el, kAXSelectedTextChangedNotification as CFString, refcon)
        observedElement = el
    }

    /// Chromium and Electron build their accessibility tree lazily; ask for it.
    private func primeIfNeeded(_ pid: pid_t) {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let kind = primeKind?(bundle) else { return }
        let app = AXUIElementCreateApplication(pid)
        if primed[pid] == nil {
            primed[pid] = (AX.bool(AX.copy(app, "AXManualAccessibility")), AX.bool(AX.copy(app, "AXEnhancedUserInterface")))
        }
        if kind == "electron" {
            AX.set(app, "AXManualAccessibility", kCFBooleanTrue)
        } else if kind == "chromium", !NSWorkspace.shared.isVoiceOverEnabled,
                  AX.bool(AX.copy(app, "AXEnhancedUserInterface")) != true {
            AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue)
        }
        Log.debug("primed \(bundle) as \(kind)")
    }

    /// Puts the Chromium/Electron flags back as we found them (the enhanced flag disturbs
    /// window managers). Blocks until done.
    func restorePrimedApps() {
        let done = DispatchSemaphore(value: 0)
        perform {
            for (pid, orig) in self.primed where NSRunningApplication(processIdentifier: pid) != nil {
                let app = AXUIElementCreateApplication(pid)
                if orig.enhanced != true { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
                if orig.manual != true { AX.set(app, "AXManualAccessibility", kCFBooleanFalse) }
            }
            self.primed.removeAll()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: - Reading

    private func emit(_ snap: FieldSnapshot, reason: String) {
        var s = snap
        let sig = s.signature
        let focusChanged = s.fieldKey != lastFieldKey
        if sig == lastSignature, !focusChanged { return }
        lastSignature = sig
        lastFieldKey = s.fieldKey
        revision += 1
        s.revision = revision
        if focusChanged, !s.textBefore.isEmpty { onFocusChange?(s) }
        onSnapshot?(s)
    }

    private func read(reason: String) {
        let pid = frontPid
        guard pid > 0, pid != ownPid else { return }
        var snap = FieldSnapshot()
        snap.pid = pid
        snap.secureInput = IsSecureEventInputEnabled()
        let running = NSRunningApplication(processIdentifier: pid)
        snap.bundleId = running?.bundleIdentifier ?? ""
        snap.appName = running?.localizedName ?? ""
        if !onlyApps.isEmpty, !onlyApps.contains(snap.bundleId) {
            snap.fieldKey = UInt64(UInt32(bitPattern: pid)) << 32
            return emit(snap, reason: reason)
        }

        // System-wide AXFocusedApplication always fails on macOS 27.0.1 (Phase 0), so go
        // through the frontmost pid.
        let app = observedApp ?? AXUIElementCreateApplication(pid)
        guard let el = AX.element(AX.copy(app, kAXFocusedUIElementAttribute)) else {
            snap.fieldKey = UInt64(UInt32(bitPattern: pid)) << 32
            return emit(snap, reason: reason)
        }
        observeElement(el)
        snap.fieldKey = (UInt64(UInt32(bitPattern: pid)) << 32) ^ UInt64(CFHash(el) & 0xFFFF_FFFF)
        snap.role = AX.string(el, kAXRoleAttribute) ?? ""
        snap.subrole = AX.string(el, kAXSubroleAttribute) ?? ""
        snap.roleDescription = AX.string(el, kAXRoleDescriptionAttribute) ?? ""
        guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(snap.role),
              snap.subrole != "AXSecureTextField",
              let sel = AX.range(AX.copy(el, kAXSelectedTextRangeAttribute)) else {
            return emit(snap, reason: reason)
        }
        snap.caretIndex = sel.location
        snap.selectionLength = sel.length
        // TextEdit reports a zero-length marked range at the caret even with no IME
        // composition; only a non-empty range means composing.
        snap.markedLength = AX.range(AX.copy(el, "AXTextInputMarkedRange"))?.length ?? 0

        let count = (AX.copy(el, kAXNumberOfCharactersAttribute) as? Int) ?? -1
        let caret = sel.location
        let start = max(0, caret - windowSize) / windowAlign * windowAlign
        var before = AX.string(el, range: start, caret - start)
        var after = count > caret ? AX.string(el, range: caret, min(count - caret, 160)) : ""
        if before == nil || after == nil, let value = AX.string(el, kAXValueAttribute) as NSString? {
            let len = value.length
            if caret <= len {
                before = before ?? value.substring(with: NSRange(location: start, length: caret - start))
                after = after ?? value.substring(with: NSRange(location: caret, length: min(len - caret, 160)))
            }
        }
        snap.textBefore = before ?? ""
        snap.textAfter = (after ?? "").components(separatedBy: CharacterSet.newlines).first ?? ""

        snap.frame = AX.frame(el)
        snap.caret = CaretResolver.resolve(el, caret: caret, frame: snap.frame, bundleId: snap.bundleId)
        // Fonts are expensive in Safari (~3.5 ms): read once per field and line.
        let line = Int((snap.caret?.rect.minY ?? 0) / 4)
        if fontCache.key != snap.fieldKey || fontCache.line != line {
            fontCache = (snap.fieldKey, line, CaretResolver.font(el, caret: caret, length: count))
        }
        snap.font = fontCache.font
        if titleCache.pid != pid || reason == "focus" {
            let window = AX.element(AX.copy(app, kAXFocusedWindowAttribute))
            titleCache = (pid, window.flatMap { AX.string($0, kAXTitleAttribute) } ?? "", window.flatMap { AX.frame($0) })
        }
        snap.windowTitle = titleCache.title
        snap.windowFrame = titleCache.frame
        emit(snap, reason: reason)
    }
}
