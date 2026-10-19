import AppKit
import ApplicationServices

/// First-run setup: the two permissions and the model download, each with its status.
/// Re-opened from the menu (Setup…) whenever something is missing.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let models: ModelManager
    private let settings: AppSettings
    /// Main thread: setup can start the engine (Accessibility granted and a model present).
    var onReady: (() -> Void)?

    private let axStatus = NSTextField(labelWithString: "")
    private let screenStatus = NSTextField(labelWithString: "")
    private let modelStatus = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let axButton = NSButton(title: "Open Settings", target: nil, action: nil)
    private let screenButton = NSButton(title: "Allow", target: nil, action: nil)
    private let modelButton = NSButton(title: "Download", target: nil, action: nil)
    private let doneButton = NSButton(title: "Start Foretype", target: nil, action: nil)
    private var timer: Timer?

    init(models: ModelManager, settings: AppSettings) {
        self.models = models
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Foretype"
        super.init(window: window)
        window.delegate = self
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func row(_ title: String, _ detail: String, status: NSTextField, button: NSButton, extra: NSView? = nil) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 13)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 12)
        d.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        var texts: [NSView] = [t, d, status]
        if let extra { texts.append(extra) }
        let left = NSStackView(views: texts)
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 3
        button.bezelStyle = .rounded
        let r = NSStackView(views: [left, button])
        r.orientation = .horizontal
        r.alignment = .top
        r.spacing = 12
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return r
    }

    private func build() {
        guard let window else { return }
        axButton.target = self; axButton.action = #selector(openAccessibility)
        screenButton.target = self; screenButton.action = #selector(allowScreen)
        modelButton.target = self; modelButton.action = #selector(modelClicked)
        doneButton.target = self; doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let rec = models.recommended
        let intro = NSTextField(wrappingLabelWithString:
            "Foretype suggests your next words in any app and runs entirely on this Mac. Nothing you type is sent anywhere.")
        let rows: [NSView] = [
            intro,
            row("Accessibility (required)", "Lets Foretype read the text field you are typing in and type the words you accept.",
                status: axStatus, button: axButton),
            row("Screen Recording (optional)", "Reads text near the field, such as the message you are answering, for better suggestions. Images are never stored.",
                status: screenStatus, button: screenButton),
            row("Language model", rec.map { "\($0.name), \($0.sizeText). \($0.license), downloaded from Hugging Face and checked against a pinned SHA-256." }
                ?? "No model in the catalog for this Mac.", status: modelStatus, button: modelButton, extra: progress),
        ]
        let buttons = NSStackView(views: [NSView(), doneButton])
        let stack = NSStackView(views: rows + [buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
        ])
        for v in rows + [buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private var modelReady: Bool {
        settings.backend != "local" || ModelLocator.find(settings: settings, recommendedFile: models.recommended?.file) != nil
    }

    /// Also called by the model manager's progress callbacks.
    func refresh() {
        let ax = AXIsProcessTrusted()
        axStatus.stringValue = ax ? "\u{2713} Granted" : "Not granted yet"
        axStatus.textColor = ax ? .systemGreen : .secondaryLabelColor
        axButton.isEnabled = !ax

        let screen = ScreenContextProvider.hasPermission
        screenStatus.stringValue = screen ? "\u{2713} Granted" : (settings.useScreenContext ? "Not granted" : "Off")
        screenStatus.textColor = screen ? .systemGreen : .secondaryLabelColor
        screenButton.isEnabled = !screen

        if settings.backend != "local" {
            modelStatus.stringValue = "Using your server: \(settings.backendURL)"
            modelButton.isEnabled = false
            progress.isHidden = true
        } else if let rec = models.recommended {
            switch models.states[rec.id] ?? .notInstalled {
            case .installed:
                modelStatus.stringValue = "\u{2713} Installed"
                modelStatus.textColor = .systemGreen
                modelButton.title = "Download"
                modelButton.isEnabled = false
                progress.isHidden = true
            case let .downloading(p):
                modelStatus.stringValue = String(format: "Downloading\u{2026} %.0f%%", p * 100)
                modelStatus.textColor = .secondaryLabelColor
                modelButton.title = "Cancel"
                modelButton.isEnabled = true
                progress.isHidden = false
                progress.doubleValue = p
            case .verifying:
                modelStatus.stringValue = "Verifying\u{2026}"
                modelButton.isEnabled = false
                progress.isIndeterminate = true
                progress.startAnimation(nil)
            case let .failed(msg):
                modelStatus.stringValue = "Download failed: \(msg)"
                modelStatus.textColor = .systemRed
                modelButton.title = "Retry"
                modelButton.isEnabled = true
                progress.isHidden = true
            case .notInstalled:
                let other = ModelLocator.find(settings: settings, recommendedFile: rec.file)
                modelStatus.stringValue = other.map { "\u{2713} Using \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Not downloaded"
                modelStatus.textColor = other == nil ? .secondaryLabelColor : .systemGreen
                modelButton.title = "Download"
                modelButton.isEnabled = true
                progress.isHidden = true
            }
            if case .verifying = models.states[rec.id] ?? .notInstalled {} else {
                progress.isIndeterminate = false
                progress.stopAnimation(nil)
            }
        }
        doneButton.isEnabled = ax && modelReady
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc private func allowScreen() {
        settings.useScreenContext = true
        settings.askedForScreenRecording = true
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @objc private func modelClicked() {
        guard let rec = models.recommended else { return }
        if case .downloading = models.states[rec.id] ?? .notInstalled {
            models.cancel(rec)
        } else {
            models.download(rec) { [weak self] result in
                if case let .success(path) = result { self?.settings.modelPath = path }
                self?.refresh()
            }
        }
        refresh()
    }

    @objc private func done() {
        settings.onboarded = true
        close()
        onReady?()
    }
}
