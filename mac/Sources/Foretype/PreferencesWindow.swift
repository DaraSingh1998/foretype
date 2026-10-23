import AppKit

/// What the Settings window needs from the app. AppDelegate implements it with the same
/// code paths as the menu-bar menu, so a change made in either place behaves the same.
protocol PreferencesHost: AnyObject {
    var settings: AppSettings { get }
    var models: ModelManager { get }
    var stats: UsageStats { get }
    /// "ready — Qwen3-1.7B-Base.Q4_K_M.gguf" and the like.
    var engineStatus: String { get }
    /// Pushes changed settings into the core (`Controller.applySettings`).
    func settingsChanged()
    func setPersonalize(_ on: Bool)
    func historyStats() -> (records: Int, words: Int)?
    func confirmDeleteHistory()
    func openInstructions()
    func openScreenRecordingSettings()
    func isModelInUse(_ path: String) -> Bool
    func useModelFile(_ path: String)
    func download(_ m: ModelInfo)
    func confirmDeleteModel(_ path: String)
    func applyServer(backend: String, url: String, model: String, apiKey: String?)
    /// Adds text files the user picks to the writing history.
    func importWriting()
    /// Picks an application and flips its default (off, or on where it is off by default).
    func addAppException()
    /// The user's own details (Settings ▸ About You). A change applies at once and is saved
    /// encrypted shortly after.
    var aboutYou: AboutYou { get }
    func setAboutYou(_ details: AboutYou)
    func confirmClearAboutYou()
    /// Sparkle, configured in release builds only (`isConfigured`).
    var updates: UpdateController? { get }
    /// Pausing: why and until when (`pauseDescription` is nil while not paused).
    var pause: PauseState { get }
    var pauseDescription: String? { get }
    var powerState: PowerState { get }
    /// Pauses until `until`, or until resumed (nil).
    func pauseSuggestions(until: Date?)
    /// Ends the user's pause, or sets the power rules' pause aside ("Resume Anyway").
    func resumeSuggestions()
    /// The battery or Low Power Mode settings changed.
    func powerSettingsChanged()
}

/// The Settings window (menu: Settings…, Cmd-,): everything in the menu-bar menu plus the
/// per-app list, model files and disk use, the server fields and statistics, in toolbar
/// tabs. Every change applies immediately through the host; the menu stays a second way to
/// the common settings.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    let tabs: PreferencesTabController
    let panes: [PreferencesPane]
    private let modelPane: ModelPane
    private let statsPane: StatisticsPane
    private var fitPending = false

    init(host: PreferencesHost) {
        let model = ModelPane(title: L("Model"), host: host)
        let statistics = StatisticsPane(title: L("Statistics"), host: host)
        let panes: [PreferencesPane] = [GeneralPane(title: L("General"), host: host),
                                        TypingPane(title: L("Typing"), host: host),
                                        ContextPane(title: L("Context"), host: host),
                                        PersonalizationPane(title: L("Personalization"), host: host),
                                        AboutYouPane(title: L("About You"), host: host),
                                        AppsPane(title: L("Apps"), host: host), model, statistics]
        let tabs = PreferencesTabController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        let symbols = ["gearshape", "keyboard", "text.viewfinder", "person.crop.circle", "person.text.rectangle",
                       "square.grid.2x2", "cpu", "chart.bar"]
        for (pane, symbol) in zip(panes, symbols) {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        self.tabs = tabs
        self.panes = panes
        modelPane = model
        statsPane = statistics
        super.init(window: window)
        window.delegate = self
        // A display added, removed or rearranged, the Dock resized, scroll bars shown always.
        for name in [NSApplication.didChangeScreenParametersNotification, NSScroller.preferredScrollerStyleDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        modelPane.loadServer()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            tabs.fit(animated: false)
            window?.center()
            // Centring can leave a window as tall as the screen under the menu bar.
            tabs.fit(animated: false)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func screensChanged() {
        // After the scroll views have taken up a new scroller style.
        DispatchQueue.main.async { [weak self] in
            if self?.window?.isVisible == true { self?.tabs.fit(animated: false) }
        }
    }

    /// Dragged onto another display: fits the pane to that one once the mouse is let go
    /// (moving the window during the drag would fight it).
    func windowDidChangeScreen(_ notification: Notification) {
        guard !fitPending else { return }
        fitPending = true
        fitAfterDrag()
    }

    private func fitAfterDrag() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.fitAfterDrag() }
            return
        }
        fitPending = false
        tabs.fit(animated: true)
    }

    /// Settings, engine status or permissions may have changed.
    func refresh() {
        for p in panes where p.isViewLoaded { p.refresh() }
        if window?.isVisible == true { tabs.fit(animated: false) }
    }

    /// A model's download state or the models folder changed.
    func modelsChanged() {
        guard modelPane.isViewLoaded else { return }
        if modelPane.refreshRows() { tabs.fit(animated: false) }
    }

    func statsChanged() {
        if statsPane.isViewLoaded { statsPane.refresh() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }
}

/// Toolbar tabs that size the window to the selected pane.
final class PreferencesTabController: NSTabViewController {
    /// Where the window must fit: its screen's visible frame (below the menu bar, beside the
    /// Dock). --settings-selftest puts made-up screens here.
    var visibleFrame: (NSWindow) -> NSRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        (tabViewItem?.viewController as? PreferencesPane)?.refresh()
        fit(animated: true)
    }

    /// Resizes the window to the selected pane, keeping its top edge: as tall as the pane's
    /// rows where the screen has room, otherwise as tall as the screen allows with the rows
    /// scrolling. Then moves the window back inside the screen if it sticks out.
    func fit(animated: Bool) {
        guard selectedTabViewItemIndex >= 0,
              let pane = tabViewItems[selectedTabViewItemIndex].viewController as? PreferencesPane,
              let window = view.window, let content = window.contentView else { return }
        let chrome = NSSize(width: window.frame.width - content.frame.width, height: window.frame.height - content.frame.height)
        let visible = visibleFrame(window)
        let want = pane.contentHeight
        let height = visible.map { min(want, floor($0.height - chrome.height)) } ?? want
        let width = pane.setScrolls(want > height)
        let f = Self.frame(content: NSSize(width: width, height: height), chrome: chrome, current: window.frame, visible: visible)
        let w = window.frame
        guard [f.minX - w.minX, f.minY - w.minY, f.width - w.width, f.height - w.height].contains(where: { abs($0) > 0.5 }) else { return }
        window.setFrame(f, display: true, animate: animated && window.isVisible)
    }

    /// The window frame for `content`: `current`'s top edge kept, then moved inside `visible`.
    static func frame(content: NSSize, chrome: NSSize, current: NSRect, visible: NSRect?) -> NSRect {
        var f = current
        f.size = NSSize(width: content.width + chrome.width, height: content.height + chrome.height)
        f.origin.y = current.maxY - f.height
        guard let v = visible else { return f }
        f.origin.x = max(min(f.minX, v.maxX - f.width), v.minX)
        f.origin.y = max(min(f.minY, v.maxY - f.height), v.minY)
        return f
    }
}

