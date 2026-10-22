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
    /// The page's URL when the field is in a web view (from the enclosing AXWebArea).
    var url = ""
    /// The field's accessible label or placeholder (aria-label in web and Electron apps).
    var fieldDescription = ""
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
    /// The previous character's edge when only the field-frame check rejected it (no caret).
    var edgeOutsideFrame: CGRect?
    var font: NSFont?
    /// OCR of the focused window near the field, filled in by the controller.
    var screenContext = ""
    /// The user asked for suggestions here with the force hotkey.
    var force = false
    /// Spell checker verdicts, filled in by the controller (`Speller`).
    var spellFragment = ""
    var spellWord = ""
    var spellCorrection = ""

    /// The JSON shape the core's `Snapshot` expects.
    func coreJSON() -> String {
        let o: [String: Any] = [
            "revision": revision, "field_key": fieldKey, "bundle_id": bundleId, "app_name": appName,
            "window_title": windowTitle, "url": url, "description": fieldDescription, "role": role, "subrole": subrole,
            "role_description": roleDescription, "text_before": textBefore, "text_after": textAfter,
            "selection_len": selectionLength, "marked_len": markedLength, "secure_input": secureInput,
            "field_width": Double(frame?.width ?? 0), "field_height": Double(frame?.height ?? 0),
            "screen_context": screenContext, "force": force,
            "spell_fragment": spellFragment, "spell_word": spellWord, "spell_correction": spellCorrection,
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
    /// FORETYPE_ONLY_APPS: apps (pid, bundle ID) it rejects are never read or primed.
    var onlyAppsAllow: ((pid_t, String) -> Bool)?

    /// Text window before the caret, in UTF-16 units; its start moves in aligned steps so
    /// the core's prompt prefix stays byte-stable.
    private let windowSize = 3000
    private let windowAlign = 1024

    private var runLoop: CFRunLoop!
    private var thread: Thread?
    /// Main thread: the app-activation observer, present while tracking.
    private var activation: NSObjectProtocol?
    /// AX thread: tracking (between `start` and `stop`).
    private var running = false
    private var pollTimer: CFRunLoopTimer?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var observedApp: AXUIElement?
    private var observedElement: AXUIElement?
    private var frontPid: pid_t = 0
    private var lastSignature: [AnyHashable] = []
    private var lastFieldKey: UInt64 = 0
    /// The last snapshot emitted, and whether one that looked like a lagging caret is held.
    private var lastEmitted = FieldSnapshot()
    private var heldLagging = false
    private var revision: UInt64 = 0
    private var readPending = false
    private var fontCache: (key: UInt64, line: Int, caret: Int, count: Int, typed: Int, font: NSFont?) = (0, -1, 0, 0, 0, nil)
    private var titleCache: (pid: pid_t, title: String, frame: CGRect?) = (0, "", nil)
    private var fieldInfoCache: (key: UInt64, description: String, url: String, web: Bool) = (0, "", "", false)
    /// Characters typed after the caret arrives during which its font is read again (above).
    private static let fontSettleChars = 6
    private static let forceMarkers = ProcessInfo.processInfo.environment["FORETYPE_TEXT_MARKERS"] == "1"
    private var primed: [pid_t: (manual: Bool?, enhanced: Bool?)] = [:]
    private var primedAt: [pid_t: CFAbsoluteTime] = [:]
    private var lastPrimeCheck: CFAbsoluteTime = 0
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    /// Starts tracking, or resumes it after `stop`, with a fresh read of the focused field.
    /// Main thread.
    func start() {
        if thread == nil {
            let ready = DispatchSemaphore(value: 0)
            let thread = Thread { [unowned self] in
                self.runLoop = CFRunLoopGetCurrent()
                AXUIElementSetMessagingTimeout(AX.systemWide, 0.08)
                // A source that never fires: the run loop keeps running while stopped, with no
                // timer or observer in it.
                var context = CFRunLoopSourceContext()
                CFRunLoopAddSource(self.runLoop, CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
                ready.signal()
                CFRunLoopRun()
            }
            thread.name = "foretype.ax"
            thread.qualityOfService = .userInteractive
            thread.start()
            ready.wait()
            self.thread = thread
        }
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self?.perform { self?.activate(pid) }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        perform {
            self.running = true
            self.lastSignature = []
            self.lastFieldKey = 0
            self.heldLagging = false
            self.schedulePoll()
            if let front { self.activate(front) }
        }
        Log.debug("tracker started")
    }

    /// Stops all reading until `start`: no poll, no AXObservers, no activation handling (the
    /// thread stays, asleep). Main thread.
    func stop() {
        guard let activation else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(activation)
        self.activation = nil
        perform {
            self.running = false
            if let t = self.pollTimer { CFRunLoopTimerInvalidate(t) }
            self.pollTimer = nil
            self.detachObserver()
        }
        Log.debug("tracker stopped")
    }

    // MARK: - Scheduling on the AX thread

    /// Does nothing before the first `start` (no thread yet).
    func perform(_ block: @escaping () -> Void) {
        guard runLoop != nil else { return }
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
        pollTimer = timer
    }

    /// From the key tap thread: the user typed something; re-read shortly after.
    func keyDown() {
        perform(afterMs: 8) { self.requestRead() }
        perform(afterMs: 45) { self.requestRead() }
    }

    /// Emits a fresh snapshot of the focused field even if nothing changed.
    func forceRead() {
        perform {
            self.lastSignature = []
            self.read(reason: "force")
        }
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
        guard running else { return }
        frontPid = pid
        guard pid != ownPid else { return }
        if pid != observedPid {
            detachObserver()
            attachObserver(pid)
            if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { primeIfNeeded(pid, bundle) }
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
    ///
    /// Chrome turns on web content 2 s after `AXEnhancedUserInterface` is set, and a set or
    /// clear inside those 2 s restarts or cancels the wait (a debounce in
    /// `chrome_browser_application_mac.mm`). So the flag is set once per process and kept
    /// until quit, and a fresh Chrome shows its focused field about 2 s after activation.
    /// Nothing else an outside client does (an AXObserver, walking or hit-testing the tree,
    /// a focus change in the page) turns it on, and setting it returns `notImplemented` even
    /// when it works. Chrome often clears the flag again just after it activates, so it is
    /// checked once 0.5 s after each set. It is also checked while the app shows no focused
    /// element, and set again if it reads false 3 s after our set (the request was lost, say
    /// while the app was launching, or someone cleared it). A read that times out is no
    /// reason to set it again.
    private func primeIfNeeded(_ pid: pid_t, _ bundle: String, after minAge: Double = 3) {
        guard running, let kind = primeKind?(bundle), onlyAppsAllow?(pid, bundle) ?? true,
              kind == "electron" || kind == "chromium" && !NSWorkspace.shared.isVoiceOverEnabled else { return }
        let attr = kind == "electron" ? "AXManualAccessibility" : "AXEnhancedUserInterface"
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, attr as CFString, &value)
        let current = err == .success ? AX.bool(value) : nil
        if let at = primedAt[pid] {
            guard current == false, CFAbsoluteTimeGetCurrent() - at > minAge else { return }
        } else {
            guard current != true else { return }
        }
        if primed[pid] == nil {
            primed[pid] = (AX.bool(AX.copy(app, "AXManualAccessibility")), AX.bool(AX.copy(app, "AXEnhancedUserInterface")))
        }
        AX.set(app, attr, kCFBooleanTrue)
        let again = primedAt[pid] != nil
        primedAt[pid] = CFAbsoluteTimeGetCurrent()
        Log.debug("primed \(bundle) as \(kind)\(again ? " again (the flag read false)" : "")")
        if minAge > 1 { perform(afterMs: 500) { self.primeIfNeeded(pid, bundle, after: 0.4) } }
    }

    /// Puts the Chromium/Electron flags back as we found them (the enhanced flag disturbs
    /// window managers). Blocks until done.
    func restorePrimedApps() {
        guard thread != nil else { return }
        let done = DispatchSemaphore(value: 0)
        perform {
            for (pid, orig) in self.primed where NSRunningApplication(processIdentifier: pid) != nil {
                let app = AXUIElementCreateApplication(pid)
                if orig.enhanced != true { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
                if orig.manual != true { AX.set(app, "AXManualAccessibility", kCFBooleanFalse) }
            }
            self.primed.removeAll()
            self.primedAt.removeAll()
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
        // Electron updates a field's text a few milliseconds before its caret index, so the
        // letter just typed reads as text after the caret (the mid-line card would flash).
        // Such a snapshot is held once and the field read again.
        if !focusChanged, !heldLagging, FocusTracker.caretLags(s, after: lastEmitted) {
            heldLagging = true
            perform(afterMs: 15) { self.requestRead() }
            return
        }
        heldLagging = false
        lastEmitted = s
        lastSignature = sig
        lastFieldKey = s.fieldKey
        revision += 1
        s.revision = revision
        if focusChanged, !s.textBefore.isEmpty { onFocusChange?(s) }
        onSnapshot?(s)
    }

    private func read(reason: String) {
        let pid = frontPid
        // Re-reads scheduled before a stop land here too.
        guard running, pid > 0, pid != ownPid else { return }
        var snap = FieldSnapshot()
        snap.pid = pid
        snap.secureInput = IsSecureEventInputEnabled()
        let running = NSRunningApplication(processIdentifier: pid)
        snap.bundleId = running?.bundleIdentifier ?? ""
        snap.appName = running?.localizedName ?? ""
        if onlyAppsAllow?(pid, snap.bundleId) == false {
            snap.fieldKey = UInt64(UInt32(bitPattern: pid)) << 32
            return emit(snap, reason: reason)
        }

        // System-wide AXFocusedApplication always fails on macOS 27.0.1 (Phase 0), so go
        // through the frontmost pid.
        let app = observedApp ?? AXUIElementCreateApplication(pid)
        guard let el = AX.element(AX.copy(app, kAXFocusedUIElementAttribute)) else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPrimeCheck > 1 {
                lastPrimeCheck = now
                primeIfNeeded(pid, snap.bundleId)
            }
            snap.fieldKey = UInt64(UInt32(bitPattern: pid)) << 32
            return emit(snap, reason: reason)
        }
        observeElement(el)
        snap.fieldKey = (UInt64(UInt32(bitPattern: pid)) << 32) ^ UInt64(CFHash(el) & 0xFFFF_FFFF)
        snap.role = AX.string(el, kAXRoleAttribute) ?? ""
        snap.subrole = AX.string(el, kAXSubroleAttribute) ?? ""
        snap.roleDescription = AX.string(el, kAXRoleDescriptionAttribute) ?? ""
        // Read for every focused element (once each), so hints can spot pages like Google
        // Docs whose text isn't exposed.
        if fieldInfoCache.key != snap.fieldKey {
            let page = FocusTracker.webArea(el)
            fieldInfoCache = (snap.fieldKey, FocusTracker.fieldDescription(el), page.url, page.web)
        }
        snap.fieldDescription = fieldInfoCache.description
        snap.url = fieldInfoCache.url
        if titleCache.pid != pid || reason == "focus" {
            let window = AX.element(AX.copy(app, kAXFocusedWindowAttribute))
            titleCache = (pid, window.flatMap { AX.string($0, kAXTitleAttribute) } ?? "", window.flatMap { AX.frame($0) })
        }
        snap.windowTitle = titleCache.title
        snap.windowFrame = titleCache.frame
        guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(snap.role),
              snap.subrole != "AXSecureTextField" else {
            return emit(snap, reason: reason)
        }
        // Web fields whose ranges don't work: read through text markers instead
        // (FORETYPE_TEXT_MARKERS=1 forces this path for testing).
        let sel = FocusTracker.forceMarkers ? nil : AX.range(AX.copy(el, kAXSelectedTextRangeAttribute))
        guard let sel else {
            if let m = AX.viaTextMarkers(el, maxBefore: windowSize) {
                snap.textBefore = m.before
                snap.textAfter = m.after
                snap.caretIndex = m.before.utf16.count
                snap.selectionLength = m.selection
                snap.frame = AX.frame(el)
                snap.caret = m.caret.map { CaretInfo(rect: $0, strategy: "textMarker") }
                snap.font = nil
            }
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
        if fieldInfoCache.web {
            if let p = FocusTracker.paragraphValue(el, caret: caret, count: count) {
                let s = max(0, p.caret - windowSize) / windowAlign * windowAlign
                before = p.value.substring(with: NSRange(location: s, length: p.caret - s))
                after = p.value.substring(with: NSRange(location: p.caret, length: min(p.value.length - p.caret, 160)))
                snap.caretIndex = p.caret
            } else if count == 1, caret == 1, before == "\n" {
                // Chromium's empty contenteditable (`<p><br></p>`) reads as a newline with the
                // caret after it, though the caret is on the first line.
                before = ""
                after = ""
                snap.caretIndex = 0
            }
        }
        snap.textBefore = before ?? ""
        snap.textAfter = (after ?? "").components(separatedBy: CharacterSet.newlines).first ?? ""

        snap.frame = AX.frame(el)
        snap.caret = CaretResolver.resolve(el, caret: caret, frame: snap.frame, bundleId: snap.bundleId)
        if snap.caret == nil { snap.edgeOutsideFrame = CaretResolver.edgeOutsideFrame(el, caret: caret, frame: snap.frame) }
        // Fonts are expensive in Safari (~3.5 ms). Read when the caret arrives (another field or
        // line, a click, an arrow, a deletion) and again for the first few characters typed
        // there: typed text can be in other attributes than the text before it (TextEdit kept
        // typing at 12 pt after a script set the text to 20 pt), and the zoom check needs a run
        // of it. Then kept while typing goes on. A snapshot whose caret hasn't moved changes
        // nothing (Electron updates a field's text before its caret).
        let line = Int((snap.caret?.rect.minY ?? 0) / 4)
        let moved = caret - fontCache.caret
        let typed = moved > 0 && (count < 0 || count - fontCache.count == moved)
        if fontCache.key != snap.fieldKey || fontCache.line != line || (moved != 0 && !typed) {
            fontCache = (snap.fieldKey, line, caret, count, 0, CaretResolver.font(el, caret: caret, length: count))
        } else if typed {
            let font = fontCache.typed < FocusTracker.fontSettleChars ? CaretResolver.font(el, caret: caret, length: count) : fontCache.font
            fontCache = (snap.fieldKey, line, caret, count, fontCache.typed + moved, font)
        }
        snap.font = fontCache.font
        emit(snap, reason: reason)
    }

    /// Label, placeholder and title of a field (once per field).
    private static func fieldDescription(_ el: AXUIElement) -> String {
        let parts = [kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute]
            .compactMap { AX.string(el, $0) }.filter { !$0.isEmpty }
        return String(parts.joined(separator: " | ").prefix(160))
    }

    /// Text appeared after a caret that hasn't moved, with nothing else changed: the host has
    /// inserted what was typed but not yet moved its caret index.
    static func caretLags(_ s: FieldSnapshot, after prev: FieldSnapshot) -> Bool {
        s.fieldKey == prev.fieldKey && s.caretIndex == prev.caretIndex && s.textBefore == prev.textBefore
            && prev.textAfter.isEmpty && !s.textAfter.isEmpty
    }

    /// Whether the field is in a web page (any AXWebArea above it), and the page's URL: the
    /// nearest AXWebArea with a real URL (frames such as `about:blank` are skipped; at most 30
    /// levels, once per field).
    private static func webArea(_ el: AXUIElement) -> (url: String, web: Bool) {
        var node: AXUIElement? = el
        var web = false
        for _ in 0..<30 {
            guard let n = node else { break }
            if AX.string(n, kAXRoleAttribute) == "AXWebArea" {
                web = true
                if let u = AX.copy(n, kAXURLAttribute), CFGetTypeID(u) == CFURLGetTypeID() {
                    let s = (u as! URL).absoluteString
                    if s.hasPrefix("http") { return (s, true) }
                }
            }
            node = AX.element(AX.copy(n, kAXParentAttribute))
        }
        return ("", web)
    }

    /// Chromium contenteditables (chat composers in Chrome and Electron apps): `AXValue` and
    /// `AXNumberOfCharacters` have a newline between paragraphs that the ranges
    /// (`AXSelectedTextRange`, `AXStringForRange`) leave out. Read through the ranges, the
    /// paragraphs run together, and the value read at the caret's index starts one character
    /// early per paragraph above (the last letter typed shows up after the caret). When the
    /// ranges end short of the count, this maps the caret into the value (`AX.valueIndex`):
    /// the value and the caret's index in it, or nil.
    private static func paragraphValue(_ el: AXUIElement, caret: Int, count: Int) -> (value: NSString, caret: Int)? {
        guard count > 0, count <= 50_000, caret < count, AX.string(el, range: count - 1, 1) == nil,
              let value = AX.string(el, kAXValueAttribute) as NSString?, value.length == count,
              let ranged = AX.string(el, range: 0, caret),
              let i = AX.valueIndex(of: ranged, in: value as String) else { return nil }
        return (value, i)
    }
}
