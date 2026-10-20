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
}

/// The Settings window (menu: Settings…, Cmd-,): everything in the menu-bar menu plus the
/// per-app list, model files and disk use, the server fields and statistics, in toolbar
/// tabs. Every change applies immediately through the host; the menu stays a second way to
/// the common settings.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let tabs: PreferencesTabController
    private let panes: [PreferencesPane]
    private let modelPane: ModelPane
    private let statsPane: StatisticsPane

    init(host: PreferencesHost) {
        let model = ModelPane(title: "Model", host: host)
        let statistics = StatisticsPane(title: "Statistics", host: host)
        let panes: [PreferencesPane] = [GeneralPane(title: "General", host: host), PersonalizationPane(title: "Personalization", host: host),
                                        AppsPane(title: "Apps", host: host), model, statistics]
        let tabs = PreferencesTabController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        let symbols = ["gearshape", "person.crop.circle", "square.grid.2x2", "cpu", "chart.bar"]
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        modelPane.loadServer()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            tabs.fit(animated: false)
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
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
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        (tabViewItem?.viewController as? PreferencesPane)?.refresh()
        fit(animated: true)
    }

    /// Resizes the window to the selected pane's fitting size, keeping its top edge.
    func fit(animated: Bool) {
        guard selectedTabViewItemIndex >= 0, let pane = tabViewItems[selectedTabViewItemIndex].viewController,
              let window = view.window, let content = window.contentView else { return }
        pane.view.layoutSubtreeIfNeeded()
        let want = pane.view.fittingSize
        let dw = want.width - content.frame.width, dh = want.height - content.frame.height
        guard abs(dw) > 0.5 || abs(dh) > 0.5 else { return }
        var f = window.frame
        f.size.width += dw
        f.size.height += dh
        f.origin.y -= dh
        window.setFrame(f, display: true, animate: animated && window.isVisible)
    }
}

// MARK: - Panes

/// One tab: a vertical stack of rows, fixed width, as tall as its content.
class PreferencesPane: NSViewController {
    weak var host: PreferencesHost?
    let stack = NSStackView()
    static let width: CGFloat = 580
    static let inset: CGFloat = 24

    init(title: String, host: PreferencesHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: Self.inset, bottom: 20, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor),
            v.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        view = v
        build()
        refresh()
    }

    func build() {}
    func refresh() {}

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

// MARK: General

final class GeneralPane: PreferencesPane {
    private let enabled = NSButton(checkboxWithTitle: "Show suggestions as you type", target: nil, action: nil)
    private let length = NSPopUpButton()
    private let sentenceEnd = NSButton(checkboxWithTitle: "Stop at the end of a sentence", target: nil, action: nil)
    private let screen = NSButton(checkboxWithTitle: "Use text on screen near the field", target: nil, action: nil)
    private let screenStatus = NSTextField(labelWithString: "")
    private let screenAllow = NSButton(title: "Allow Screen Recording\u{2026}", target: nil, action: nil)
    private let instructionsSummary = NSTextField(labelWithString: "")

