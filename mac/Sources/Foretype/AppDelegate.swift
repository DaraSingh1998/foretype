import AppKit
import ApplicationServices

/// Menu-bar agent: permissions, model discovery, engine start-up and the settings menu.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: Controller?
    private let settings = AppSettings()
    private var engineState = "starting"
    private var engineDetail = ""
    private var lastFrontApp: NSRunningApplication?
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "Foretype")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let me = ProcessInfo.processInfo.processIdentifier
        lastFrontApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != me {
                self?.lastFrontApp = app
            }
        }
        installSignalHandlers()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startEngine()
        } else {
            engineState = "waiting"
            engineDetail = "Grant Accessibility in System Settings"
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() {
                    t.invalidate()
                    self?.startEngine()
                }
            }
        }
    }

    /// Ctrl-C / kill from a terminal should still restore Chromium flags and free Metal.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    private func startEngine() {
        guard let model = ModelLocator.find(settings: settings) else {
            engineState = "error"
            engineDetail = "No model: put a .gguf in \(ModelLocator.modelsDir.path) or set FORETYPE_MODEL"
            Log.debug(engineDetail)
            return
        }
        let config: [String: Any] = ["model_path": model, "settings": settings.coreDict]
        let json = String(data: try! JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        guard let engine = EngineBridge(configJSON: json) else {
            engineState = "error"
            engineDetail = "Engine failed to start"
            return
        }
        // One system prompt, and only from the bundled app: a bare dev binary started from a
        // terminal would make macOS ask on behalf of the terminal.
        if settings.useScreenContext, Bundle.main.bundleIdentifier != nil,
           !ScreenContextProvider.hasPermission, !settings.askedForScreenRecording {
            settings.askedForScreenRecording = true
            CGRequestScreenCaptureAccess()
        }
        let c = Controller(engine: engine, settings: settings)
        c.onStatus = { [weak self] state, detail in
            self?.engineState = state
            self?.engineDetail = state == "ready" ? URL(fileURLWithPath: model).lastPathComponent : detail
        }
        if !c.start() {
            engineState = "error"
            engineDetail = "Could not create event taps (Accessibility permission?)"
        }
        controller = c
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Foretype \u{2014} \(engineState)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if !engineDetail.isEmpty {
            let detail = NSMenuItem(title: engineDetail, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Suggestions On", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.enabled ? .on : .off
        menu.addItem(enabled)

        let lengthItem = NSMenuItem(title: "Suggestion Length", action: nil, keyEquivalent: "")
        let lengthMenu = NSMenu()
        for (i, preset) in AppSettings.lengthPresets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(setLength(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = settings.lengthWords == preset.words ? .on : .off
            lengthMenu.addItem(item)
        }
        lengthItem.submenu = lengthMenu
        menu.addItem(lengthItem)

        let screenItem = NSMenuItem(title: "Use Screen Context", action: #selector(toggleScreenContext), keyEquivalent: "")
        screenItem.target = self
        screenItem.state = settings.useScreenContext ? .on : .off
        menu.addItem(screenItem)
        if settings.useScreenContext, !ScreenContextProvider.hasPermission {
            let grant = NSMenuItem(title: "Allow Screen Recording\u{2026}", action: #selector(openScreenRecording), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        if let app = lastFrontApp, let bundle = app.bundleIdentifier {
            let name = app.localizedName ?? bundle
            let offByDefault = (controller?.engine.compatRule(bundle)["disabled"] as? Bool) ?? false
            let on = offByDefault ? settings.enabledApps.contains(bundle) : !settings.disabledApps.contains(bundle)
            let item = NSMenuItem(title: "Suggest in \(name)", action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.representedObject = [bundle, offByDefault] as [Any]
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            let item = NSMenuItem(title: "Open Accessibility Settings\u{2026}", action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Quit Foretype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        controller?.applySettings()
    }

    @objc private func setLength(_ sender: NSMenuItem) {
        settings.lengthWords = AppSettings.lengthPresets[sender.tag].words
        controller?.applySettings()
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let bundle = info[0] as? String,
              let offByDefault = info[1] as? Bool else { return }
        if offByDefault {
            var list = settings.enabledApps
            if let i = list.firstIndex(of: bundle) { list.remove(at: i) } else { list.append(bundle) }
            settings.enabledApps = list
        } else {
            var list = settings.disabledApps
            if let i = list.firstIndex(of: bundle) { list.remove(at: i) } else { list.append(bundle) }
            settings.disabledApps = list
        }
        controller?.applySettings()
    }

    @objc private func toggleScreenContext() {
        settings.useScreenContext.toggle()
        controller?.applySettings()
    }

    @objc private func openScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
