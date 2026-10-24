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
    /// Text from other apps' windows (opt-in, D42).
    let pool = ContextPool()
    let speller = Speller()
    let pixelCaret = PixelCaretProvider()
    let hotkeys = Hotkeys()
    var onStatus: ((String, String) -> Void)?
    /// Compatibility rules by bundle ID (looked up once per app).
    private var rules: [String: [String: Any]] = [:]
    /// Field and line the user forced suggestions in (Ctrl + key above Tab). Force ends when
    /// focus moves or the caret leaves that line (in a terminal the whole window is one
    /// field, so it must not outlive the command being typed).
    private var forcedField: UInt64 = 0
    private var forcedLine = ""
    /// Apps paused on their own (Ctrl+Opt+Cmd + key above Tab, the menu's Pause in X), and
    /// until when; `Date.distantFuture` is until the app quits.
    private(set) var snoozed: [String: Date] = [:]
    /// What Esc left quiet: a field for a few seconds, or an app until the user switches apps
    /// (Settings ▸ Typing). Under `lock`.
    private var esc = EscState()
    /// Everything stopped (`setPaused`). Read on the AX thread under `lock`.
    private var paused = false
    /// Main thread: what `setPaused` last applied.
    private(set) var isPaused = false
    /// Lighter work for the power rules (`PowerPolicy.Decision.saveEnergy`). Main thread;
    /// applied with `applySettings` or `setPaused`.
    var saveEnergy = false
    private var quitObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var latest = FieldSnapshot()
    /// Main thread: the suggestion on screen and its field, to move it when the pixel caret
    /// locator reports a new position. `detail` is set for a fill of one of the user's details.
    /// It can be held back (set, panel hidden) while the locator searches for the caret.
    private var shown: (fieldKey: UInt64, text: String, detail: AboutYou.Field?, midLine: Bool)?
    /// Main thread: whether a suggestion is on screen (an update waits until none is).
    var isShowingSuggestion: Bool { shown != nil }

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
        new.setContext(pool.currentJSON)
        hide()
        DispatchQueue.global(qos: .utility).async { old.shutdown() }
    }

    /// Returns false if the event taps could not be created (no Accessibility grant). With
    /// `paused`, the taps are created and turned off at once, and the tracker waits for the
    /// resume (it would prime Chromium apps on its first read).
    func start(paused: Bool) -> Bool {
        engine.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.handle(ev) } }
        tracker.primeKind = { [weak self] bundle in self?.engine.compatRule(bundle)["prime"] as? String }
        tracker.onlyAppsAllow = { [settings] pid, bundle in settings.onlyAppsAllow(pid: pid, bundleId: bundle) }
        tracker.onSnapshot = { [weak self] snap in self?.arrived(snap) }
        tracker.onFocusChange = { [weak self] snap in self?.engine.warm(snap) }
        screen.enabled = settings.useScreenContext
        screen.onUpdate = { [weak self] fieldKey, text in self?.screenTextArrived(fieldKey, text) }
        pixelCaret.onUpdate = { [weak self] fieldKey in self?.pixelCaretArrived(fieldKey) }
        pool.onChange = { [weak self] json in self?.contextChanged(json) }
        keys.onKeyDown = { [weak self] in self?.tracker.keyDown() }
        keys.onAction = { [weak self] action in DispatchQueue.main.async { self?.perform(action) } }
        hotkeys.onAction = { [weak self] action in self?.hotkey(action) }
        hotkeys.register(keyAboveTab: UInt32(keys.acceptAllKey))
        // An app paused until it quits: forget it once no copy of it runs.
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return }
            self.lock.lock()
            if self.snoozed[bundle] == .distantFuture { self.snoozed[bundle] = nil }
            self.lock.unlock()
        }
        // An app Esc switched off is on again once another app comes to the front (not
        // Foretype's own windows).
        let me = ProcessInfo.processInfo.processIdentifier
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != me else { return }
            self.lock.lock()
            self.esc.appActivated(app.bundleIdentifier)
            self.lock.unlock()
        }
        keys.escBehavior = settings.escBehavior
        isPaused = paused
        self.paused = paused
        screen.enabled = screenEnabled
        engine.configure(coreSettingsJSON())
        engine.setDetails(detailsJSON)
        updatePool()
        let ok = keys.start()
        if paused { keys.stop() } else { tracker.start() }
        return ok
    }

    /// Pausing stops every source of work: the tracker (poll, AXObservers), both event taps,
    /// screen and caret captures, the Chromium/Electron accessibility flags (set again on
    /// resume) and the core, which frees the model. Resuming starts them again with a fresh
    /// read of the focused field. Main thread.
    func setPaused(_ on: Bool) {
        guard on != isPaused else { return }
        isPaused = on
        lock.lock()
        paused = on
        forcedField = 0
        esc.reset()
        if on { latest = FieldSnapshot() }
        lock.unlock()
        if on {
            hide()
            keys.stop()
            tracker.stop()
            pixelCaret.cancel()
            screen.enabled = false
            screen.reset()
            // Pause, screen lock and sleep forget other apps' text too (D42).
            updatePool()
            tracker.restorePrimedApps()
            engine.configure(coreSettingsJSON())
        } else {
            engine.configure(coreSettingsJSON())
            screen.enabled = screenEnabled
            updatePool()
            if !keys.start() { Log.debug("key taps could not be turned back on") }
            tracker.start()
        }
        Log.debug("paused: \(on)")
    }

    /// Screen context reads the window with OCR; not while saving energy.
    private var screenEnabled: Bool { settings.useScreenContext && !saveEnergy && !isPaused }

    /// Other apps' text: the user's setting, a model on this Mac, not paused. Their windows
    /// are OCR'd only on Macs with 12 GB or more, with Screen Recording, and not while saving
    /// energy. Main thread.
    private func updatePool() {
        let on = settings.useOtherApps && settings.backendIsOnDevice && !isPaused
        var gate = ContextPool.Gate()
        gate.neverRead = Set(settings.neverReadApps)
        gate.onlyApps = { [settings] pid, bundle in settings.onlyAppsAllow(pid: pid, bundleId: bundle) }
        gate.excluded = { [weak self] bundle in self?.contextExcluded(bundle) ?? true }
        pool.configure(enabled: on, allowOCR: ContextPool.memoryAllowsOCR && !saveEnergy && ScreenContextProvider.hasPermission,
                       gate: gate)
    }

    /// Apps the user switched suggestions off in, or paused Foretype in, are not read as
    /// context. Apps off only by default (spreadsheets, editors, terminals) are: a sheet is
    /// what an email quotes (D44).
    private func contextExcluded(_ bundleId: String) -> Bool {
        settings.disabledApps.contains(bundleId) || isSnoozed(bundleId)
    }

    /// Pool queue: other apps' text changed. Prefill the new header in the background so the
    /// next keystroke doesn't wait for it.
    private func contextChanged(_ json: String) {
        engine.setContext(json)
        DispatchQueue.main.async { NotificationCenter.default.post(name: ContextPool.changed, object: nil) }
        let snap = latestSnapshot
        lock.lock()
        let stopped = paused
        lock.unlock()
        if !stopped, snap.fieldKey & 0xFFFF_FFFF != 0, !snap.textBefore.isEmpty { engine.warm(snap) }
    }

    /// "Forget All Now" (What Foretype sees): every window read is dropped, and with the
    /// core's pool emptied, so are the prompts and saved contexts holding their text (D47).
    /// While the setting stays on, windows on screen are read again at the next switch or
    /// typing pause.
    func forgetContext() {
        pool.reset()
    }

    private var latestSnapshot: FieldSnapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// The app and page URL of the last field read (never one of Foretype's own windows), for
    /// the Custom Instructions window's website note.
    var lastField: (bundleId: String, url: String) {
        let s = latestSnapshot
        return (s.bundleId, s.url)
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
        lock.lock()
        let stopped = paused
        lock.unlock()
        // Read just before a pause.
        if stopped { return }
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
        lock.lock()
        let quiet = s.force ? nil : esc.quiet(fieldKey: s.fieldKey, bundleId: s.bundleId, now: Date())
        lock.unlock()
        if isSnoozed(s.bundleId) || quiet == .app {
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return
        }
        if quiet == .field {
            // Esc's pause in this field: the core still sees the text (personalization) but
            // finds it dismissed and answers with nothing.
            engine.dismiss(fieldKey: s.fieldKey, textBefore: s.textBefore)
            engine.submit(s)
            return
        }
        // Never hand a secure field's text to the spell checker.
        if !s.secureInput, s.subrole != "AXSecureTextField" { speller.annotate(&s) }
        hintIfNeeded(s)
        // Before submitting, so a suggestion arriving for this snapshot sees a solid search
        // that is under way.
        if let pixel { pixelCaret.note(pixel) }
        engine.submit(s)
        screen.note(.init(fieldKey: s.fieldKey, pid: s.pid, windowFrame: s.windowFrame, fieldFrame: s.frame),
                    skip: !screenContextAllowed(s))
        pool.note(pid: s.pid, windowTitle: s.windowTitle, windowFrame: s.windowFrame)
    }

    /// The pixel caret locator's view of a snapshot, when it should place the ghost text:
    /// the app's rule says so (`"caret": "pixel"`), or Accessibility gave no caret for a
    /// text field (an empty one too, so the caret is found before the first keystroke).
    /// Never for fields where screen context is not allowed, or with screen context off (it
    /// captures the screen too).
    private func pixelTarget(_ s: FieldSnapshot) -> PixelCaretProvider.Target? {
        guard settings.useScreenContext, s.fieldKey & 0xFFFF_FFFF != 0,
              s.selectionLength == 0, s.markedLength == 0, screenContextAllowed(s),
              ScreenContextProvider.hasPermission else { return nil }
        // FORETYPE_CARET=pixel|ax overrides the app's rule (testing).
        let mode = ProcessInfo.processInfo.environment["FORETYPE_CARET"] ?? rule(s.bundleId)["caret"] as? String
        guard mode != "ax", s.caret == nil || mode == "pixel" else { return nil }
        let line = s.textBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return .init(fieldKey: s.fieldKey, pid: s.pid, bundleId: s.bundleId, windowFrame: s.windowFrame, fieldFrame: s.frame,
                     lineStart: s.caretIndex - line.utf16.count, lineText: line, font: s.font,
                     edgeOutsideFrame: s.edgeOutsideFrame, lineEnd: !Controller.midLine(s))
    }

    /// Text other than spaces follows the caret on its line.
    private static func midLine(_ s: FieldSnapshot) -> Bool {
        !(s.textAfter.split(separator: "\n", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Caret queue: the locator found or corrected the caret, or a solid search gave up; move
    /// the suggestion, or show one held back for the search.
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
            guard let self, let shown = self.shown, shown.fieldKey == fieldKey,
                  self.latestSnapshot.revision == updated.revision else { return }
            self.panel.show(text: shown.text, caret: updated.caret, frame: self.panelFrame(updated), font: updated.font,
                            midLine: shown.midLine, tag: shown.detail?.tag)
            self.keys.setSuggestionVisible(self.panel.isVisible)
            Log.debug("rev \(updated.revision) pixel caret moved the suggestion: show=\(self.panel.mode)")
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
            guard revision == snap.revision, !isPaused else { return }
            // One of the user's own details: tagged on screen, never written to the log.
            let detail = source == "details" ? AboutYou.Field(rawValue: label) : nil
            if text.isEmpty {
                hide()
            } else {
                // A replacement shows what Tab turns the typed text into.
                let display = replace.isEmpty ? text
                    : source == "emoji" ? " \(text) \(label)" : " → \(text.trimmingCharacters(in: .whitespaces))"
                let midLine = Controller.midLine(snap) && replace.isEmpty
                if snap.caret == nil, pixelCaret.isLocating(snap.fieldKey) {
                    // The pixel locator is looking for the caret on this line (tens of
                    // milliseconds): wait for it rather than flash the mirror card.
                    panel.hide()
                } else {
                    panel.show(text: display, caret: snap.caret, frame: panelFrame(snap), font: snap.font, midLine: midLine,
                               tag: detail?.tag)
                }
                shown = (snap.fieldKey, display, detail, midLine)
                keys.setSuggestionVisible(panel.isVisible)
            }
            if Log.enabled, source != "pending" {
                let caret = snap.caret.map { "\($0.strategy) \(Int($0.rect.minX)),\(Int($0.rect.minY)) h\(Int($0.rect.height))" } ?? "none"
                let what = source == "details" ? "<\(label), redacted>" : text.debugDescription
                // What follows the caret on its line decides inline or card; its scalars show invisible ones.
                let after = snap.textAfter.isEmpty ? "" : " after=" + snap.textAfter.prefix(12).unicodeScalars
                    .map { $0.properties.isAlphabetic ? "a" : String(format: "U+%04X", $0.value) }.joined(separator: ",")
                // The caret line's start index and the field's top and height: new lines and a
                // growing field, without the text.
                let lineLength = snap.textBefore.split(separator: "\n", omittingEmptySubsequences: false).last?.utf16.count ?? 0
                let field = snap.frame.map { " field=\(Int($0.minY))+\(Int($0.height))" } ?? ""
                let font = snap.font.map { " font=\($0.fontName) \(String(format: "%g", $0.pointSize))" } ?? ""
                let at = panel.globalFrame.map { " at \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
                Log.debug("rev \(revision) \(source)\(ms.map { String(format: " %.0fms", $0) } ?? "") \(snap.appName) caret=\(caret)\(after) line=\(snap.caretIndex - lineLength)\(field)\(font) show=\(panel.mode)\(at) -> \(what)")
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
                shown = panel.isVisible ? (latestSnapshot.fieldKey, r.remaining, detail, false) : nil
                keys.setSuggestionVisible(panel.isVisible)
            }
        case .dismiss:
            let snap = latestSnapshot
            let behavior = keys.escBehavior
            engine.dismiss(fieldKey: snap.fieldKey, textBefore: snap.textBefore)
            lock.lock()
            esc.dismissed(behavior, fieldKey: snap.fieldKey, bundleId: snap.bundleId, now: Date())
            lock.unlock()
            hide()
            Log.debug(behavior == .offInApp ? "Esc: off in \(snap.appName) until another app comes to the front"
                : "Esc: field paused for \(Int(EscState.fieldPause)) s")
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
        guard !isPaused else { return Log.debug("hotkey \(action) ignored: paused") }
        switch action {
        case .forceSuggest:
            guard snap.fieldKey != 0 else { return }
            let line = snap.textBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            lock.lock(); forcedField = snap.fieldKey; forcedLine = line; snoozed[snap.bundleId] = nil; esc.reset(); lock.unlock()
            Log.debug("force suggestions in \(snap.appName)")
            tracker.forceRead()
        case .snoozeApp:
            guard !snap.bundleId.isEmpty else { return }
            snooze(snap.bundleId, until: Date().addingTimeInterval(300))
            Log.debug("snoozed \(snap.appName) for 5 minutes")
        }
    }

    /// Pauses suggestions in one app until `until` (`.distantFuture`: until it quits).
    func snooze(_ bundleId: String, until: Date) {
        lock.lock(); snoozed[bundleId] = until; lock.unlock()
        hide()
    }

    /// Resumes an app paused from the menu or the hotkey, or switched off by Esc.
    func unsnooze(_ bundleId: String) {
        lock.lock()
        snoozed[bundleId] = nil
        if esc.offApp == bundleId { esc.reset() }
        lock.unlock()
    }

    /// The app Esc switched off until the user switches apps (`EscBehavior.offInApp`).
    var escOffApp: String? {
        lock.lock(); defer { lock.unlock() }
        return esc.offApp
    }

    /// Settings plus runtime state (pause, power) as the core's JSON.
    private func coreSettingsJSON() -> String {
        let d = Controller.coreSettings(settings, paused: isPaused, saveEnergy: saveEnergy)
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    /// The core's settings: the user's, the pause, and the power rules' lighter work.
    static func coreSettings(_ settings: AppSettings, paused: Bool, saveEnergy: Bool) -> [String: Any] {
        var d = settings.coreDict
        d["paused"] = paused
        d["debounce_ms"] = saveEnergy ? 80 : 0
        // Prefetching roughly doubles generated tokens; keep it for full speed. So does the
        // 3-wide phrase beam (+1.1 points of keystrokes saved for +15% GPU energy).
        d["prefetch"] = !saveEnergy
        d["beam_width"] = saveEnergy ? 1 : 3
        // About 1 GB of memory and its upkeep: let it go after a minute without typing.
        d["unload_after_s"] = saveEnergy ? 60 : 300
        return d
    }

    func applySettings() {
        let escBehavior = settings.escBehavior
        if keys.escBehavior != escBehavior {
            keys.escBehavior = escBehavior
            lock.lock(); esc.reset(); lock.unlock()
        }
        screen.enabled = screenEnabled
        updatePool()
        engine.configure(coreSettingsJSON())
        hide()
    }

    func shutdown() {
        hide()
        tracker.restorePrimedApps()
        engine.shutdown()
    }
}