    override func build() {
        for (b, sel) in [(enabled, #selector(changed(_:))), (sentenceEnd, #selector(changed(_:))), (screen, #selector(changed(_:)))] {
            b.target = self
            b.action = sel
        }
        length.addItems(withTitles: AppSettings.lengthPresets.map(\.name))
        length.target = self
        length.action = #selector(changed(_:))
        screenAllow.target = self
        screenAllow.action = #selector(allowScreen)
        screenAllow.controlSize = .small
        screenStatus.font = .systemFont(ofSize: 11)
        let edit = NSButton(title: "Edit\u{2026}", target: self, action: #selector(editInstructions))
        instructionsSummary.textColor = .secondaryLabelColor
        instructionsSummary.lineBreakMode = .byTruncatingTail
        instructionsSummary.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true

        let w: CGFloat = 400
        let grid = Self.form([
            [Self.formLabel("Suggestions:"), enabled],
            [Self.formLabel("Length:"), length],
            [NSGridCell.emptyContentView, sentenceEnd],
            [NSGridCell.emptyContentView, Self.note("When this is off, a suggestion can run on into the next sentence.", width: w)],
            [Self.formLabel("Screen context:"), screen],
            [NSGridCell.emptyContentView, Self.note("Reads the text around the field you are typing in, such as the message you are answering, with on-device OCR. The image is discarded right away.", width: w)],
            [NSGridCell.emptyContentView, Self.hstack([screenStatus, screenAllow])],
            [Self.formLabel("Instructions:"), Self.hstack([edit, instructionsSummary])],
            [NSGridCell.emptyContentView, Self.note("A note about you and how you write, for all apps and for the app you were last in.", width: w)],
        ])
        add(grid, spacingAfter: 18)
        add(Self.separator())
        add(Self.note("Tab takes the next word, the key above Tab takes the whole suggestion, Esc dismisses it and Option-Tab types a real Tab. Ctrl + the key above Tab suggests where Foretype normally stays quiet; Ctrl-Option-Command + that key snoozes the app for 5 minutes."))
    }

    override func refresh() {
        guard let s = host?.settings else { return }
        enabled.state = s.enabled ? .on : .off
        length.selectItem(at: AppSettings.lengthPresets.firstIndex { $0.words == s.lengthWords } ?? 1)
        sentenceEnd.state = s.stopAtSentenceEnd ? .on : .off
        screen.state = s.useScreenContext ? .on : .off
        let allowed = ScreenContextProvider.hasPermission
        screenStatus.stringValue = allowed ? "\u{2713} Screen Recording allowed" : "Screen Recording not allowed yet"
        screenStatus.textColor = allowed ? .systemGreen : .secondaryLabelColor
        screenAllow.isHidden = allowed || !s.useScreenContext
        let global = s.instructions.replacingOccurrences(of: "\n", with: " ")
        let apps = s.appInstructions.count
        var summary = global.isEmpty ? "No note for all apps" : "\u{201C}\(global)\u{201D}"
        if apps > 0 { summary += ", notes for \(apps) app\(apps == 1 ? "" : "s")" }
        instructionsSummary.stringValue = summary
    }

    @objc private func changed(_ sender: NSControl) {
        guard let host else { return }
        let s = host.settings
        switch sender {
        case enabled: s.enabled = enabled.state == .on
        case length: s.lengthWords = AppSettings.lengthPresets[max(0, length.indexOfSelectedItem)].words
        case sentenceEnd: s.stopAtSentenceEnd = sentenceEnd.state == .on
        case screen: s.useScreenContext = screen.state == .on
        default: return
        }
        host.settingsChanged()
    }

    @objc private func allowScreen() { host?.openScreenRecordingSettings() }

    @objc private func editInstructions() { host?.openInstructions() }
}

// MARK: Personalization

final class PersonalizationPane: PreferencesPane {
    private let learn = NSButton(checkboxWithTitle: "Learn from my writing", target: nil, action: nil)
    private let strength = NSSegmentedControl(labels: ["Gentle", "Balanced", "Strong"], trackingMode: .selectOne, target: nil, action: nil)
    private let learned = NSTextField(labelWithString: "")

    override func build() {
        learn.target = self
        learn.action = #selector(toggled)
        strength.target = self
        strength.action = #selector(strengthChanged)
        learned.textColor = .secondaryLabelColor
        let delete = NSButton(title: "Delete Writing History\u{2026}", target: self, action: #selector(deleteHistory))
        let w: CGFloat = 400
        let grid = Self.form([
            [NSGridCell.emptyContentView, learn],
            [NSGridCell.emptyContentView, Self.note("Off by default. Only fields where you accepted a suggestion are kept, only the text you typed there, at least 20 characters, never secure fields. Stored encrypted on this Mac (key in your Keychain); nothing leaves it.", width: w)],
            [Self.formLabel("Strength:"), strength],
            [NSGridCell.emptyContentView, Self.note("How strongly suggestions lean towards words you use often.", width: w)],
            [Self.formLabel("Learned:"), learned],
            [NSGridCell.emptyContentView, delete],
        ])
        add(grid)
    }

    override func refresh() {
        guard let host else { return }
        let s = host.settings
        learn.state = s.personalize ? .on : .off
        strength.selectedSegment = min(max(s.personalizeStrength, 0), 2)
        strength.isEnabled = s.personalize
        if !s.personalize {
            learned.stringValue = "Nothing while this is off"
        } else if let h = host.historyStats() {
            learned.stringValue = "\(AppDelegate.count(h.records, "text")), \(AppDelegate.count(h.words, "word"))"
        } else {
            learned.stringValue = "Available once Foretype is running"
        }
    }

    @objc private func toggled() { host?.setPersonalize(learn.state == .on) }

    @objc private func strengthChanged() {
        guard let host else { return }
        host.settings.personalizeStrength = strength.selectedSegment
        host.settingsChanged()
    }

    @objc private func deleteHistory() { host?.confirmDeleteHistory() }
}

// MARK: Apps

final class AppsPane: PreferencesPane {
    private let list = NSStackView()
    private let empty = PreferencesPane.note("You haven't changed any app yet. To turn Foretype off (or on) in an app, open the Foretype menu while that app is in front and choose \u{201C}Suggest in \u{2026}\u{201D}.")
    private let onlyApps = NSTextField(labelWithString: "")

    override func build() {
        add(Self.heading("Apps you changed"))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 200),
        ])
        add(scroll)
        add(Self.note("Remove returns an app to its default. Code editors, password managers, remote desktops and spreadsheets are off by default; terminals suggest only on AI-agent prompts."))
        onlyApps.font = .systemFont(ofSize: 11)
        onlyApps.textColor = .systemOrange
        add(onlyApps)
    }

