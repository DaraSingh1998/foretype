import AppKit

/// What the "What Foretype sees" window shows (Settings ▸ Context): the windows of other apps
/// in memory and the passages the core put into the last prompt. Gathered from what is
/// already held (`ContextPool.entries`, `ft_engine_context_report`): nothing is read or
/// captured for it, and it never leaves the Mac.
struct ContextSight {
    enum State: Equatable {
        /// "Use text from other apps" is off.
        case off
        /// A server makes suggestions: other apps' text is never read for it.
        case server
        case paused
        /// Setup isn't finished (no Accessibility or no model): nothing runs yet.
        case notRunning
        case on
    }

    var state: State
    var entries: [ContextPool.Entry] = []
    var report: ContextReport?
    var now = Date()
    /// Names of the displays by `Entry.display` when more than one is connected.
    var displays: [String] = []

    /// The window list's empty note, or nil when there are windows.
    var windowsNote: String? {
        switch state {
        case .off: return L("\u{201C}Use text from other apps\u{201D} is off: no other window is read.")
        case .server: return ContextSight.serverNote
        case .paused: return L("Foretype is paused: nothing is read, and what was read has been forgotten.")
        case .notRunning: return L("Foretype isn\u{2019}t running yet: finish setup first.")
        case .on: return entries.isEmpty ? ContextSight.nothingYetNote : nil
        }
    }

    static var serverNote: String {
        L("Unavailable while a server makes suggestions: other apps\u{2019} text never leaves this Mac, and a server may not be on it.")
    }

    static var nothingYetNote: String {
        L("Nothing read yet. Open a document, slides or a web page in another window, then click into the field you are writing in: Foretype reads the windows beside it when focus moves there or you stop typing.")
    }

    /// The passage list's empty note, or nil when it has passages.
    var passagesNote: String? {
        guard state == .on, let last = report?.last else {
            return L("No suggestion has used text from other apps yet, or since it was last forgotten.")
        }
        guard last.passages.isEmpty else { return nil }
        if last.left_out { return L("Left out of the last prompt: with it, the prompt didn\u{2019}t fit the model\u{2019}s context.") }
        if last.gone > 0 { return L("The windows the last prompt used have left memory since: their text isn\u{2019}t shown.") }
        return L("The last prompt took no text from other windows: none matched what you were writing.")
    }

    /// "2 on screen, 1 viewed in the last 10 minutes" (a part with none is left out).
    var windowsSummary: String {
        let visible = entries.filter(\.visible).count
        var parts: [String] = []
        if visible > 0 { parts.append(LCount(visible, "%@ on screen", one: "%@ on screen")) }
        if entries.count > visible {
            parts.append(LCount(entries.count - visible, "%@ viewed in the last 10 minutes", one: "%@ viewed in the last 10 minutes"))
        }
        return parts.joined(separator: ", ")
    }

    /// "3 passages, about 340 of 512 tokens, 5 seconds ago".
    var promptSummary: String? {
        guard state == .on, let r = report, let last = r.last else { return nil }
        var parts: [String] = []
        if !last.passages.isEmpty { parts.append(LCount(last.passages.count, "%@ passages", one: "%@ passage")) }
        parts.append(L("about %1$@ of %2$@ tokens", formatNumber(last.tokens), formatNumber(r.budget)))
        parts.append(ContextSight.ago(now.timeIntervalSince(Date(timeIntervalSince1970: last.at))))
        var s = parts.joined(separator: ", ")
        if last.gone > 0, !last.passages.isEmpty {
            s += " " + LCount(last.gone, "(%@ more from windows that have left memory)", one: "(%@ more from a window that has left memory)")
        }
        return s
    }

