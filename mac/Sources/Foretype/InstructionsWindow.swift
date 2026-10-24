import AppKit

/// Edits the custom instructions: one note for every app, one for the app the user was last
/// in and, when that was a web page, one for its website (each appended after the one before,
/// as Cotypist does). The first two start as the defaults (`DefaultInstructions`), which
/// Restore Defaults brings back; websites have none. Settings ▸ Personalization opens it on a
/// single website's note (`Sites.key`).
final class InstructionsWindowController: NSWindowController, NSWindowDelegate {
    /// The website section.
    enum Sites {
        /// The page the user was last on: its note can be kept for its host or for its whole
        /// domain (two separate notes, `texts` by key; a popup picks which one is edited).
        case page(Site, texts: [String: String])
        /// One saved note, by its key (Settings ▸ Personalization ▸ Edit…).
        case key(String, text: String)
    }

    struct Saved {
        /// Nil when the window didn't show it.
        var global: String?
        var app: (bundle: String, text: String)?
        /// By key; an empty text removes the note.
        var sites: [String: String] = [:]
    }

    private let globalView = NSTextView()
    private let appView = NSTextView()
    private let siteView = NSTextView()
    private let showsGlobal: Bool
    private let appBundle: String?
    /// The website notes the window edits, by key, and the one in `siteView`.
    private var siteKeys: [String] = []
    private var siteTexts: [String: String] = [:]
    private var siteKey: String?
    private let scope = NSPopUpButton()
    var onSave: ((Saved) -> Void)?

    /// `global` nil: only the website's note (with `sites` `.key`).
    init(global: String?, appName: String?, appBundle: String?, appText: String, sites: Sites?) {
        showsGlobal = global != nil
        self.appBundle = appName == nil ? nil : appBundle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Custom Instructions")
        super.init(window: window)
        window.delegate = self

        func label(_ text: String, bold: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 12)
            if !bold { l.textColor = .secondaryLabelColor }
            return l
        }
        // Three notes share the height two had.
        let editorHeight: CGFloat = global != nil && appName != nil && sites != nil ? 84 : 110
        func editor(_ view: NSTextView, _ text: String) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            view.isRichText = false
            view.font = .systemFont(ofSize: 13)
            view.string = text
            view.isVerticallyResizable = true
            view.textContainer?.widthTracksTextView = true
            view.autoresizingMask = [.width]
            scroll.documentView = view
            scroll.heightAnchor.constraint(equalToConstant: editorHeight).isActive = true
            return scroll
        }

        let save = NSButton(title: L("Save"), target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        // Fills in the default notes; Save keeps them (and later versions' defaults).
        let restore = NSButton(title: L("Restore Defaults"), target: self, action: #selector(restoreClicked))
        restore.isHidden = global == nil
        let buttons = NSStackView(views: [restore, NSView(), cancel, save])
        buttons.orientation = .horizontal

        var rows: [NSView] = []
        if let global {
            rows += [label(L("For all apps"), bold: true),
                     label(L("Who you are and how you write, for example \u{201C}I'm a product manager. Keep it friendly and short; British spelling.\u{201D}")),
                     editor(globalView, global)]
        }
        if let appName {
            rows += [label(L("For %@", appName), bold: true),
                     label(L("Added after the note above whenever you type in %@.", appName)),
                     editor(appView, appText)]
        }
        switch sites {
        case let .page(site, texts):
            siteKeys = site.keys
            siteTexts = texts
            // The host's own note unless only the domain has one.
            let start = siteKeys.first { !(texts[$0] ?? "").isEmpty } ?? siteKeys[0]
            siteKey = start
            scope.addItems(withTitles: siteKeys.map(Site.describe))
            scope.selectItem(at: siteKeys.firstIndex(of: start) ?? 0)
            scope.target = self
            scope.action = #selector(scopeChanged)
            scope.isEnabled = siteKeys.count > 1
            rows += [label(L("For this website"), bold: true),
                     PreferencesPane.hstack([label(L("Applies to:")), scope]),
                     label(L("Added after the notes above whenever you type on this website.")),
                     editor(siteView, texts[start] ?? "")]
        case let .key(key, text):
            siteKeys = [key]
            siteTexts = [key: text]
            siteKey = key
            rows += [label(L("For %@", Site.describe(key)), bold: true),
                     label(L("Added after the notes for all apps and for the app whenever you type on this website.")),
                     editor(siteView, text)]
        case nil:
            break
        }
        rows.append(buttons)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520),
        ])
        for v in rows {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: ceil(stack.fittingSize.height)))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The rows' height (`--settings-selftest`).
    var contentHeight: CGFloat {
        window?.contentView?.layoutSubtreeIfNeeded()
        return window?.contentView?.subviews.first.map { ceil($0.fittingSize.height) } ?? 0
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(showsGlobal ? globalView : siteView)
    }

    @objc private func scopeChanged() {
        let i = scope.indexOfSelectedItem
        guard let current = siteKey, siteKeys.indices.contains(i), siteKeys[i] != current else { return }
        siteTexts[current] = siteView.string
        siteKey = siteKeys[i]
        siteView.string = siteTexts[siteKeys[i]] ?? ""
    }

    @objc private func saveClicked() {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var saved = Saved()
        if showsGlobal { saved.global = trimmed(globalView.string) }
        if let appBundle { saved.app = (appBundle, trimmed(appView.string)) }
        if let siteKey { siteTexts[siteKey] = siteView.string }
        for key in siteKeys {
            let text = trimmed(siteTexts[key] ?? "")
            // Only notes that exist or were written: an untouched empty key stays absent.
            if !text.isEmpty || siteTexts[key] != nil { saved.sites[key] = text }
        }
        onSave?(saved)
        close()
    }

    @objc private func restoreClicked() {
        globalView.string = DefaultInstructions.shared.global
        if let appBundle { appView.string = DefaultInstructions.shared.apps[appBundle] ?? "" }
        // Websites have no default note.
        if siteKey != nil { siteView.string = "" }
    }

    @objc private func cancelClicked() {
        close()
    }
}
