import AppKit

/// Wires the pieces together:
/// FocusTracker (AX thread) -> core -> events (main) -> GhostPanel + KeyTap -> Inserter.
final class Controller {
    private var _engine: EngineBridge
    private let engineLock = NSLock()
    /// The current engine; replaced when the user switches model or server.
    var engine: EngineBridge {
        engineLock.lock(); defer { engineLock.unlock() }
        return _engine
    }
    let settings: AppSettings
    /// Words-saved counts, updated on every accept (counts only, no text).
    let stats: UsageStats
    let tracker = FocusTracker()
    let keys = KeyTap()
    let panel = GhostPanel()
    let screen = ScreenContextProvider()
    let speller = Speller()
    let pixelCaret = PixelCaretProvider()
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
    /// Main thread: the suggestion on screen and its field, to move it when the pixel caret
    /// locator reports a new position. `detail` is set for a fill of one of the user's details.
    private var shown: (fieldKey: UInt64, text: String, detail: AboutYou.Field?)?

    /// The user's details for the core (`AboutYou.coreJSON`); sent again to a new engine.
    var detailsJSON = "{}" {
        didSet { engine.setDetails(detailsJSON) }
    }

    init(engine: EngineBridge, settings: AppSettings, stats: UsageStats) {
        _engine = engine
        self.settings = settings
        self.stats = stats
    }