    /// "On screen · Built-in Retina Display · Accessibility · 2,340 characters".
    func detail(_ e: ContextPool.Entry) -> String {
        var parts = [e.visible ? L("On screen") : L("Viewed %@", ContextSight.ago(now.timeIntervalSince(e.lastSeen)))]
        if displays.count > 1 { parts.append(e.display < displays.count ? displays[e.display] : L("Display %@", formatNumber(e.display + 1))) }
        parts.append(e.ocr ? L("Read by OCR") : L("Read by Accessibility"))
        parts.append(LCount(e.text.count, "%@ characters", one: "%@ character"))
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "Safari — Spring Launch Plan (docs.example.com)".
    static func title(_ e: ContextPool.Entry) -> String {
        let t = e.title.isEmpty || e.title == e.app ? e.app : "\(e.app) \u{2014} \(e.title)"
        return e.urlHost.isEmpty ? t : "\(t) (\(e.urlHost))"
    }

    /// "5 seconds ago", "3 minutes ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return LCount(s, "%@ seconds ago", one: "%@ second ago") }
        return LCount(s / 60, "%@ minutes ago", one: "%@ minute ago")
    }

    /// Changes when a row would read differently (ages move it once a minute at most).
    var rowsSignature: Int {
        var h = Hasher()
        h.combine(windowsNote)
        for e in entries {
            h.combine(e.key)
            h.combine(ContextSight.title(e))
            h.combine(detail(e))
        }
        h.combine(passagesNote)
        for p in report?.last?.passages ?? [] {
            h.combine(p.label)
            h.combine(p.ordinal)
            h.combine(p.text)
        }
        return h.finalize()
    }

    /// The connected displays' names in `displayBounds()` order (the pool's display index).
    static func displayNames() -> [String] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 1 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).enumerated().map { i, id in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            return screen?.localizedName ?? L("Display %@", formatNumber(i + 1))
        }
    }
}

/// The "What Foretype sees" window: updates every second while open, from memory only.
final class ContextViewerController: NSWindowController, NSWindowDelegate {
    /// Main thread: what to show now.
    var source: () -> ContextSight
    /// "Never Read This App" on a window's row: adds its app to the never-read list.
    var onNeverRead: ((String) -> Void)?
    /// "Forget All Now": clears the pool and the engine's saved contexts.
    var onForget: (() -> Void)?

    private let windowsSummary = NSTextField(labelWithString: "")
    private let windowsList = AppList(minHeight: 64, maxHeight: 220)
    private let promptSummary = NSTextField(wrappingLabelWithString: "")
    private let level = NSLevelIndicator()
    private let passagesList = AppList(minHeight: 64, maxHeight: 250)
    private let forget = NSButton(title: L("Forget All Now"), target: nil, action: nil)
    private let stack = NSStackView()
    private var timer: Timer?
    private var shown: Int?
    /// What was shown last (the self-test and FORETYPE_CONTEXT_REPORT read it).
    private(set) var sight: ContextSight
    static let width: CGFloat = 640