// MARK: - Panes

/// One tab: a vertical stack of rows, fixed width, in a scroll view. The window shows every
/// row where the screen has room and scrolls them where it hasn't
/// (`PreferencesTabController.fit`).
class PreferencesPane: NSViewController {
    weak var host: PreferencesHost?
    let stack = NSStackView()
    private let scroll = NSScrollView()
    private var widthConstraint: NSLayoutConstraint?
    static let width: CGFloat = 580
    static let inset: CGFloat = 24

    init(title: String, host: PreferencesHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: Self.inset, bottom: 20, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        let width = scroll.widthAnchor.constraint(equalToConstant: Self.width)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            width,
        ])
        widthConstraint = width
        view = scroll
        build()
        refresh()
    }

    func build() {}
    func refresh() {}

    /// The height of all the rows.
    var contentHeight: CGFloat {
        _ = view
        stack.layoutSubtreeIfNeeded()
        return ceil(stack.fittingSize.height)
    }

    /// The window is shorter than the rows: they scroll.
    var scrolls: Bool { scroll.hasVerticalScroller }

    /// Turns scrolling on or off and returns the pane's width: wider by the scroller where
    /// scroll bars take room (System Settings ▸ Appearance ▸ Show scroll bars: Always), so
    /// the scroller covers no control.
    func setScrolls(_ on: Bool) -> CGFloat {
        _ = view
        if !on, scroll.hasVerticalScroller {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scroll.hasVerticalScroller = on
        scroll.verticalScrollElasticity = on ? .automatic : .none
        let bar = on && scroll.scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        widthConstraint?.constant = Self.width + bar
        return Self.width + bar
    }

    /// All the rows as a PNG, light or dark (FORETYPE_UPDATE_REPORT, --settings-selftest).
    func png(dark: Bool = false) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        view.setFrameSize(NSSize(width: Self.width, height: contentHeight))
        view.layoutSubtreeIfNeeded()
        guard let rep = stack.bitmapImageRepForCachingDisplay(in: stack.bounds) else { return nil }
        stack.cacheDisplay(in: stack.bounds, to: rep)
        var background = NSColor.white
        appearance?.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? background
        }
        let image = NSImage(size: stack.bounds.size, flipped: false) { r in
            background.setFill()
            r.fill()
            rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return true
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// Adds a row that spans the pane's width.
    func add(_ v: NSView, spacingAfter: CGFloat? = nil) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: v) }
    }

    static func heading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    /// Secondary, wrapping explanation text.
    static func note(_ text: String, width: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.isSelectable = false
        if let width {
            l.preferredMaxLayoutWidth = width
            l.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return l
    }

    static func formLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    /// A two-column form: right-aligned labels, controls on the left edge of column two.
    static func form(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.column(at: 0).xPlacement = .trailing
        g.rowAlignment = .firstBaseline
        g.columnSpacing = 8
        g.rowSpacing = 8
        return g
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = spacing
        return s
    }
}

/// An NSButton that runs a closure (for rows built from data).
final class ActionButton: NSButton {
    var handler: (() -> Void)?

    static func make(_ title: String, _ handler: @escaping () -> Void) -> ActionButton {
        let b = ActionButton(title: title, target: nil, action: nil)
        b.target = b
        b.action = #selector(run)
        b.handler = handler
        return b
    }

    @objc private func run() { handler?() }
}

/// Container for a scroll view's document: top-left origin, so rows start at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A bordered list of rows (`AppList.row`) with separators: as tall as its rows between
/// `minHeight` and `maxHeight`, scrolling beyond, so the buttons under it stay in view.
final class AppList: NSScrollView {
    private let list = NSStackView()
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private var height: NSLayoutConstraint!