    override func refresh() {
        guard let s = host?.settings else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = s.disabledApps.map { ($0, "Off", true) } + s.enabledApps.map { ($0, "On (off by default)", false) }
        if rows.isEmpty {
            let pad = NSStackView(views: [empty])
            pad.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            list.addArrangedSubview(pad)
            pad.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            empty.preferredMaxLayoutWidth = Self.width - 2 * Self.inset - 30
        }
        for (i, (bundle, state, off)) in rows.enumerated() {
            let row = appRow(bundle: bundle, state: state, off: off)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            if i < rows.count - 1 {
                let sep = Self.separator()
                list.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        onlyApps.stringValue = s.onlyApps.isEmpty ? "" : "Development: limited to \(s.onlyApps.joined(separator: ", ")) (FORETYPE_ONLY_APPS)"
        onlyApps.isHidden = s.onlyApps.isEmpty
    }

    private func appRow(bundle: String, state: String, off: Bool) -> NSView {
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
        let id = NSTextField(labelWithString: icon == nil ? "not installed" : bundle)
        id.font = .systemFont(ofSize: 10)
        id.textColor = .tertiaryLabelColor
        let names = NSStackView(views: [title, id])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let status = NSTextField(labelWithString: state)
        status.textColor = off ? .secondaryLabelColor : .systemGreen
        let remove = ActionButton.make("Remove") { [weak self] in self?.remove(bundle, off: off) }
        remove.controlSize = .small
        remove.toolTip = "Return \(name) to its default"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, names, spacer, status, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        return row
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
        add(Self.hstack([Self.heading("Built-in models"), status]))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        add(rows)
        let show = NSButton(title: "Show in Finder", target: self, action: #selector(showFolder))
        show.controlSize = .small
        usage.textColor = .secondaryLabelColor
        add(Self.hstack([usage, show]), spacingAfter: 16)
        add(Self.separator())

        add(Self.heading("Where suggestions come from"))
        backend.addItems(withTitles: AppDelegate.backendTitles)
        backend.target = self
        backend.action = #selector(backendChanged)
        url.placeholderString = "http://127.0.0.1:8080"
        modelName.placeholderString = "model name (OpenAI-compatible only)"
        for f in [url, modelName, apiKey] as [NSTextField] {
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyServer))
        let grid = Self.form([
            [Self.formLabel("Engine:"), backend],
            [Self.formLabel("Server URL:"), url],
            [Self.formLabel("Model:"), modelName],
            [Self.formLabel("API key:"), apiKey],
            [NSGridCell.emptyContentView, Self.note("A llama-server gives the same suggestions as the built-in engine. OpenAI-compatible servers (Ollama, LM Studio, a cloud provider) complete words you have started less well, about half the typing saved. The API key is kept in your Keychain.", width: 330)],
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
        apiKey.placeholderString = s.backendAPIKey.isEmpty ? "optional" : "saved; type to replace"
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
        usage.stringValue = "Models folder: \(AppDelegate.bytes(host.models.diskUsage())) on disk"
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
            var e = ModelRow.Entry(key: "m:\(m.id)", title: m.name, badge: m.recommended ? "recommended" : "")
            switch models.states[m.id] ?? .notInstalled {
            case .installed:
                let inUse = host.isModelInUse(path)
                let bytes = files.first { $0.model == m }?.bytes ?? m.bytes
                e.detail = "\(AppDelegate.bytes(bytes)) on disk" + (inUse ? " \u{00B7} in use" : "")
                e.inUse = inUse
                e.primary = inUse ? ("In Use", nil) : ("Use", { [weak host] in host?.useModelFile(path) } as () -> Void)
                e.secondary = ("Delete\u{2026}", { [weak host] in host?.confirmDeleteModel(path) })
            case let .downloading(p):
                e.detail = String(format: "Downloading %.0f%% of %@", p * 100, m.sizeText)
                e.progress = p
                e.primary = ("Cancel", { models.cancel(m) })
            case let .paused(p):
                let kept = models.keptBytes(m).map { "\(AppDelegate.bytes($0)) " } ?? ""
                e.detail = String(format: "Paused at %.0f%% of %@ (%@kept until Foretype quits)", p * 100, m.sizeText, kept)
                e.progress = p
                e.primary = ("Resume", { [weak host] in host?.download(m) })
                e.secondary = ("Discard", { models.discardPaused(m) })
            case .verifying:
                e.detail = "Verifying the checksum\u{2026}"
                e.progress = -1
            case let .failed(msg):
                e.detail = "Download failed: \(msg)"
                e.failed = true
                e.primary = ("Retry", { [weak host] in host?.download(m) })
            case .notInstalled:
                e.detail = "\(m.sizeText) download \u{00B7} \(m.license)"
                e.primary = ("Download", { [weak host] in host?.download(m) })
            }
            out.append(e)
        }
        for f in files where f.model == nil {
            var e = ModelRow.Entry(key: "f:\(f.path)", title: f.fileName, badge: f.incomplete ? "incomplete download" : "not in the catalog")
            let inUse = !f.incomplete && host.isModelInUse(f.path)
            e.detail = "\(AppDelegate.bytes(f.bytes)) on disk" + (inUse ? " \u{00B7} in use" : "")
            e.inUse = inUse
            if !f.incomplete {
                e.primary = inUse ? ("In Use", nil) : ("Use", { [weak host] in host?.useModelFile(f.path) } as () -> Void)
            }
            e.secondary = ("Delete\u{2026}", { [weak host] in host?.confirmDeleteModel(f.path) })
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
    /// Rows of the table: title and how to read the value from the counts.
    private static let rowSpecs: [(String, (UsageStats.Counts) -> Int)] = [
        ("Keystrokes saved", { $0.keystrokesSaved }),
        ("Words inserted", { $0.words }),
        ("Characters inserted", { $0.characters }),
        ("Suggestions accepted", { $0.accepts }),
        ("    Next word (Tab)", { $0.wordAccepts }),
        ("    Whole suggestion", { $0.allAccepts }),
    ]
    private var cells: [[NSTextField]] = []
    private let since = NSTextField(labelWithString: "")

    override func build() {
        let header = ["", "Today", "Last 7 days", "All time"].map { t -> NSView in
            let l = NSTextField(labelWithString: t)
            l.font = .boldSystemFont(ofSize: 12)
            return l
        }
        var grid: [[NSView]] = [header]
        for (i, (title, _)) in Self.rowSpecs.enumerated() {
            // The first row is the headline number.
            let values = (0..<3).map { _ -> NSTextField in
                let l = NSTextField(labelWithString: "0")
                l.font = .monospacedDigitSystemFont(ofSize: 13, weight: i == 0 ? .semibold : .regular)
                l.alignment = .right
                return l
            }
            cells.append(values)
            let t = NSTextField(labelWithString: title)
            if i == 0 { t.font = .boldSystemFont(ofSize: 13) }
            if title.hasPrefix(" ") { t.textColor = .secondaryLabelColor }
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
        add(Self.note("Keystrokes saved are the characters Foretype typed for you minus the one key press each accept took. Only these numbers are stored (the last 30 days and the totals), never what you typed or where."), spacingAfter: 16)
        let reset = NSButton(title: "Reset Statistics\u{2026}", target: self, action: #selector(resetClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(Self.hstack([spacer, reset]))
    }

    override func refresh() {
        guard let stats = host?.stats else { return }
        let columns = [stats.today, stats.lastDays(7), stats.total]
        for (r, spec) in Self.rowSpecs.enumerated() {
            for (c, counts) in columns.enumerated() {
                cells[r][c].stringValue = AppDelegate.number(spec.1(counts))
            }
        }
        let f = DateFormatter()
        f.dateStyle = .long
        since.stringValue = stats.total.accepts == 0 ? "Nothing accepted yet." : "Counting since \(f.string(from: stats.since))."
    }

    @objc private func resetClicked() {
        let alert = NSAlert()
        alert.messageText = "Reset the statistics?"
        alert.informativeText = "Today's, the last 30 days' and the all-time counts go back to zero."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { host?.stats.reset() }
    }
}
