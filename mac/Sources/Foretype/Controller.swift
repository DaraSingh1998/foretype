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
    var onStatus: ((String, String) -> Void)?
    /// Bundle IDs whose compatibility rule turns suggestions off by default.
    private var offByDefault: [String: Bool] = [:]

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
        let ok = keys.start()
        tracker.start()
        return ok
    }

    private var latestSnapshot: FieldSnapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// AX thread.
    private func arrived(_ snap: FieldSnapshot) {
        var s = snap
        s.screenContext = screen.text(for: s.fieldKey)
        lock.lock()
        latest = s
        lock.unlock()
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
        lock.lock()
        let cached = offByDefault[s.bundleId]
        lock.unlock()
        let off = cached ?? ((engine.compatRule(s.bundleId)["disabled"] as? Bool) ?? false)
        if cached == nil {
            lock.lock(); offByDefault[s.bundleId] = off; lock.unlock()
        }
        return !off || settings.enabledApps.contains(s.bundleId)
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
            Inserter.type(r.insert)
            Log.debug("accept \(action == .acceptAll ? "all" : "word") \(r.insert.debugDescription)")
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

    func applySettings() {
        screen.enabled = settings.useScreenContext
        engine.configure(settings.coreJSON())
        hide()
    }

    func shutdown() {
        hide()
        tracker.restorePrimedApps()
        engine.shutdown()
    }
}