    init(source: @escaping () -> ContextSight) {
        self.source = source
        sight = ContextSight(state: .off)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = L("What Foretype Sees")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        windowsSummary.font = .systemFont(ofSize: 11)
        windowsSummary.textColor = .secondaryLabelColor
        promptSummary.font = .systemFont(ofSize: 11)
        promptSummary.textColor = .secondaryLabelColor
        promptSummary.preferredMaxLayoutWidth = Self.width - 48 - 150
        level.levelIndicatorStyle = .continuousCapacity
        level.minValue = 0
        level.widthAnchor.constraint(equalToConstant: 140).isActive = true
        level.setContentHuggingPriority(.required, for: .horizontal)
        forget.target = self
        forget.action = #selector(forgetClicked)
        forget.toolTip = L("Forgets every window read and the prompts kept for them. While the setting is on, windows on screen are read again the next time focus moves or you stop typing.")
        let promptRow = PreferencesPane.hstack([promptSummary, NSView(), level])
        promptRow.alignment = .centerY
        let note = PreferencesPane.note(L("Shows only what is already in memory: nothing is read for this window, and it all stays on this Mac. Each window is forgotten 10 minutes after you last saw it, and everything when Foretype pauses, the screen locks or the Mac sleeps."), width: 420)
        let footer = PreferencesPane.hstack([note, NSView(), forget])
        footer.alignment = .top
        let rows: [NSView] = [
            PreferencesPane.heading(L("Windows in memory")), windowsSummary, windowsList,
            PreferencesPane.heading(L("In the last prompt")), promptRow, passagesList,
            PreferencesPane.separator(), footer,
        ]
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in rows { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(18, after: windowsList)
        stack.setCustomSpacing(14, after: passagesList)
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        for v in rows { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
    }

    /// `activate: false` (FORETYPE_CONTEXT_REPORT) puts it in front without taking focus from
    /// the field being typed in.
    func show(activate: Bool = true) {
        refresh()
        if window?.isVisible != true { window?.center() }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    /// Reads what is in memory now; the rows are rebuilt only when one would read differently.
    func refresh() {
        let s = source()
        sight = s
        windowsSummary.stringValue = s.entries.isEmpty ? "" : s.windowsSummary
        windowsSummary.isHidden = s.entries.isEmpty
        promptSummary.stringValue = s.promptSummary ?? ""
        let budget = Double(s.report?.budget ?? 0)
        level.maxValue = max(budget, 1)
        level.doubleValue = Double(s.report?.last?.tokens ?? 0)
        level.isHidden = s.promptSummary == nil
        forget.isEnabled = !s.entries.isEmpty || s.report?.last != nil
        let sig = s.rowsSignature
        guard sig != shown else { return }
        shown = sig
        windowsList.setRows(s.entries.map(windowRow), empty: s.windowsNote.map { PreferencesPane.note($0, width: Self.width - 70) })
        passagesList.setRows((s.report?.last?.passages ?? []).map(passageRow),
                             empty: s.passagesNote.map { PreferencesPane.note($0, width: Self.width - 70) })
        stack.layoutSubtreeIfNeeded()
        fitWindow()
    }

    /// As tall as the rows; the lists scroll beyond their maximum heights.
    private func fitWindow() {
        guard let window else { return }
        let size = NSSize(width: Self.width, height: ceil(stack.fittingSize.height))
        guard abs(window.contentRect(forFrameRect: window.frame).height - size.height) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        if window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
    }

    /// A window in memory: icon, app and title, how it was read, and Never Read This App.
    private func windowRow(_ e: ContextPool.Entry) -> NSView {
        let icon = NSRunningApplication(processIdentifier: e.pid)?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
        let image = NSImageView(image: icon)
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        image.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let title = NSTextField(labelWithString: ContextSight.title(e))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(wrappingLabelWithString: sight.detail(e))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.isSelectable = false
        detail.maximumNumberOfLines = 2
        detail.cell?.truncatesLastVisibleLine = true
        detail.preferredMaxLayoutWidth = 400
        let names = NSStackView(views: [title, detail])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        for v in [title, detail] { v.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true }
        let never = ActionButton.make(L("Never Read This App")) { [weak self] in self?.onNeverRead?(e.bundleId) }
        never.controlSize = .small
        never.toolTip = L("Adds %@ to the apps never read as context and forgets its windows now.", e.app)
        never.setContentCompressionResistancePriority(.required, for: .horizontal)
        never.setAccessibilityIdentifier("never-read:\(e.bundleId)")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, names, spacer, never])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        return row
    }

    /// A passage of the last prompt: its window, its estimated tokens and its start.
    private func passageRow(_ p: ContextReport.Passage) -> NSView {
        let label = NSTextField(labelWithString: p.label)
        label.font = .boldSystemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tokens = NSTextField(labelWithString: L("about %@ tokens", formatNumber(p.tokens)))
        tokens.font = .systemFont(ofSize: 10)
        tokens.textColor = .secondaryLabelColor
        tokens.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = PreferencesPane.hstack([label, NSView(), tokens])
        let text = NSTextField(wrappingLabelWithString: p.text)
        text.font = .systemFont(ofSize: 11)
        text.maximumNumberOfLines = 3
        text.cell?.truncatesLastVisibleLine = true
        text.isSelectable = false
        text.preferredMaxLayoutWidth = Self.width - 70
        text.toolTip = p.text
        let v = NSStackView(views: [top, text])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        v.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        top.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -20).isActive = true
        text.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -20).isActive = true
        return v
    }

    @objc private func forgetClicked() {
        onForget?()
        // The pool is emptied on its own queue and the core told after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    // MARK: - Self-test

    /// The content as a PNG, light or dark.
    func png(dark: Bool) -> Data? {
        guard let content = window?.contentView else { return nil }
        defer { content.appearance = nil }
        return PreferencesPane.png(of: content, dark: dark)
    }

    /// `Foretype --context-view-selftest [DIR]`: the window on made-up windows and a made-up
    /// report, never shown: every state's notes, the rows and their buttons, the summaries,
    /// and that it fits a 13-inch MacBook Air with a full pool. DIR gets a PNG per state,
    /// light and dark (run the bundled binary with `-AppleLanguages '(hi)'` for Hindi).
    static func selfTest(dir: String?) -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("FAIL: \(what)") }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ i: Int, visible: Bool, ocr: Bool = false, age: TimeInterval = 0) -> ContextPool.Entry {
            let apps = [("TextEdit", "com.apple.TextEdit", "Q3 Budget Review.rtf"), ("Safari", "com.apple.Safari", "Spring Launch Plan"),
                        ("Keynote", "com.apple.iWork.Keynote", "Board update.key"), ("Preview", "com.apple.Preview", "Ferry timetable.pdf")]
            let a = apps[i % apps.count]
            return ContextPool.Entry(key: "\(100 + i):\(i)", pid: 0, app: a.0, bundleId: a.1, title: a.2,
                                     urlHost: a.0 == "Safari" ? "docs.example.com" : "",
                                     text: String(repeating: "Contractors cost $68,900 against a budget of $52,000. ", count: 20 + i),
                                     visible: visible, display: i % 2, lastSeen: now.addingTimeInterval(-age), ocr: ocr)
        }
        let passages = (0..<4).map { i in
            ContextReport.Passage(label: i < 2 ? "TextEdit \u{2014} Q3 Budget Review.rtf" : "Safari \u{2014} Spring Launch Plan (docs.example.com)",
                                  app: i < 2 ? "TextEdit" : "Safari", bundle_id: i < 2 ? "com.apple.TextEdit" : "com.apple.Safari",
                                  ordinal: i, tokens: 70 + i,
                                  text: "Total Q3 spend was $412,600 against a budget of $398,000, an overrun of $14,600 (3.7%). Most of the overrun came from contractor hours on the warehouse migration, which ran three weeks longer than planned, and the equipment refresh for the Leeds office.")
        }
        let report = ContextReport(server: false, windows: 3, passages: 20, budget: 512, changes: 2,
                                   last: .init(at: now.timeIntervalSince1970 - 5, tokens: 340, left_out: false, gone: 1, passages: passages))
        let full = ContextSight(state: .on, entries: [entry(0, visible: true), entry(1, visible: true, ocr: true), entry(2, visible: false, age: 200)]
                                    + (3..<12).map { entry($0, visible: false, age: TimeInterval($0) * 40) },
                                report: report, now: now, displays: ["Built-in Retina Display", "DELL U2720Q"])
        var current = full
        let viewer = ContextViewerController { current }
        var neverRead: [String] = []
        var forgot = 0
        viewer.onNeverRead = { neverRead.append($0) }
        viewer.onForget = { forgot += 1 }
        let states: [(String, ContextSight)] = [
            ("full", full),
            ("one", ContextSight(state: .on, entries: [entry(0, visible: true)], report: report, now: now)),
            ("nothing-yet", ContextSight(state: .on, now: now)),
            ("no-match", ContextSight(state: .on, entries: [entry(2, visible: false, age: 30)],
                                      report: ContextReport(budget: 512, last: .init(at: now.timeIntervalSince1970 - 70, tokens: 0, left_out: false, gone: 0, passages: [])), now: now)),
            ("left-out", ContextSight(state: .on, entries: [entry(0, visible: true)],
                                      report: ContextReport(budget: 512, last: .init(at: now.timeIntervalSince1970, tokens: 0, left_out: true, gone: 0, passages: [])), now: now)),
            ("off", ContextSight(state: .off, now: now)),
            ("server", ContextSight(state: .server, report: ContextReport(server: true, budget: 512), now: now)),
            ("paused", ContextSight(state: .paused, now: now)),
            ("not-running", ContextSight(state: .notRunning, now: now)),
        ]
        let air = PreferencesSelfTest.air13
        for (name, s) in states {
            current = s
            viewer.refresh()
            guard let window = viewer.window else { return false }
            let height = window.frame.height
            print(String(format: "%@: %.0f pt high (%d windows, %d passages)", name, height, s.entries.count, s.report?.last?.passages.count ?? 0))
            check(height <= air.height, "\(name): \(height) pt doesn't fit a 13-inch MacBook Air (\(air.height))")
            check((s.windowsNote == nil) == !s.entries.isEmpty, "\(name): window note \(s.windowsNote ?? "nil")")
            check((s.passagesNote == nil) == !(s.report?.last?.passages.isEmpty ?? true) || s.state != .on, "\(name): passage note")
            if let dir {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for dark in [false, true] {
                    let path = "\(dir)/context-view-\(name)-\(dark ? "dark" : "light").png"
                    check((try? viewer.png(dark: dark)?.write(to: URL(fileURLWithPath: path))) != nil, "writing \(path)")
                }
            }
        }
        // The full pool: its summaries, its rows and their buttons.
        current = full
        viewer.refresh()
        let n = formatNumber
        check(full.windowsSummary.contains(n(2)) && full.windowsSummary.contains(n(10)), "windows summary: \(full.windowsSummary)")
        let summary = full.promptSummary ?? ""
        check(summary.contains(n(340)) && summary.contains(n(512)) && summary.contains(n(5)), "prompt summary: \(summary)")
        check(full.detail(full.entries[1]).contains("DELL U2720Q") && ContextSight.title(full.entries[1]).contains("(docs.example.com)"),
              "detail: \(full.detail(full.entries[1])), title \(ContextSight.title(full.entries[1]))")
        check(full.detail(full.entries[0]) != full.detail(full.entries[1]), "OCR and Accessibility rows read differently")
        check(ContextSight.ago(59).contains(n(59)) && ContextSight.ago(61).contains(n(1)) && ContextSight.ago(-3).contains(n(0)), "ages")
        let buttons = viewer.window?.contentView.map { allViews($0) }?.compactMap { $0 as? ActionButton } ?? []
        let neverButtons = buttons.filter { $0.accessibilityIdentifier().hasPrefix("never-read:") }
        check(neverButtons.count == full.entries.count, "\(neverButtons.count) Never Read buttons for \(full.entries.count) windows")
        neverButtons.first { $0.accessibilityIdentifier() == "never-read:com.apple.Safari" }?.performClick(nil)
        check(neverRead == ["com.apple.Safari"], "Never Read This App adds \(neverRead)")
        viewer.forget.performClick(nil)
        check(forgot == 1, "Forget All Now")
        // Nothing in memory: nothing to forget.
        current = ContextSight(state: .on, now: now)
        viewer.refresh()
        check(!viewer.forget.isEnabled, "Forget All Now enabled with nothing in memory")
        // An unchanged pool keeps its rows (no rebuild every second).
        let before = viewer.windowsList.documentView?.subviews.first?.subviews.map { ObjectIdentifier($0) }
        viewer.refresh()
        check(before == viewer.windowsList.documentView?.subviews.first?.subviews.map { ObjectIdentifier($0) }, "rows rebuilt without a change")
        if dir != nil { print("context view pictures written to \(dir!)") }
        print(failures == 0 ? "context view self-test passed" : "context view self-test: \(failures) failed")
        return failures == 0
    }

    private static func allViews(_ v: NSView) -> [NSView] {
        [v] + v.subviews.flatMap(allViews)
    }
}
