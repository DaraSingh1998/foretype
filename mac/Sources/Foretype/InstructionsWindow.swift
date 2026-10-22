import AppKit

/// Edits the custom instructions: one note for every app, plus one for the app the user
/// was last in (appended after the global note, as Cotypist does). Both start as the
/// defaults (`DefaultInstructions`), which Restore Defaults brings back.
final class InstructionsWindowController: NSWindowController, NSWindowDelegate {
    private let globalView = NSTextView()
    private let appView = NSTextView()
    private let appBundle: String?
    var onSave: ((_ global: String, _ app: String, _ bundle: String?) -> Void)?

    init(global: String, appName: String?, appBundle: String?, appText: String) {
        self.appBundle = appBundle
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
            scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
            return scroll
        }

        let save = NSButton(title: L("Save"), target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        // Fills in the default notes; Save keeps them (and later versions' defaults).
        let restore = NSButton(title: L("Restore Defaults"), target: self, action: #selector(restoreClicked))
        let buttons = NSStackView(views: [restore, NSView(), cancel, save])
        buttons.orientation = .horizontal

        var rows: [NSView] = [
            label(L("For all apps"), bold: true),
            label(L("Who you are and how you write, for example \u{201C}I'm a product manager. Keep it friendly and short; British spelling.\u{201D}")),
            editor(globalView, global),
        ]
        if let appName {
            appView.string = appText
            rows += [label(L("For %@", appName), bold: true),
                     label(L("Added after the note above whenever you type in %@.", appName)),
                     editor(appView, appText)]
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
        ])
        for v in rows where v !== buttons {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(globalView)
    }

    @objc private func saveClicked() {
        onSave?(globalView.string.trimmingCharacters(in: .whitespacesAndNewlines),
                appView.string.trimmingCharacters(in: .whitespacesAndNewlines), appBundle)
        close()
    }

    @objc private func restoreClicked() {
        globalView.string = DefaultInstructions.shared.global
        if let appBundle { appView.string = DefaultInstructions.shared.apps[appBundle] ?? "" }
    }

    @objc private func cancelClicked() {
        close()
    }
}
