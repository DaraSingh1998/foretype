import AppKit

/// Wires the pieces together:
/// FocusTracker (AX thread) -> core -> events (main) -> GhostPanel + KeyTap -> Inserter.
final class Controller {
    let engine: EngineBridge
    let settings: AppSettings
    let tracker = FocusTracker()
    let keys = KeyTap()
    let panel = GhostPanel()
    let screen = ScreenContextProvider()
    let hotkeys = Hotkeys()
    let power = PowerMonitor()
    var onStatus: ((String, String) -> Void)?
    /// Compatibility rules by bundle ID (looked up once per app).
    private var rules: [String: [String: Any]] = [:]
    /// Field and line the user forced suggestions in (Ctrl + key above Tab). Force ends when
    /// focus moves or the caret leaves that line (in a terminal the whole window is one
    /// field, so it must not outlive the command being typed).
    private var forcedField: UInt64 = 0
    private var forcedLine = ""
    /// Apps snoozed with Ctrl+Opt+Cmd + key above Tab, and until when.
    private(set) var snoozed: [String: Date] = [:]

    private let lock = NSLock()
    private var latest = FieldSnapshot()

    init(engine: EngineBridge, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    /// Returns false if the event taps could not be created (no Accessibility grant).
    func start() -> Bool {
        engine.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.handle(ev) } }
        tracker.primeKind = { [weak engine] bundle in engine?.compatRule(bundle)["prime"] as? String }
        tracker.onlyApps = Set(settings.onlyApps)
        tracker.onSnapshot = { [weak self] snap in self?.arrived(snap) }
        tracker.onFocusChange = { [weak self] snap in self?.engine.warm(snap) }
        screen.enabled = settings.useScreenContext
        screen.onUpdate = { [weak self] fieldKey, text in self?.screenTextArrived(fieldKey, text) }
        keys.onKeyDown = { [weak self] in self?.tracker.keyDown() }
        keys.onAction = { [weak self] action in DispatchQueue.main.async { self?.perform(action) } }
        hotkeys.onAction = { [weak self] action in self?.hotkey(action) }
        hotkeys.register(keyAboveTab: UInt32(keys.acceptAllKey))
        power.onChange = { [weak self] _ in self?.applySettings() }
        power.start()
        engine.configure(coreSettingsJSON())
        let ok = keys.start()
        tracker.start()
        return ok
    }

    private var latestSnapshot: FieldSnapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private func rule(_ bundleId: String) -> [String: Any] {
        lock.lock()
        if let r = rules[bundleId] { lock.unlock(); return r }
        lock.unlock()
        let r = engine.compatRule(bundleId)
        lock.lock(); rules[bundleId] = r; lock.unlock()
        return r
    }

    private func isSnoozed(_ bundleId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = snoozed[bundleId] else { return false }
        if until > Date() { return true }
        snoozed[bundleId] = nil
        return false
    }

    /// AX thread.
    private func arrived(_ snap: FieldSnapshot) {
        var s = snap
        s.screenContext = screen.text(for: s.fieldKey)
        lock.lock()
        let line = s.textBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if forcedField != 0, forcedField != s.fieldKey || !line.hasPrefix(forcedLine) { forcedField = 0 }
        s.force = forcedField != 0
        latest = s
        lock.unlock()
        if isSnoozed(s.bundleId) {
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return
        }
        engine.submit(s)
        screen.note(.init(fieldKey: s.fieldKey, pid: s.pid, windowFrame: s.windowFrame, fieldFrame: s.frame),
                    skip: !screenContextAllowed(s))
    }

    /// No screen capture for secure fields, non-text focus, or apps where suggestions are off.
    private func screenContextAllowed(_ s: FieldSnapshot) -> Bool {
        guard !s.secureInput, ["AXTextArea", "AXTextField", "AXComboBox"].contains(s.role),
              s.subrole != "AXSecureTextField", !s.bundleId.isEmpty else { return false }
        let only = settings.onlyApps
        if !only.isEmpty, !only.contains(s.bundleId) { return false }
        if settings.disabledApps.contains(s.bundleId) { return false }
        let off = (rule(s.bundleId)["disabled"] as? Bool) ?? false
        return !off || s.force || settings.enabledApps.contains(s.bundleId)
    }

    /// Screen queue: fresh OCR for a field. Prefill the new header right away so the next
    /// keystroke does not pay for it.
    private func screenTextArrived(_ fieldKey: UInt64, _ text: String) {
        lock.lock()
        guard latest.fieldKey == fieldKey, latest.screenContext != text else { lock.unlock(); return }
        latest.screenContext = text
        let snap = latest
        lock.unlock()
        engine.warm(snap)
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case let .suggestion(revision, text, source, ms):
            let snap = latestSnapshot
            guard revision == snap.revision else { return }
            if text.isEmpty {
                hide()
            } else {
                panel.show(text: text, caret: snap.caret, frame: snap.frame, font: snap.font)
                keys.setSuggestionVisible(panel.isVisible)
            }
            if Log.enabled, source != "pending" {
                let caret = snap.caret.map { "\($0.strategy) \(Int($0.rect.minX)),\(Int($0.rect.minY)) h\(Int($0.rect.height))" } ?? "none"
                Log.debug("rev \(revision) \(source)\(ms.map { String(format: " %.0fms", $0) } ?? "") \(snap.appName) caret=\(caret) -> \(text.debugDescription)")
            }
        case let .status(state, detail):
            Log.debug("engine \(state): \(detail)")
            onStatus?(state, detail)
        }
    }

    func hide() {
        panel.hide()
        keys.setSuggestionVisible(false)
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case .acceptWord, .acceptAll:
            guard let r = engine.accept(all: action == .acceptAll), !r.insert.isEmpty else {
                // The suggestion went stale between the key press and now: give the key back.
                hide()
                Inserter.press(key: action == .acceptWord ? 48 : CGKeyCode(keys.acceptAllKey))
                return
            }
            let strategy = insertionStrategy(for: latestSnapshot.bundleId)
            Inserter.insert(r.insert, strategy: strategy)
            Log.debug("accept \(action == .acceptAll ? "all" : "word") via \(strategy.rawValue) \(r.insert.debugDescription)")
            if r.remaining.isEmpty {
                hide()
            } else {
                panel.advance(inserted: r.insert, remaining: r.remaining)
                keys.setSuggestionVisible(panel.isVisible)
            }
        case .dismiss:
            let snap = latestSnapshot
            engine.dismiss(fieldKey: snap.fieldKey, textBefore: snap.textBefore)
            hide()
        case .passTab:
            hide()
            Inserter.press(key: 48)
        }
    }

    /// Per-app insertion from the compatibility database; FORETYPE_INSERTION overrides it
    /// for testing.
    private func insertionStrategy(for bundleId: String) -> InsertionStrategy {
        if let env = ProcessInfo.processInfo.environment["FORETYPE_INSERTION"], let s = InsertionStrategy(rawValue: env) {
            return s
        }
        return (rule(bundleId)["insertion"] as? String).flatMap(InsertionStrategy.init(rawValue:)) ?? .keystrokes
    }

    /// Main thread.
    private func hotkey(_ action: Hotkeys.Action) {
        let snap = latestSnapshot
        switch action {
        case .forceSuggest:
            guard snap.fieldKey != 0 else { return }
            let line = snap.textBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            lock.lock(); forcedField = snap.fieldKey; forcedLine = line; snoozed[snap.bundleId] = nil; lock.unlock()
            Log.debug("force suggestions in \(snap.appName)")
            tracker.forceRead()
        case .snoozeApp:
            guard !snap.bundleId.isEmpty else { return }
            lock.lock(); snoozed[snap.bundleId] = Date().addingTimeInterval(300); lock.unlock()
            Log.debug("snoozed \(snap.appName) for 5 minutes")
            hide()
        }
    }

    func unsnooze(_ bundleId: String) {
        lock.lock(); snoozed[bundleId] = nil; lock.unlock()
    }

    /// Settings plus runtime state (battery debounce) as the core's JSON.
    private func coreSettingsJSON() -> String {
        var d = settings.coreDict
        d["debounce_ms"] = power.onBattery ? 80 : 0
        // Prefetching roughly doubles generated tokens; keep it for mains power.
        d["prefetch"] = !power.onBattery
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    func applySettings() {
        screen.enabled = settings.useScreenContext
        engine.configure(coreSettingsJSON())
        hide()
    }

    func shutdown() {
        hide()
        tracker.restorePrimedApps()
        engine.shutdown()
    }
}