    /// Swaps in a new engine (model or server changed) without restarting capture.
    func replaceEngine(_ new: EngineBridge) {
        new.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.handle(ev) } }
        engineLock.lock()
        let old = _engine
        _engine = new
        engineLock.unlock()
        lock.lock(); rules.removeAll(); lock.unlock()
        old.onEvent = nil
        new.configure(coreSettingsJSON())
        new.setDetails(detailsJSON)
        hide()
        DispatchQueue.global(qos: .utility).async { old.shutdown() }
    }

    /// Returns false if the event taps could not be created (no Accessibility grant).
    func start() -> Bool {
        engine.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.handle(ev) } }
        tracker.primeKind = { [weak self] bundle in self?.engine.compatRule(bundle)["prime"] as? String }
        tracker.onlyAppsAllow = { [settings] pid, bundle in settings.onlyAppsAllow(pid: pid, bundleId: bundle) }
        tracker.onSnapshot = { [weak self] snap in self?.arrived(snap) }
        tracker.onFocusChange = { [weak self] snap in self?.engine.warm(snap) }
        screen.enabled = settings.useScreenContext
        screen.onUpdate = { [weak self] fieldKey, text in self?.screenTextArrived(fieldKey, text) }
        pixelCaret.onUpdate = { [weak self] fieldKey in self?.pixelCaretArrived(fieldKey) }
        keys.onKeyDown = { [weak self] in self?.tracker.keyDown() }
        keys.onAction = { [weak self] action in DispatchQueue.main.async { self?.perform(action) } }
        hotkeys.onAction = { [weak self] action in self?.hotkey(action) }
        hotkeys.register(keyAboveTab: UInt32(keys.acceptAllKey))
        power.onChange = { [weak self] _ in self?.applySettings() }
        power.start()
        engine.configure(coreSettingsJSON())
        engine.setDetails(detailsJSON)
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
        let pixel = pixelTarget(s)
        if let pixel { s.caret = pixelCaret.caret(for: pixel) }
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
        // Never hand a secure field's text to the spell checker.
        if !s.secureInput, s.subrole != "AXSecureTextField" { speller.annotate(&s) }
        hintIfNeeded(s)
        engine.submit(s)
        screen.note(.init(fieldKey: s.fieldKey, pid: s.pid, windowFrame: s.windowFrame, fieldFrame: s.frame),
                    skip: !screenContextAllowed(s))
        if let pixel { pixelCaret.note(pixel) }
    }

    /// The pixel caret locator's view of a snapshot, when it should place the ghost text:
    /// the app's rule says so (`"caret": "pixel"`), or Accessibility gave no caret for a
    /// field with text. Never for fields where screen context is not allowed, or with
    /// screen context off (it captures the screen too).
    private func pixelTarget(_ s: FieldSnapshot) -> PixelCaretProvider.Target? {
        guard settings.useScreenContext, s.fieldKey & 0xFFFF_FFFF != 0, !s.textBefore.isEmpty,
              s.selectionLength == 0, s.markedLength == 0, screenContextAllowed(s),
              ScreenContextProvider.hasPermission else { return nil }
        // FORETYPE_CARET=pixel|ax overrides the app's rule (testing).
        let mode = ProcessInfo.processInfo.environment["FORETYPE_CARET"] ?? rule(s.bundleId)["caret"] as? String
        guard mode != "ax", s.caret == nil || mode == "pixel" else { return nil }
        let line = s.textBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return .init(fieldKey: s.fieldKey, pid: s.pid, bundleId: s.bundleId, windowFrame: s.windowFrame, fieldFrame: s.frame,
                     lineStart: s.caretIndex - line.utf16.count, lineText: line, font: s.font,
                     edgeOutsideFrame: s.edgeOutsideFrame)
    }

    /// Caret queue: the locator found or corrected the caret; move a visible suggestion.
    private func pixelCaretArrived(_ fieldKey: UInt64) {
        lock.lock()
        let snap = latest
        lock.unlock()
        guard snap.fieldKey == fieldKey, let t = pixelTarget(snap) else { return }
        let caret = pixelCaret.caret(for: t)
        lock.lock()
        guard latest.revision == snap.revision else { lock.unlock(); return }
        latest.caret = caret
        let updated = latest
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, let shown = self.shown, shown.fieldKey == fieldKey, self.panel.isVisible,
                  self.latestSnapshot.revision == updated.revision else { return }
            self.panel.show(text: shown.text, caret: updated.caret, frame: self.panelFrame(updated), font: updated.font,
                            tag: shown.detail?.tag)
        }
    }

    /// The field frame's right edge bounds the ghost text, unless the caret lies left or right
    /// of the field (a frame reported elsewhere); then the window's does. LibreOffice's
    /// paragraph frames are about 100 pt too high but horizontally right.
    private func panelFrame(_ s: FieldSnapshot) -> CGRect? {
        guard let c = s.caret, let f = s.frame, c.rect.minX < f.minX - 4 || c.rect.minX > f.maxX + 4 else { return s.frame }
        return s.windowFrame
    }

    /// One-time tips (per Mac) for places that need a setting changed before Foretype can
    /// work there. AX thread.
    private func hintIfNeeded(_ s: FieldSnapshot) {
        let textRole = ["AXTextArea", "AXTextField", "AXComboBox"].contains(s.role)
        let hint: (key: String, text: String)?
        if s.url.contains("docs.google.com/document"), !textRole || s.textBefore.isEmpty {
            hint = ("googleDocs", L("Google Docs hides its text from other apps. Turn on Tools \u{25B8} Accessibility \u{25B8} Screen reader support (\u{2318}\u{2325}Z) to get suggestions."))
        } else if ["company.thebrowser.Browser", "company.thebrowser.dia"].contains(s.bundleId), textRole, s.caret == nil,
                  !s.textBefore.isEmpty {
            hint = ("textMetrics.\(s.bundleId)", L("For ghost text at the caret in %@, open chrome://accessibility and turn on Text Metrics.", s.appName))
        } else {
            hint = nil
        }
        guard let hint, !UserDefaults.standard.bool(forKey: "hintShown.\(hint.key)"),
              let rect = s.frame ?? s.windowFrame else { return }
        UserDefaults.standard.set(true, forKey: "hintShown.\(hint.key)")
        Log.debug("hint \(hint.key)")
        DispatchQueue.main.async { [weak self] in self?.panel.showHint(hint.text, near: rect) }
    }

    /// No screen capture for secure fields, non-text focus, or apps where suggestions are off.
    private func screenContextAllowed(_ s: FieldSnapshot) -> Bool {
        guard !s.secureInput, ["AXTextArea", "AXTextField", "AXComboBox"].contains(s.role),
              s.subrole != "AXSecureTextField", !s.bundleId.isEmpty else { return false }
        if !settings.onlyAppsAllow(pid: s.pid, bundleId: s.bundleId) { return false }
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
        case let .suggestion(revision, text, source, ms, replace, label):
            let snap = latestSnapshot
            guard revision == snap.revision else { return }
            // One of the user's own details: tagged on screen, never written to the log.
            let detail = source == "details" ? AboutYou.Field(rawValue: label) : nil
            if text.isEmpty {
                hide()
            } else {
                // A replacement shows what Tab turns the typed text into.
                let display = replace.isEmpty ? text
                    : source == "emoji" ? " \(text) \(label)" : " → \(text.trimmingCharacters(in: .whitespaces))"
                let midLine = !(snap.textAfter.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
                    .trimmingCharacters(in: .whitespaces).isEmpty
                panel.show(text: display, caret: snap.caret, frame: panelFrame(snap), font: snap.font, midLine: midLine && replace.isEmpty,
                           tag: detail?.tag)
                shown = (snap.fieldKey, display, detail)
                keys.setSuggestionVisible(panel.isVisible)
            }
            if Log.enabled, source != "pending" {
                let caret = snap.caret.map { "\($0.strategy) \(Int($0.rect.minX)),\(Int($0.rect.minY)) h\(Int($0.rect.height))" } ?? "none"
                let what = source == "details" ? "<\(label), redacted>" : text.debugDescription
                Log.debug("rev \(revision) \(source)\(ms.map { String(format: " %.0fms", $0) } ?? "") \(snap.appName) caret=\(caret) -> \(what)")
            }
        case let .status(state, detail):
            Log.debug("engine \(state): \(detail)")
            onStatus?(state, detail)
        }
    }

    func hide() {
        panel.hide()
        shown = nil
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
            let detail = shown?.detail
            if !r.replace.isEmpty { Inserter.deleteBackward(r.replace.count) }
            Inserter.insert(r.insert, strategy: strategy)
            // Replacements (emoji, corrections) stand for text already typed: not typing saved.
            if r.replace.isEmpty { stats.record(inserted: r.insert, all: action == .acceptAll) }
            Log.debug("accept \(action == .acceptAll ? "all" : "word") via \(strategy.rawValue) \(detail.map { "<\($0.rawValue), redacted>" } ?? r.insert.debugDescription)")
            if r.remaining.isEmpty {
                hide()
            } else {
                panel.advance(inserted: r.insert, remaining: r.remaining)
                shown = panel.isVisible ? (latestSnapshot.fieldKey, r.remaining, detail) : nil
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
        // Prefetching roughly doubles generated tokens; keep it for mains power. So does the
        // 3-wide phrase beam (+1.1 points of keystrokes saved for +15% GPU energy).
        d["prefetch"] = !power.onBattery
        d["beam_width"] = power.onBattery ? 1 : 3
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