    init(minHeight: CGFloat = 60, maxHeight: CGFloat = 240) {
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        documentView = doc
        height = heightAnchor.constraint(equalToConstant: minHeight)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            height,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Replaces the rows; `empty` (a wrapping note) shows when there are none.
    func setRows(_ rows: [NSView], empty: NSView? = nil) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var views = rows
        if rows.isEmpty, let empty {
            let pad = NSStackView(views: [empty])
            pad.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            views = [pad]
        }
        for (i, v) in views.enumerated() {
            if i > 0 {
                let sep = PreferencesPane.separator()
                list.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            list.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.layoutSubtreeIfNeeded()
        height.constant = min(max(ceil(list.fittingSize.height) + 2, minHeight), maxHeight)
    }

    /// One app: icon, name and bundle ID, a status (`state`, may be empty) and a Remove
    /// button whose tooltip is `removeTip` with the app's name.
    static func row(bundle: String, state: String, stateColor: NSColor = .secondaryLabelColor,
                    removeTip: String, onRemove: @escaping () -> Void) -> NSView {
        var name = bundle
        var icon: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        let image = NSImageView(image: icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        image.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let title = NSTextField(labelWithString: name)
        // Not installed: the bundle ID is already the title.
        let id = NSTextField(labelWithString: icon == nil ? L("not installed") : bundle)
        id.font = .systemFont(ofSize: 10)
        id.textColor = .tertiaryLabelColor
        let names = NSStackView(views: [title, id])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let status = NSTextField(labelWithString: state)
        status.textColor = stateColor
        status.isHidden = state.isEmpty
        let remove = ActionButton.make(L("Remove"), onRemove)
        remove.controlSize = .small
        remove.toolTip = String(format: removeTip, name)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, names, spacer, status, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        return row
    }
}

// MARK: General

/// When Foretype runs (login, pause, power) and its version and updates.
final class GeneralPane: PreferencesPane {
    /// --settings-selftest: shows the update rows, which builds without Sparkle hide.
    static var showsUpdatesForTesting = false
    private let openAtLogin = NSButton(checkboxWithTitle: L("Open Foretype when you log in"), target: nil, action: nil)
    private let pauseStatus = NSTextField(labelWithString: "")
    private let pauseMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let resume = NSButton(title: L("Resume"), target: nil, action: nil)
    private let battery = NSPopUpButton()
    private let lowPower = NSPopUpButton()
    private let batteryLevel = NSPopUpButton()
    private var batteryRows: [NSGridRow] = []
    private let autoCheck = NSButton(checkboxWithTitle: L("Check for updates every day"), target: nil, action: nil)
    private let autoInstall = NSButton(checkboxWithTitle: L("Install updates automatically"), target: nil, action: nil)
    private let checkNow = NSButton(title: L("Check Now"), target: nil, action: nil)
    private let versionLabel = NSTextField(labelWithString: "")
    private let availableLabel = NSTextField(labelWithString: "")
    private let installUpdate = NSButton(title: L("Install\u{2026}"), target: nil, action: nil)
    private var availableRow: NSGridRow?
    private let updateNote = PreferencesPane.note(L("A new version installs after a few minutes away from the keyboard and mouse; Foretype then reopens by itself and keeps its permissions."), width: 400)
    private var updateRows: [NSGridRow] = []

    override func build() {
        openAtLogin.target = self
        openAtLogin.action = #selector(loginChanged)
        pauseMenu.addItem(withTitle: L("Pause"))
        pauseMenu.addItems(withTitles: PauseChoice.allCases.map(\.title))
        pauseMenu.target = self
        pauseMenu.action = #selector(pauseChosen)
        resume.target = self
        resume.action = #selector(resumeClicked)
        battery.addItems(withTitles: [L("Full speed"), L("Save energy"), L("Pause")])
        lowPower.addItems(withTitles: [L("Save energy"), L("Pause")])
        batteryLevel.addItems(withTitles: PowerPolicy.batteryLevels.map {
            $0 == 0 ? L("Keep going") : L("Pause below %@", formatPercent(Double($0) / 100))
        })
        for p in [battery, lowPower, batteryLevel] {
            p.target = self
            p.action = #selector(powerChanged(_:))
        }
        for b in [autoCheck, autoInstall] {
            b.target = self
            b.action = #selector(updatesChanged(_:))
        }
        checkNow.target = self
        checkNow.action = #selector(checkForUpdates)
        checkNow.controlSize = .small
        // Sparkle's window for the waiting update, as the menu's update line opens.
        installUpdate.target = self
        installUpdate.action = #selector(checkForUpdates)
        installUpdate.controlSize = .small
        availableLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let available = Self.hstack([availableLabel, installUpdate])
        let grid = Self.form([
            [Self.formLabel(L("Startup:")), openAtLogin],
            [Self.formLabel(L("Suggestions:")), Self.hstack([pauseStatus, pauseMenu, resume])],
            [Self.formLabel(L("On battery:")), battery],
            [Self.formLabel(L("Low battery:")), batteryLevel],
            [Self.formLabel(L("Low Power Mode:")), lowPower],
            [NSGridCell.emptyContentView, Self.note(L("Saving energy: no look-ahead or screen reading, and the model is freed after a minute without typing. Foretype always pauses while the Mac sleeps or is locked, and saves energy or pauses when it runs hot."), width: 400)],
            [Self.formLabel(L("Version:")), versionLabel],
            [NSGridCell.emptyContentView, available],
            [Self.formLabel(L("Updates:")), autoCheck],
            [NSGridCell.emptyContentView, autoInstall],
            [NSGridCell.emptyContentView, updateNote],
            [NSGridCell.emptyContentView, checkNow],
        ])
        grid.row(at: 6).topPadding = 8
        batteryRows = [battery, batteryLevel].compactMap { grid.cell(for: $0)?.row }
        updateRows = [autoCheck, autoInstall, updateNote, checkNow].compactMap { grid.cell(for: $0)?.row }
        availableRow = grid.cell(for: available)?.row
        add(grid)
    }

    override func refresh() {
        guard let host else { return }
        let s = host.settings
        openAtLogin.state = AppLocation.opensAtLogin ? .on : .off
        openAtLogin.isEnabled = AppLocation.isBundledApp
        let pause = host.pause
        pauseStatus.stringValue = host.pauseDescription ?? L("On")
        pauseStatus.textColor = pause.isPaused ? .secondaryLabelColor : .labelColor
        pauseMenu.isHidden = pause.isUserPaused
        let canResume = pause.isUserPaused || (pause.powerReason != nil && pause.systemReason == nil)
        resume.isHidden = !canResume
        resume.title = pause.isUserPaused ? L("Resume") : L("Resume Anyway")
        battery.selectItem(at: PowerPolicy.BatteryMode.allCases.firstIndex(of: s.batteryMode) ?? 1)
        lowPower.selectItem(at: PowerPolicy.LowPowerMode.allCases.firstIndex(of: s.lowPowerMode) ?? 1)
        batteryLevel.selectItem(at: PowerPolicy.batteryLevels.firstIndex(of: s.pauseBelowBattery) ?? 0)
        for row in batteryRows { row.isHidden = !host.powerState.hasBattery }
        refreshUpdates()
    }

    private func refreshUpdates() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        let updates = host?.updates
        let on = updates?.isConfigured ?? false
        for row in updateRows { row.isHidden = !on && !Self.showsUpdatesForTesting }
        if let updates, on {
            autoCheck.state = updates.automaticallyChecks ? .on : .off
            autoInstall.state = updates.automaticallyInstalls ? .on : .off
            autoInstall.isEnabled = updates.automaticallyChecks
        }
        var text = L("Development build")
        if let version, let build { text = L("%@ (build %@)", version, build) }
        if !on { text += " \u{2014} " + L("this build doesn\u{2019}t update itself") }
        versionLabel.stringValue = text
        let available = on ? updates?.availableVersion : nil
        availableLabel.stringValue = available.map { L("Version %@ is available", $0) } ?? ""
        availableRow?.isHidden = available == nil
    }

    /// What the version rows say (FORETYPE_UPDATE_REPORT).
    var versionText: String {
        availableRow?.isHidden == false ? "\(versionLabel.stringValue) | \(availableLabel.stringValue) [\(installUpdate.title)]"
            : versionLabel.stringValue
    }

    @objc private func updatesChanged(_ sender: NSButton) {
        guard let updates = host?.updates else { return }
        switch sender {
        case autoCheck: updates.automaticallyChecks = autoCheck.state == .on
        case autoInstall: updates.automaticallyInstalls = autoInstall.state == .on
        default: return
        }
        refreshUpdates()
    }

    @objc private func checkForUpdates() { host?.updates?.checkForUpdates() }

    @objc private func pauseChosen() {
        guard let choice = PauseChoice(rawValue: pauseMenu.indexOfSelectedItem - 1) else { return }
        host?.pauseSuggestions(until: choice.until)
    }

    @objc private func resumeClicked() { host?.resumeSuggestions() }

    @objc private func powerChanged(_ sender: NSPopUpButton) {
        guard let host else { return }
        let s = host.settings
        let i = max(0, sender.indexOfSelectedItem)
        switch sender {
        case battery: s.batteryMode = PowerPolicy.BatteryMode.allCases[i]
        case lowPower: s.lowPowerMode = PowerPolicy.LowPowerMode.allCases[i]
        case batteryLevel: s.pauseBelowBattery = PowerPolicy.batteryLevels[i]
        default: return
        }
        host.powerSettingsChanged()
    }

    @objc private func loginChanged() {
        AppLocation.setOpensAtLogin(openAtLogin.state == .on)
        refresh()
    }
}

// MARK: Typing

/// How suggestions read and what they offer while you type, and the keys.
final class TypingPane: PreferencesPane {
    private let length = NSPopUpButton()
    private let sentenceEnd = NSButton(checkboxWithTitle: L("Stop at the end of a sentence"), target: nil, action: nil)
    private let emoji = NSButton(checkboxWithTitle: L("Offer emoji for :shortcodes"), target: nil, action: nil)
    private let autocorrect = NSButton(checkboxWithTitle: L("Offer a fix for a misspelled word"), target: nil, action: nil)
    private let typoGate = NSButton(checkboxWithTitle: L("Wait while a word looks misspelled"), target: nil, action: nil)
    private let midLine = NSButton(checkboxWithTitle: L("Suggest in the middle of a line (experimental)"), target: nil, action: nil)

    override func build() {
        length.addItems(withTitles: AppSettings.lengthPresets.map(\.name))
        for c in [length, sentenceEnd, emoji, autocorrect, typoGate, midLine] as [NSControl] {
            c.target = self
            c.action = #selector(changed(_:))
        }
        let w: CGFloat = 400
        let grid = Self.form([
            [Self.formLabel(L("Length:")), length],
            [NSGridCell.emptyContentView, sentenceEnd],
            [NSGridCell.emptyContentView, Self.note(L("When this is off, a suggestion can run on into the next sentence."), width: w)],
            [Self.formLabel(L("Typing aids:")), emoji],
            [NSGridCell.emptyContentView, Self.note(L("Type a colon and a name, like :tada, then Tab."), width: w)],
            [NSGridCell.emptyContentView, autocorrect],
            [NSGridCell.emptyContentView, typoGate],
            [NSGridCell.emptyContentView, Self.note(L("Both use the macOS spell checker in your languages, and skip names, acronyms and words you have written before."), width: w)],
            [NSGridCell.emptyContentView, midLine],
            [NSGridCell.emptyContentView, Self.note(L("Up to three words, shown in a small card under the caret."), width: w)],
        ])
        add(grid, spacingAfter: 18)
        add(Self.separator())
        add(Self.note(L("Tab takes the next word, the key above Tab takes the whole suggestion, Esc dismisses it and Option-Tab types a real Tab. Ctrl + the key above Tab suggests where Foretype normally stays quiet; Ctrl-Option-Command + that key pauses it in the current app for 5 minutes. Option-click the menu-bar icon to pause or resume everywhere.")))
    }

    override func refresh() {
        guard let s = host?.settings else { return }
        length.selectItem(at: AppSettings.lengthPresets.firstIndex { $0.words == s.lengthWords } ?? 1)
        sentenceEnd.state = s.stopAtSentenceEnd ? .on : .off
        emoji.state = s.emoji ? .on : .off
        autocorrect.state = s.autocorrect ? .on : .off
        typoGate.state = s.typoGate ? .on : .off
        midLine.state = s.midLine ? .on : .off
    }

    @objc private func changed(_ sender: NSControl) {
        guard let host else { return }
        let s = host.settings
        switch sender {
        case length: s.lengthWords = AppSettings.lengthPresets[max(0, length.indexOfSelectedItem)].words
        case sentenceEnd: s.stopAtSentenceEnd = sentenceEnd.state == .on
        case emoji: s.emoji = emoji.state == .on
        case autocorrect: s.autocorrect = autocorrect.state == .on
        case typoGate: s.typoGate = typoGate.state == .on
        case midLine: s.midLine = midLine.state == .on
        default: return
        }
        host.settingsChanged()
    }
}

// MARK: Context

/// What suggestions may read besides the field itself: the text on screen around it. Each
/// source is a labelled section of `grid`, with its note and status rows under its switch.
final class ContextPane: PreferencesPane {
    private let screen = NSButton(checkboxWithTitle: L("Use text on screen near the field"), target: nil, action: nil)
    private let screenStatus = NSTextField(labelWithString: "")
    private let screenAllow = NSButton(title: L("Allow Screen Recording\u{2026}"), target: nil, action: nil)
    private let screenRelaunch = NSButton(title: L("Relaunch"), target: nil, action: nil)
    private let screenHint = PreferencesPane.note(Signing.staleGrantHint, width: 400)
    private var screenHintRow: NSGridRow?

    override func build() {
        screen.target = self
        screen.action = #selector(screenChanged)
        screenStatus.font = .systemFont(ofSize: 11)
        screenAllow.target = self
        screenAllow.action = #selector(allowScreen)
        screenAllow.controlSize = .small
        screenRelaunch.target = self
        screenRelaunch.action = #selector(relaunch)
        screenRelaunch.controlSize = .small
        let grid = Self.form([
            [Self.formLabel(L("Screen context:")), screen],
            [NSGridCell.emptyContentView, Self.note(L("Reads the text around the field you are typing in, such as the message you are answering, with on-device OCR. The image is discarded right away."), width: 400)],
            [NSGridCell.emptyContentView, Self.hstack([screenStatus, screenAllow, screenRelaunch])],
            [NSGridCell.emptyContentView, screenHint],
        ])
        screenHintRow = grid.cell(for: screenHint)?.row
        add(grid)
    }

    override func refresh() {
        guard let s = host?.settings else { return }
        screen.state = s.useScreenContext ? .on : .off
        let allowed = ScreenContextProvider.hasPermission
        screenStatus.stringValue = allowed ? "\u{2713} " + L("Screen Recording allowed") : L("Screen Recording not allowed yet")
        screenStatus.textColor = allowed ? .systemGreen : .secondaryLabelColor
        screenAllow.isHidden = allowed || !s.useScreenContext
        // macOS applies a new Screen Recording grant only when the app starts.
        screenRelaunch.isHidden = allowed || !s.useScreenContext || !s.askedForScreenRecording || !AppLocation.isBundledApp
        screenHint.isHidden = allowed || !s.useScreenContext || !Signing.isAdHocBundle
        screenHintRow?.isHidden = screenHint.isHidden
    }

    @objc private func screenChanged() {
        guard let host else { return }
        host.settings.useScreenContext = screen.state == .on
        host.settingsChanged()
    }

    @objc private func allowScreen() { host?.openScreenRecordingSettings() }

    @objc private func relaunch() { AppLocation.relaunch() }
}

// MARK: Personalization

/// Your note for the model (Instructions) and learning from your writing.
final class PersonalizationPane: PreferencesPane {
    private let instructionsSummary = NSTextField(labelWithString: "")
    private let learn = NSButton(checkboxWithTitle: L("Learn from my writing"), target: nil, action: nil)
    private let strength = NSSegmentedControl(labels: AppSettings.strengthNames, trackingMode: .selectOne, target: nil, action: nil)
    private let learned = NSTextField(labelWithString: "")
    private let importButton = NSButton(title: L("Import Writing\u{2026}"), target: nil, action: nil)

    override func build() {
        learn.target = self
        learn.action = #selector(toggled)
        strength.target = self
        strength.action = #selector(strengthChanged)
        learned.textColor = .secondaryLabelColor
        let delete = NSButton(title: L("Delete Writing History\u{2026}"), target: self, action: #selector(deleteHistory))
        importButton.target = self
        importButton.action = #selector(importWriting)
        let edit = NSButton(title: L("Edit\u{2026}"), target: self, action: #selector(editInstructions))
        instructionsSummary.textColor = .secondaryLabelColor
        instructionsSummary.lineBreakMode = .byTruncatingTail
        instructionsSummary.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        let w: CGFloat = 400
        let grid = Self.form([
            [Self.formLabel(L("Instructions:")), Self.hstack([edit, instructionsSummary])],
            [NSGridCell.emptyContentView, Self.note(L("A note about you and how you write, for all apps and for the app you were last in."), width: w)],
            [Self.formLabel(L("Your writing:")), learn],
            [NSGridCell.emptyContentView, Self.note(L("Off by default. Only fields where you accepted a suggestion are kept, only the text you typed there, at least 20 characters, never secure fields. Stored encrypted on this Mac (key in your Keychain); nothing leaves it."), width: w)],
            [Self.formLabel(L("Strength:")), strength],
            [NSGridCell.emptyContentView, Self.note(L("How strongly suggestions lean towards words you use often."), width: w)],
            [Self.formLabel(L("Learned:")), learned],
            [NSGridCell.emptyContentView, Self.hstack([importButton, delete])],
            [NSGridCell.emptyContentView, Self.note(L("Import adds text files you choose (.txt, .md), split into paragraphs, to learn your words."), width: w)],
        ])
        grid.row(at: 2).topPadding = 8
        add(grid)
    }

    override func refresh() {
        guard let host else { return }
        let s = host.settings
        let global = s.instructions.replacingOccurrences(of: "\n", with: " ")
        let apps = s.appInstructions.values.filter { !$0.isEmpty }.count
        var summary = global.isEmpty ? L("No note for all apps") : "\u{201C}\(global)\u{201D}"
        if s.instructionsAreDefault && !global.isEmpty { summary = L("Default: %@", summary) }
        if apps > 0 { summary += ", " + LCount(apps, "notes for %@ apps", one: "notes for %@ app") }
        instructionsSummary.stringValue = summary
        learn.state = s.personalize ? .on : .off
        strength.selectedSegment = min(max(s.personalizeStrength, 0), 2)
        strength.isEnabled = s.personalize
        importButton.isEnabled = s.personalize
        if !s.personalize {
            learned.stringValue = L("Nothing while this is off")
        } else if let h = host.historyStats() {
            learned.stringValue = LCount(h.records, "%@ texts", one: "%@ text") + ", " + LCount(h.words, "%@ words", one: "%@ word")
        } else {
            learned.stringValue = L("Available once Foretype is running")
        }
    }

    @objc private func toggled() { host?.setPersonalize(learn.state == .on) }

    @objc private func strengthChanged() {
        guard let host else { return }
        host.settings.personalizeStrength = strength.selectedSegment
        host.settingsChanged()
    }

    @objc private func deleteHistory() { host?.confirmDeleteHistory() }

    @objc private func importWriting() { host?.importWriting() }

    @objc private func editInstructions() { host?.openInstructions() }
}

// MARK: About You

final class AboutYouPane: PreferencesPane, NSTextFieldDelegate {
    private let enabled = NSButton(checkboxWithTitle: L("Fill in my details as I type"), target: nil, action: nil)
    private let inPrompt = NSButton(checkboxWithTitle: L("Also tell the model my name, job title and company"), target: nil, action: nil)
    private let fromContacts = NSButton(title: L("Fill from My Card in Contacts\u{2026}"), target: nil, action: nil)
    private let contactsNote = PreferencesPane.note(L("Fills only the empty fields. macOS asks once for access to Contacts."), width: 400)
    private var fields: [AboutYou.Field: NSTextField] = [:]
    private var uses: [AboutYou.Field: NSButton] = [:]

    override func build() {
        for b in [enabled, inPrompt] {
            b.target = self
            b.action = #selector(toggled(_:))
        }
        fromContacts.target = self
        fromContacts.action = #selector(fillFromContacts)
        let clear = NSButton(title: L("Clear All\u{2026}"), target: self, action: #selector(clearAll))
        let w: CGFloat = 400
        var rows: [[NSView]] = [
            [NSGridCell.emptyContentView, enabled, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, Self.note(L("When you type \u{201C}My email is\u{201D}, \u{201C}Call me on\u{201D} or end a letter with \u{201C}Regards,\u{201D}, Foretype offers your own detail, exactly, as ghost text. Tab inserts it. Stored encrypted on this Mac (key in your Keychain); nothing leaves it."), width: w), NSGridCell.emptyContentView],
        ]
        for f in AboutYou.Field.allCases {
            let t = NSTextField(string: "")
            t.delegate = self
            t.usesSingleLineMode = true
            t.cell?.isScrollable = true
            t.widthAnchor.constraint(equalToConstant: 310).isActive = true
            if f == .address { t.placeholderString = L("Street, city, postcode") }
            let use = NSButton(checkboxWithTitle: L("Use"), target: self, action: #selector(toggled(_:)))
            fields[f] = t
            uses[f] = use
            rows.append([Self.formLabel(f.label), t, use])
        }
        rows += [
            [NSGridCell.emptyContentView, inPrompt, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, Self.note(L("So suggestions use your name. Only with the built-in or Apple model; never sent to a server."), width: w), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, Self.hstack([fromContacts, clear]), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, contactsNote, NSGridCell.emptyContentView],
        ]
        let grid = Self.form(rows)
        for r in [0, 1] + Array(rows.count - 4 ..< rows.count) {
            grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: r, length: 1))
        }
        let contacts = MeCard.available
        fromContacts.isHidden = !contacts
        contactsNote.isHidden = !contacts
        grid.row(at: rows.count - 1).isHidden = !contacts
        add(grid)
    }

    override func refresh() {
        guard let host else { return }
        let v = host.aboutYou
        enabled.state = v.enabled ? .on : .off
        inPrompt.state = v.inPrompt ? .on : .off
        inPrompt.isEnabled = v.enabled
        for f in AboutYou.Field.allCases {
            // Leave the field the user is typing in alone.
            if let t = fields[f], t.currentEditor() == nil, t.stringValue != v[f] { t.stringValue = v[f] }
            uses[f]?.state = v.uses(f) ? .on : .off
            uses[f]?.isEnabled = v.enabled
        }
    }

    func controlTextDidChange(_ note: Notification) {
        guard let host, let t = note.object as? NSTextField, let f = fields.first(where: { $0.value === t })?.key else { return }
        var v = host.aboutYou
        v[f] = t.stringValue
        host.setAboutYou(v)
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let host else { return }
        var v = host.aboutYou
        if sender === enabled {
            v.enabled = enabled.state == .on
        } else if sender === inPrompt {
            v.inPrompt = inPrompt.state == .on
        } else if let f = uses.first(where: { $0.value === sender })?.key {
            v.setUses(f, sender.state == .on)
        }
        host.setAboutYou(v)
        refresh()
    }

    @objc private func fillFromContacts() {
        MeCard.read { [weak self] result in
            guard let self, let host = self.host else { return }
            let alert = NSAlert()
            switch result {
            case let .success(card):
                var v = host.aboutYou
                var filled = 0
                for (f, value) in card where v[f].trimmingCharacters(in: .whitespaces).isEmpty {
                    v[f] = value
                    filled += 1
                }
                host.setAboutYou(v)
                self.refresh()
                guard filled == 0 else { return }
                alert.messageText = L("Nothing new on your card")
                alert.informativeText = L("Your card in Contacts has nothing for the fields that are still empty.")
            case .failure(.denied):
                alert.messageText = L("Foretype can't read your Contacts")
                alert.informativeText = L("Allow it in System Settings \u{25B8} Privacy & Security \u{25B8} Contacts, then try again.")
            case .failure(.noCard):
                alert.messageText = L("No card in Contacts is marked as yours")
                alert.informativeText = L("In Contacts, select your card and choose Card \u{25B8} Make This My Card.")
            }
            if let window = self.view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    @objc private func clearAll() { host?.confirmClearAboutYou() }
}

// MARK: Apps

/// Apps whose default the user changed (suggestions off, or on where they are off by default).
final class AppsPane: PreferencesPane {
    private let list = AppList(minHeight: 44, maxHeight: 280)
    private let empty = PreferencesPane.note(L("You haven't changed any app yet. Add an app below, or choose \u{201C}Suggest in \u{2026}\u{201D} in the Foretype menu while that app is in front."))
    private let onlyApps = NSTextField(labelWithString: "")

    override func build() {
        empty.preferredMaxLayoutWidth = Self.width - 2 * Self.inset - 30
        add(Self.heading(L("Apps you changed")))
        add(list)
        add(Self.hstack([ActionButton.make(L("Add an App\u{2026}")) { [weak self] in self?.host?.addAppException() }]))
        add(Self.note(L("Remove returns an app to its default. Code editors, password managers, remote desktops and spreadsheets are off by default; terminals suggest only on AI-agent prompts.")))
        onlyApps.font = .systemFont(ofSize: 11)
        onlyApps.textColor = .systemOrange
        add(onlyApps)
    }

    override func refresh() {
        guard let s = host?.settings else { return }
        let apps = s.disabledApps.map { ($0, true) } + s.enabledApps.map { ($0, false) }
        list.setRows(apps.map { bundle, off in
            AppList.row(bundle: bundle, state: off ? L("Off") : L("On (off by default)"), stateColor: off ? .secondaryLabelColor : .systemGreen,
                        removeTip: L("Return %@ to its default")) { [weak self] in self?.remove(bundle, off: off) }
        }, empty: empty)
        onlyApps.stringValue = s.onlyApps.isEmpty ? "" : L("Development: limited to %@ (FORETYPE_ONLY_APPS)", s.onlyApps.joined(separator: ", "))
        onlyApps.isHidden = s.onlyApps.isEmpty
    }

    private func remove(_ bundle: String, off: Bool) {
        guard let host else { return }
        if off { host.settings.disabledApps.removeAll { $0 == bundle } } else { host.settings.enabledApps.removeAll { $0 == bundle } }
        host.settingsChanged()
    }
}

// MARK: Model

final class ModelPane: PreferencesPane, NSTextFieldDelegate {
    private let status = NSTextField(labelWithString: "")
    private let rows = NSStackView()
    private var rowKeys: [String] = []
    private var rowViews: [ModelRow] = []
    private let usage = NSTextField(labelWithString: "")
    private let backend = NSPopUpButton()
    private let url = NSTextField()
    private let modelName = NSTextField()
    private let apiKey = NSSecureTextField()
    /// The user edited the server fields: refreshes leave them alone until Apply.
    private var serverEdited = false

    override func build() {
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add(Self.hstack([Self.heading(L("Built-in models")), status]))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        add(rows)
        let show = NSButton(title: L("Show in Finder"), target: self, action: #selector(showFolder))
        show.controlSize = .small
        usage.textColor = .secondaryLabelColor
        add(Self.hstack([usage, show]), spacingAfter: 16)
        add(Self.separator())

        add(Self.heading(L("Where suggestions come from")))
        backend.addItems(withTitles: AppDelegate.backendTitles)
        backend.target = self
        backend.action = #selector(backendChanged)
        url.placeholderString = "http://127.0.0.1:8080"
        modelName.placeholderString = L("model name (OpenAI-compatible only)")
        for f in [url, modelName, apiKey] as [NSTextField] {
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        let apply = NSButton(title: L("Apply"), target: self, action: #selector(applyServer))
        let grid = Self.form([
            [Self.formLabel(L("Engine:")), backend],
            [Self.formLabel(L("Server URL:")), url],
            [Self.formLabel(L("Model:")), modelName],
            [Self.formLabel(L("API key:")), apiKey],
            [NSGridCell.emptyContentView, Self.note(L("A llama-server gives the same suggestions as the built-in engine. OpenAI-compatible servers (Ollama, LM Studio, a cloud provider) complete words you have started less well, about half the typing saved. The API key is kept in your Keychain."), width: 330)],
            [NSGridCell.emptyContentView, apply],
        ])
        add(grid)
    }

    override func refresh() {
        guard let host else { return }
        status.stringValue = host.engineStatus
        if !serverEdited { loadServer() }
        refreshRows()
    }

    /// Fills the server fields from the settings (on show, after Apply).
    func loadServer() {
        guard isViewLoaded, let s = host?.settings else { return }
        backend.selectItem(at: AppDelegate.backends.firstIndex(of: s.backend) ?? 0)
        url.stringValue = s.backendURL
        modelName.stringValue = s.backendModel
        apiKey.stringValue = ""
        apiKey.placeholderString = s.backendAPIKey.isEmpty ? L("optional") : L("saved; type to replace")
        serverEdited = false
        enableServerFields()
    }

    private func enableServerFields() {
        let kind = AppDelegate.backends[max(0, backend.indexOfSelectedItem)]
        url.isEnabled = kind != "local"
        apiKey.isEnabled = kind != "local"
        modelName.isEnabled = kind == "openai"
    }

    /// Rebuilds the model rows when the set of entries changed, otherwise updates them in
    /// place (download progress). Returns true when rows were added or removed.
    @discardableResult
    func refreshRows() -> Bool {
        guard let host else { return false }
        let entries = modelEntries(host)
        usage.stringValue = L("Models folder: %@ on disk", AppDelegate.bytes(host.models.diskUsage()))
        let keys = entries.map(\.key)
        if keys == rowKeys {
            for (row, e) in zip(rowViews, entries) { row.update(e) }
            return false
        }
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = entries.map { e in
            let r = ModelRow()
            r.update(e)
            rows.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            return r
        }
        rowKeys = keys
        return true
    }

    private func modelEntries(_ host: PreferencesHost) -> [ModelRow.Entry] {
        let models = host.models
        let files = models.localFiles()
        var out: [ModelRow.Entry] = []
        for m in models.catalog {
            let path = models.path(m)
            var e = ModelRow.Entry(key: "m:\(m.id)", title: m.name, badge: m.recommended ? L("recommended") : "")
            switch models.states[m.id] ?? .notInstalled {
            case .installed:
                let inUse = host.isModelInUse(path)
                let bytes = files.first { $0.model == m }?.bytes ?? m.bytes
                e.detail = L(inUse ? "%@ on disk \u{00B7} in use" : "%@ on disk", AppDelegate.bytes(bytes))
                e.inUse = inUse
                e.primary = inUse ? (L("In Use"), nil) : (L("Use"), { [weak host] in host?.useModelFile(path) } as () -> Void)
                e.secondary = (L("Delete\u{2026}"), { [weak host] in host?.confirmDeleteModel(path) })
            case let .downloading(p):
                e.detail = L("Downloading %1$@ of %2$@", formatPercent(p), m.sizeText)
                e.progress = p
                e.primary = (L("Cancel"), { models.cancel(m) })
            case let .paused(p):
                if let kept = models.keptBytes(m) {
                    e.detail = L("Paused at %1$@ of %2$@ (%3$@ kept until Foretype quits)", formatPercent(p), m.sizeText, AppDelegate.bytes(kept))
                } else {
                    e.detail = L("Paused at %1$@ of %2$@ (kept until Foretype quits)", formatPercent(p), m.sizeText)
                }
                e.progress = p
                e.primary = (L("Resume"), { [weak host] in host?.download(m) })
                e.secondary = (L("Discard"), { models.discardPaused(m) })
            case .verifying:
                e.detail = L("Verifying the checksum\u{2026}")
                e.progress = -1
            case let .failed(msg):
                e.detail = L("Download failed: %@", msg)
                e.failed = true
                e.primary = (L("Retry"), { [weak host] in host?.download(m) })
            case .notInstalled:
                e.detail = L("%1$@ download \u{00B7} %2$@", m.sizeText, m.license)
                e.primary = (L("Download"), { [weak host] in host?.download(m) })
            }
            out.append(e)
        }
        for f in files where f.model == nil {
            var e = ModelRow.Entry(key: "f:\(f.path)", title: f.fileName, badge: f.incomplete ? L("incomplete download") : L("not in the catalog"))
            let inUse = !f.incomplete && host.isModelInUse(f.path)
            e.detail = L(inUse ? "%@ on disk \u{00B7} in use" : "%@ on disk", AppDelegate.bytes(f.bytes))
            e.inUse = inUse
            if !f.incomplete {
                e.primary = inUse ? (L("In Use"), nil) : (L("Use"), { [weak host] in host?.useModelFile(f.path) } as () -> Void)
            }
            e.secondary = (L("Delete\u{2026}"), { [weak host] in host?.confirmDeleteModel(f.path) })
            out.append(e)
        }
        return out
    }

    @objc private func showFolder() {
        try? FileManager.default.createDirectory(at: ModelLocator.modelsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ModelLocator.modelsDir)
    }

    @objc private func backendChanged() {
        serverEdited = true
        enableServerFields()
    }

    func controlTextDidChange(_ obj: Notification) {
        serverEdited = true
    }

    @objc private func applyServer() {
        let kind = AppDelegate.backends[max(0, backend.indexOfSelectedItem)]
        host?.applyServer(backend: kind, url: url.stringValue, model: modelName.stringValue, apiKey: apiKey.stringValue)
        loadServer()
    }
}

/// One model file or catalog entry: name, state, progress, up to two buttons.
private final class ModelRow: NSStackView {
    struct Entry {
        let key: String
        let title: String
        let badge: String
        var detail = ""
        var inUse = false
        var failed = false
        /// 0...1 shows a bar, -1 an indeterminate one, nil none.
        var progress: Double?
        /// Title and action; a nil action shows a disabled button.
        var primary: (String, (() -> Void)?)?
        var secondary: (String, (() -> Void)?)?

        init(key: String, title: String, badge: String) {
            self.key = key
            self.title = title
            self.badge = badge
        }
    }

    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let primary = ActionButton.make("") {}
    private let secondary = ActionButton.make("") {}

    init() {
        super.init(frame: .zero)
        badge.font = .systemFont(ofSize: 10)
        badge.textColor = .tertiaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for b in [primary, secondary] { b.controlSize = .small }
        let names = NSStackView(views: [PreferencesPane.hstack([title, badge], spacing: 6), detail, bar])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        for v in [names, spacer, primary, secondary] { addArrangedSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ e: Entry) {
        title.stringValue = e.title
        title.font = e.inUse ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        badge.stringValue = e.badge
        badge.isHidden = e.badge.isEmpty
        detail.stringValue = e.detail
        detail.textColor = e.failed ? .systemRed : .secondaryLabelColor
        if let p = e.progress {
            bar.isHidden = false
            bar.isIndeterminate = p < 0
            if p < 0 { bar.startAnimation(nil) } else { bar.stopAnimation(nil); bar.doubleValue = p }
        } else {
            bar.isHidden = true
            bar.stopAnimation(nil)
        }
        for (button, spec) in [(primary, e.primary), (secondary, e.secondary)] {
            button.isHidden = spec == nil
            button.title = spec?.0 ?? ""
            button.handler = spec?.1
            button.isEnabled = spec?.1 != nil
        }
    }
}

// MARK: Statistics

final class StatisticsPane: PreferencesPane {
    /// Rows of the table: title, whether it is a sub-row (indented, secondary) and how to
    /// read the value from the counts.
    private static var rowSpecs: [(String, Bool, (UsageStats.Counts) -> Int)] {
        [(L("Keystrokes saved"), false, { $0.keystrokesSaved }),
         (L("Words inserted"), false, { $0.words }),
         (L("Characters inserted"), false, { $0.characters }),
         (L("Suggestions accepted"), false, { $0.accepts }),
         (L("Next word (Tab)"), true, { $0.wordAccepts }),
         (L("Whole suggestion"), true, { $0.allAccepts })]
    }
    private var cells: [[NSTextField]] = []
    private let since = NSTextField(labelWithString: "")

    override func build() {
        let header = ["", L("Today"), L("Last 7 days"), L("All time")].map { t -> NSView in
            let l = NSTextField(labelWithString: t)
            l.font = .boldSystemFont(ofSize: 12)
            return l
        }
        var grid: [[NSView]] = [header]
        for (i, (title, sub, _)) in Self.rowSpecs.enumerated() {
            // The first row is the headline number.
            let values = (0..<3).map { _ -> NSTextField in
                let l = NSTextField(labelWithString: "0")
                l.font = .monospacedDigitSystemFont(ofSize: 13, weight: i == 0 ? .semibold : .regular)
                l.alignment = .right
                return l
            }
            cells.append(values)
            let t = NSTextField(labelWithString: sub ? "    " + title : title)
            if i == 0 { t.font = .boldSystemFont(ofSize: 13) }
            if sub { t.textColor = .secondaryLabelColor }
            grid.append([t] + values)
        }
        let g = NSGridView(views: grid)
        g.columnSpacing = 28
        g.rowSpacing = 8
        g.rowAlignment = .firstBaseline
        for c in 1..<4 {
            g.column(at: c).xPlacement = .trailing
            g.column(at: c).width = 80
        }
        g.row(at: 0).bottomPadding = 4
        add(g, spacingAfter: 16)
        since.font = .systemFont(ofSize: 11)
        since.textColor = .secondaryLabelColor
        add(since)
        add(Self.note(L("Keystrokes saved are the characters Foretype typed for you minus the one key press each accept took. Only these numbers are stored (the last 30 days and the totals), never what you typed or where.")), spacingAfter: 16)
        let reset = NSButton(title: L("Reset Statistics\u{2026}"), target: self, action: #selector(resetClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(Self.hstack([spacer, reset]))
    }

    override func refresh() {
        guard let stats = host?.stats else { return }
        let columns = [stats.today, stats.lastDays(7), stats.total]
        for (r, spec) in Self.rowSpecs.enumerated() {
            for (c, counts) in columns.enumerated() {
                cells[r][c].stringValue = formatNumber(spec.2(counts))
            }
        }
        let f = DateFormatter()
        f.dateStyle = .long
        since.stringValue = stats.total.accepts == 0 ? L("Nothing accepted yet.") : L("Counting since %@.", f.string(from: stats.since))
    }

    @objc private func resetClicked() {
        let alert = NSAlert()
        alert.messageText = L("Reset the statistics?")
        alert.informativeText = L("Today's, the last 30 days' and the all-time counts go back to zero.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Reset"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { host?.stats.reset() }
    }
}
