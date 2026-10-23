import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// Menu-bar agent: permissions, model discovery, engine start-up, the settings menu and
/// the windows it opens. Also the Settings window's host, so both surfaces share one code
/// path for every change.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, PreferencesHost {
    private var statusItem: NSStatusItem!
    /// Attached to the status item only while it opens (`statusItemClicked`), so a click
    /// reaches the button first and Option-click can pause instead.
    private let statusMenu = NSMenu()
    private var controller: Controller?
    let settings = AppSettings()
    let models = ModelManager()
    let stats = UsageStats()
    let pause = PauseState()
    private let powerMonitor = PowerMonitor()
    private let sessionMonitor = SessionMonitor()
    private var lastOnBattery = false
    private var engineState = "starting" {
        didSet { updateIcon() }
    }
    private var engineDetail = ""
    /// The model file the running engine loaded; nil with a server backend.
    private var loadedModelPath: String?
    private var lastFrontApp: NSRunningApplication?
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var instructionsWindow: InstructionsWindowController?
    private var onboarding: OnboardingWindowController?
    private var preferences: PreferencesWindowController?
    private var updater: UpdateController?
    /// Settings ▸ About You. Read from its encrypted file only if one exists, so the Keychain
    /// is never touched for users who haven't entered anything. FORETYPE_ABOUT_YOU (testing)
    /// replaces it and keeps the store untouched.
    private(set) var aboutYou = AboutYou.fromEnvironment() ?? (AboutYouStore.exists ? AboutYouStore.load() : AboutYou()) {
        didSet { Log.mask(aboutYou.logMasks) }
    }
    private let aboutYouFromEnvironment = AboutYou.fromEnvironment() != nil
    private var aboutYouSave: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.mask(aboutYou.logMasks)
        AppIcon.useCheckoutIconIfUnbundled()
        // Opened from the disk image or Downloads: offer to move into Applications first (the
        // app then quits and the moved copy opens).
        if AppLocation.offerMove(settings: settings) { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        MenuBarIcon.attach(statusItem.button)
        statusMenu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        installMainMenu()
        startPowerWatch()

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
        models.onChange = { [weak self] _, _ in
            self?.onboarding?.refresh()
            self?.preferences?.modelsChanged()
        }
        stats.onChange = { [weak self] in self?.preferences?.statsChanged() }
        updater = UpdateController()
        updater?.isBusy = { [weak self] in self?.controller?.isShowingSuggestion ?? false }
        updater?.onAvailabilityChange = { [weak self] in self?.updateAvailabilityChanged() }
        updateIcon()

        // The setup window opens when something is missing, and on the bundled app's first
        // run. A dev binary started from a terminal with everything in place skips it.
        let ready = AXIsProcessTrusted() && modelReady
        if !ready || (!settings.onboarded && Bundle.main.bundleIdentifier != nil) {
            engineState = "setup"
            engineDetail = L("Finish setup to start")
            showOnboarding()
        } else {
            startEngine()
        }
        writeUpdateReport()
    }

    /// Accessory apps show no menu bar, but key equivalents still go through the main menu.
    /// This one is never seen: it gives Foretype's own windows Cmd-, (Settings), Cmd-W,
    /// Cmd-Q and the editing keys (copy and paste in the instruction and server fields).
    private func installMainMenu() {
        let app = NSMenu()
        let prefs = NSMenuItem(title: L("Settings\u{2026}"), action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        app.addItem(prefs)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        app.addItem(NSMenuItem(title: L("Quit Foretype"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let main = NSMenu()
        for submenu in [app, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private var modelReady: Bool {
        settings.backend != "local" || ModelLocator.find(settings: settings, recommendedFile: models.recommended?.file) != nil
    }

    private func showOnboarding() {
        let w = onboarding ?? OnboardingWindowController(models: models, settings: settings)
        w.onReady = { [weak self] in self?.startEngine() }
        onboarding = w
        w.show()
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
        // FORETYPE_UPDATE_REPORT: SIGUSR1 chooses the menu's update line, as a click would.
        if Self.updateReport != nil {
            signal(SIGUSR1, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            src.setEventHandler { [weak self] in
                self?.checkForUpdates()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.writeUpdateReport() }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Starts the engine, or swaps a new one into the running controller (model or server
    /// changed).
    private func startEngine() {
        guard AXIsProcessTrusted() else {
            engineState = "waiting"
            engineDetail = L("Grant Accessibility in System Settings")
            return
        }
        // Paused already (a relaunch while paused): the core must not start loading the model.
        var config: [String: Any] = ["settings": Controller.coreSettings(settings, paused: pause.isPaused, saveEnergy: saveEnergy)]
        var label: String
        if settings.backend == "local" {
            guard let model = ModelLocator.find(settings: settings, recommendedFile: models.recommended?.file) else {
                engineState = "error"
                engineDetail = L("No model yet: open Setup\u{2026} to download one")
                showOnboarding()
                return
            }
            config["model_path"] = model
            label = URL(fileURLWithPath: model).lastPathComponent
            loadedModelPath = model
        } else if settings.backend == "apple" {
            // The core asks the shell, which asks Foundation Models (AppleModel.swift).
            config["backend"] = "shell"
            label = L("Apple on-device model")
        } else {
            config["backend"] = settings.backend
            config["backend_url"] = settings.backendURL
            config["backend_model"] = settings.backendModel
            config["backend_api_key"] = settings.backendAPIKey
            label = settings.backendURL
            loadedModelPath = nil
        }
        if settings.personalize, let key = HistoryStore.keyHex() {
            config["history_path"] = HistoryStore.path
            config["history_key_hex"] = key
        }
        let json = String(data: try! JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        guard let engine = EngineBridge(configJSON: json) else {
            engineState = "error"
            engineDetail = L("Engine failed to start")
            return
        }
        if settings.backend == "apple" { engine.setCompleter(AppleModel.complete) }
        // One system prompt, and only from the bundled app: a bare dev binary started from a
        // terminal would make macOS ask on behalf of the terminal.
        if settings.useScreenContext, Bundle.main.bundleIdentifier != nil,
           !ScreenContextProvider.hasPermission, !settings.askedForScreenRecording {
            settings.askedForScreenRecording = true
            CGRequestScreenCaptureAccess()
        }
        let onStatus: (String, String) -> Void = { [weak self] state, detail in
            self?.engineState = state
            // The core's details are English (error texts, file paths); "model unloaded" is the
            // one fixed text it sends.
            self?.engineDetail = state == "ready" ? label : detail == "model unloaded" ? L("model unloaded") : detail
            self?.preferences?.refresh()
        }
        if let c = controller {
            c.onStatus = onStatus
            c.replaceEngine(engine)
            return
        }
        let c = Controller(engine: engine, settings: settings, stats: stats)
        c.onStatus = onStatus
        c.detailsJSON = aboutYou.coreJSON()
        c.saveEnergy = saveEnergy
        if !c.start(paused: pause.isPaused) {
            engineState = "error"
            engineDetail = L("Could not create event taps (Accessibility permission?)")
        }
        controller = c
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let pending = aboutYouSave, !pending.isCancelled { pending.perform() }
        controller?.shutdown()
        models.saveForRelaunch()
    }

    // MARK: - Pause and power

    /// The power and session monitors; their changes reach the controller through `applyPause`.
    private func startPowerWatch() {
        pause.onChange = { [weak self] in self?.applyPause() }
        powerMonitor.onChange = { [weak self] _ in self?.powerChanged() }
        sessionMonitor.onChange = { [weak self] event, on in
            let reason: PauseState.SystemReason
            switch event {
            case .sleep: reason = .sleep
            case .lock: reason = .lock
            case .displaySleep: reason = .displaySleep
            }
            self?.pause.setSystem(reason, on)
        }
        lastOnBattery = powerMonitor.state.onBattery
        powerMonitor.start()
        sessionMonitor.start()
        powerChanged()
    }

    private var powerDecision: PowerPolicy.Decision {
        PowerPolicy.decide(powerMonitor.state, battery: settings.batteryMode, lowPower: settings.lowPowerMode,
                           pauseBelow: settings.pauseBelowBattery)
    }

    /// Lighter work: the power rules ask for it, or they would pause and the user resumed anyway.
    private var saveEnergy: Bool { powerDecision.saveEnergy || pause.powerSetAside }

    /// The power state or the power settings changed.
    private func powerChanged() {
        let s = powerMonitor.state
        Log.debug("power: battery=\(s.onBattery) \(s.batteryPercent.map { "\($0)%" } ?? "-") lowPower=\(s.lowPowerMode) thermal=\(s.thermal.rawValue)")
        let justPluggedIn = lastOnBattery && !s.onBattery
        lastOnBattery = s.onBattery
        pause.setPower(powerDecision.pause, justPluggedIn: justPluggedIn)
        applyPause()
    }

    /// Pushes the pause and the power rules to the controller, the icon and Settings.
    private func applyPause() {
        if let c = controller {
            let save = saveEnergy
            let saveChanged = c.saveEnergy != save
            c.saveEnergy = save
            if c.isPaused != pause.isPaused {
                c.setPaused(pause.isPaused)
            } else if saveChanged {
                c.applySettings()
            }
        }
        updateIcon()
        preferences?.refresh()
    }

    private func updateIcon() {
        let icon: MenuBarIcon.State
        if pause.isUserPaused || pause.systemReason != nil {
            icon = .paused
        } else if pause.isPaused {
            icon = .powerPaused
        } else {
            icon = Self.menuBarState(engineState)
        }
        MenuBarIcon.set(icon, badge: updater?.needsAttention ?? false)
        var tip = pauseDescription.map { "Foretype \u{2014} \($0)" } ?? "Foretype"
        if let version = updater?.availableVersion { tip += "\n" + L("Version %@ is available", version) }
        statusItem?.button?.toolTip = tip
    }

    /// "Paused until 3:45 PM", "Paused \u{2014} Low Power Mode"; nil while not paused.
    var pauseDescription: String? {
        guard pause.isPaused else { return nil }
        switch pause.systemReason {
        case .sleep: return L("Paused while the Mac sleeps")
        case .lock: return L("Paused while the screen is locked")
        case .displaySleep: return L("Paused while the display sleeps")
        case nil: break
        }
        if pause.isUserPaused, let until = pause.userUntil {
            return pause.untilResumed ? L("Paused until you resume") : L("Paused until %@", Self.pauseTime(until))
        }
        switch pause.powerReason {
        case .thermal: return L("Paused \u{2014} the Mac is running hot")
        case .batteryLow: return L("Paused \u{2014} battery below %@", formatPercent(Double(settings.pauseBelowBattery) / 100))
        case .lowPower: return L("Paused \u{2014} Low Power Mode")
        case .battery: return L("Paused \u{2014} on battery power")
        case nil: return L("Paused")
        }
    }

    /// "3:45 PM" today, "Tomorrow, 6:00 AM" otherwise.
    static func pauseTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        if !Calendar.current.isDateInToday(date) {
            f.dateStyle = .medium
            f.doesRelativeDateFormatting = true
        }
        return f.string(from: date)
    }

    func pauseSuggestions(until: Date?) {
        pause.pause(until: until)
    }

    func resumeSuggestions() {
        if pause.isUserPaused { pause.resume() } else if pause.powerReason != nil { pause.setPowerAside() }
    }

    func powerSettingsChanged() {
        powerChanged()
    }

    var powerState: PowerState { powerMonitor.state }

    /// Option-click on the menu-bar icon, and foretype://toggle.
    private func togglePause() {
        if pause.isPaused, pause.systemReason == nil { resumeSuggestions() } else if !pause.isPaused { pause.pause(until: nil) }
    }

    /// The status item's button: Option-click pauses or resumes, any other click opens the menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let e = NSApp.currentEvent, e.type == .leftMouseDown, e.modifierFlags.contains(.option) {
            togglePause()
            return
        }
        // With a menu attached the button opens it, tracking it until it closes.
        statusItem.menu = statusMenu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    /// foretype://pause (until resumed), foretype://pause?minutes=N, foretype://resume,
    /// foretype://toggle. `resume` ends the user's pause only; the power rules still apply.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "foretype" {
            let action = (url.host ?? url.path).lowercased()
            let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "minutes" }?.value.flatMap(Double.init)
            Log.debug("url: \(action)\(minutes.map { " \($0) min" } ?? "")")
            switch action {
            case "pause": pause.pause(until: minutes.flatMap { $0 > 0 ? Date().addingTimeInterval($0 * 60) : nil })
            case "resume": pause.resume()
            case "toggle": togglePause()
            default: break
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = pause.isPaused ? L("paused") : Self.stateName(engineState)
        let title = NSMenuItem(title: "Foretype \u{2014} \(state)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let text = pauseDescription ?? (engineDetail.isEmpty ? nil : engineDetail) {
            let detail = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        if stats.total.accepts > 0 {
            let today = LCount(stats.today.keystrokesSaved, "%@ keystrokes", one: "%@ keystroke")
            let saved = NSMenuItem(title: L("Saved %1$@ today \u{00B7} %2$@ in all", today, formatNumber(stats.total.keystrokesSaved)),
                                   action: nil, keyEquivalent: "")
            saved.isEnabled = false
            menu.addItem(saved)
        }
        if let version = updater?.availableVersion {
            // Sparkle's window for it: release notes, Install Update, Skip This Version.
            let update = NSMenuItem(title: L("Update Available: %@ \u{2014} Install\u{2026}", version),
                                    action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(.separator())

        if pause.isUserPaused, let until = pause.userUntil {
            let title = pause.untilResumed ? L("Resume") : L("Resume (paused until %@)", Self.pauseTime(until))
            let resume = NSMenuItem(title: title, action: #selector(resumeChosen), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        } else if pause.powerReason != nil, pause.systemReason == nil {
            let title = powerMonitor.state.onBattery ? L("Resume Anyway (until plugged in)") : L("Resume Anyway")
            let resume = NSMenuItem(title: title, action: #selector(resumeChosen), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        }
        if !pause.isUserPaused {
            let pauseItem = NSMenuItem(title: L("Pause"), action: nil, keyEquivalent: "")
            let pm = NSMenu()
            for choice in PauseChoice.allCases {
                let item = NSMenuItem(title: choice.title, action: #selector(pauseChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = choice.rawValue
                pm.addItem(item)
            }
            pm.addItem(.separator())
            let hint = NSMenuItem(title: L("Option-click the menu-bar icon to pause or resume"), action: nil, keyEquivalent: "")
            hint.isEnabled = false
            pm.addItem(hint)
            pauseItem.submenu = pm
            menu.addItem(pauseItem)
        }
        menu.addItem(.separator())

        let lengthItem = NSMenuItem(title: L("Suggestion Length"), action: nil, keyEquivalent: "")
        let lengthMenu = NSMenu()
        for (i, preset) in AppSettings.lengthPresets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(setLength(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = settings.lengthWords == preset.words ? .on : .off
            lengthMenu.addItem(item)
        }
        lengthMenu.addItem(.separator())
        let sentence = NSMenuItem(title: L("Stop at Sentence End"), action: #selector(toggleSentenceEnd), keyEquivalent: "")
        sentence.target = self
        sentence.state = settings.stopAtSentenceEnd ? .on : .off
        lengthMenu.addItem(sentence)
        lengthItem.submenu = lengthMenu
        menu.addItem(lengthItem)

        let screenItem = NSMenuItem(title: L("Use Screen Context"), action: #selector(toggleScreenContext), keyEquivalent: "")
        screenItem.target = self
        screenItem.state = settings.useScreenContext ? .on : .off
        menu.addItem(screenItem)
        if settings.useScreenContext, !ScreenContextProvider.hasPermission {
            let grant = NSMenuItem(title: L("Allow Screen Recording\u{2026}"), action: #selector(openScreenRecording), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        if let app = lastFrontApp, let bundle = app.bundleIdentifier {
            let name = app.localizedName ?? bundle
            let offByDefault = (controller?.engine.compatRule(bundle)["disabled"] as? Bool) ?? false
            let on = offByDefault ? settings.enabledApps.contains(bundle) : !settings.disabledApps.contains(bundle)
            let item = NSMenuItem(title: L("Suggest in %@", name), action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.representedObject = [bundle, offByDefault] as [Any]
            menu.addItem(item)
            if let until = controller?.snoozed[bundle], until > Date() {
                let title = until == .distantFuture ? L("Paused in %@ until it quits \u{2014} Resume", name)
                    : L("Paused in %1$@ until %2$@ \u{2014} Resume", name, Self.pauseTime(until))
                let s = NSMenuItem(title: title, action: #selector(unsnooze(_:)), keyEquivalent: "")
                s.target = self
                s.representedObject = bundle
                menu.addItem(s)
            } else if on, controller != nil {
                let appPause = NSMenuItem(title: L("Pause in %@", name), action: nil, keyEquivalent: "")
                let am = NSMenu()
                for (i, title) in [L("For 5 Minutes"), L("For 1 Hour"), L("Until %@ Quits", name)].enumerated() {
                    let a = NSMenuItem(title: title, action: #selector(snoozeChosen(_:)), keyEquivalent: "")
                    a.target = self
                    a.tag = i
                    a.representedObject = bundle
                    am.addItem(a)
                }
                am.addItem(.separator())
                let hint = NSMenuItem(title: L("Ctrl-Option-Command + the key above Tab: 5 minutes"), action: nil, keyEquivalent: "")
                hint.isEnabled = false
                am.addItem(hint)
                appPause.submenu = am
                menu.addItem(appPause)
            }
        }
        menu.addItem(.separator())
        menu.addItem(.separator())
        let personal = NSMenuItem(title: L("Personalization"), action: nil, keyEquivalent: "")
        let pm = NSMenu()
        let learn = NSMenuItem(title: L("Learn From My Writing"), action: #selector(togglePersonalize), keyEquivalent: "")
        learn.target = self
        learn.state = settings.personalize ? .on : .off
        pm.addItem(learn)
        if settings.personalize {
            for (i, name) in AppSettings.strengthNames.enumerated() {
                let item = NSMenuItem(title: name, action: #selector(setStrength(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.indentationLevel = 1
                item.state = settings.personalizeStrength == i ? .on : .off
                pm.addItem(item)
            }
            if let stats = controller?.engine.historyStats() {
                let info = NSMenuItem(title: L("%1$@, %2$@ learned", LCount(stats.records, "%@ texts", one: "%@ text"),
                                                    LCount(stats.words, "%@ words", one: "%@ word")),
                                      action: nil, keyEquivalent: "")
                info.isEnabled = false
                pm.addItem(info)
            }
        }
        pm.addItem(.separator())
        let imp = NSMenuItem(title: L("Import Writing\u{2026}"), action: settings.personalize ? #selector(importWritingMenu) : nil, keyEquivalent: "")
        imp.target = self
        pm.addItem(imp)
        let del = NSMenuItem(title: L("Delete Writing History\u{2026}"), action: #selector(deleteHistory), keyEquivalent: "")
        del.target = self
        pm.addItem(del)
        let note = NSMenuItem(title: L("Stored encrypted on this Mac; only texts where you accepted a suggestion."), action: nil, keyEquivalent: "")
        note.isEnabled = false
        pm.addItem(note)
        personal.submenu = pm
        menu.addItem(personal)
        let instr = NSMenuItem(title: L("Custom Instructions\u{2026}"), action: #selector(openInstructionsMenu), keyEquivalent: "")
        instr.target = self
        menu.addItem(instr)
        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: L("Model"), action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu()
        menu.addItem(modelItem)
        let prefs = NSMenuItem(title: L("Settings\u{2026}"), action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let setup = NSMenuItem(title: L("Setup\u{2026}"), action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        if let updater, updater.isConfigured {
            let check = NSMenuItem(title: L("Check for Updates\u{2026}"), action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let item = NSMenuItem(title: L("Open Accessibility Settings\u{2026}"), action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: L("Quit Foretype"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Catalog models (download state or size on disk), other GGUFs in the folder, delete,
    /// disk usage, server.
    private func modelMenu() -> NSMenu {
        let mm = NSMenu()
        let active = settings.backend == "local" ? ModelLocator.find(settings: settings, recommendedFile: models.recommended?.file) : nil
        let files = models.localFiles()
        for m in models.catalog {
            let name = m.recommended ? L("%@ (recommended)", m.name) : m.name
            let title: String
            switch models.states[m.id] ?? .notInstalled {
            case let .downloading(p): title = L("%1$@ \u{2014} %2$@, downloading %3$@, click to cancel", name, m.sizeText, formatPercent(p))
            case let .paused(p): title = L("%1$@ \u{2014} %2$@, paused at %3$@, click to resume", name, m.sizeText, formatPercent(p))
            case .verifying: title = L("%@ \u{2014} verifying\u{2026}", name)
            case .notInstalled, .failed: title = L("%1$@ \u{2014} %2$@, download", name, m.sizeText)
            case .installed:
                let bytes = files.first { $0.model == m }?.bytes ?? m.bytes
                title = L("%1$@ \u{2014} %2$@ on disk", name, Self.bytes(bytes))
            }
            let item = NSMenuItem(title: title, action: #selector(modelChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.id
            item.state = active == models.path(m) ? .on : .off
            mm.addItem(item)
        }
        // GGUFs that aren't (complete) catalog models: ModelLocator may pick one, so they can
        // be chosen too.
        for f in files where f.model == nil && !f.incomplete {
            let item = NSMenuItem(title: L("%1$@ \u{2014} %2$@ on disk", f.fileName, Self.bytes(f.bytes)), action: #selector(fileChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = f.path
            item.state = active == f.path ? .on : .off
            mm.addItem(item)
        }
        mm.addItem(.separator())
        if !files.isEmpty {
            let delete = NSMenuItem(title: L("Delete a Model"), action: nil, keyEquivalent: "")
            let dm = NSMenu()
            for f in files {
                var title = "\(f.name) \u{2014} \(Self.bytes(f.bytes))"
                if f.incomplete { title = L("%@ (incomplete download)", title) }
                if isModelInUse(f.path) { title = L("%@ (in use)", title) }
                let item = NSMenuItem(title: title + "\u{2026}", action: #selector(deleteChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = f.path
                dm.addItem(item)
            }
            delete.submenu = dm
            mm.addItem(delete)
        }
        let usage = NSMenuItem(title: L("Models folder: %@ on disk", Self.bytes(models.diskUsage())), action: nil, keyEquivalent: "")
        usage.isEnabled = false
        mm.addItem(usage)
        mm.addItem(.separator())
        let server = NSMenuItem(title: L("Use a Server Instead\u{2026}"), action: #selector(configureServer), keyEquivalent: "")
        server.target = self
        server.state = settings.backend == "local" ? .off : .on
        mm.addItem(server)
        let folder = NSMenuItem(title: L("Show Models Folder"), action: #selector(showModelsFolder), keyEquivalent: "")
        folder.target = self
        mm.addItem(folder)
        return mm
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// The menu-bar glyph for an engine state while not paused (`updateIcon` shows the
    /// paused glyphs). The core's "paused" only lingers until its "idle" after a resume.
    static func menuBarState(_ state: String) -> MenuBarIcon.State {
        switch state {
        case "ready", "idle", "paused": return .active
        case "starting", "loading": return .loading
        default: return .error
        }
    }

    /// The engine state ("ready", "loading", ...) as the menu and the Settings window show it.
    static func stateName(_ state: String) -> String {
        switch state {
        case "starting": return L("starting")
        case "setup": return L("setup")
        case "waiting": return L("waiting")
        case "loading": return L("loading")
        case "ready": return L("ready")
        case "idle": return L("idle")
        case "paused": return L("paused")
        case "error": return L("error")
        default: return state
        }
    }

    @objc private func pauseChosen(_ sender: NSMenuItem) {
        guard let choice = PauseChoice(rawValue: sender.tag) else { return }
        pause.pause(until: choice.until)
    }

    @objc private func resumeChosen() {
        resumeSuggestions()
    }

    @objc private func snoozeChosen(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        let until = [Date().addingTimeInterval(300), Date().addingTimeInterval(3600), Date.distantFuture][sender.tag]
        controller?.snooze(bundle, until: until)
    }

    @objc private func setLength(_ sender: NSMenuItem) {
        settings.lengthWords = AppSettings.lengthPresets[sender.tag].words
        settingsChanged()
    }

    @objc private func toggleSentenceEnd() {
        settings.stopAtSentenceEnd.toggle()
        settingsChanged()
    }

    func addAppException() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = L("Choose an app to change: Foretype turns off there, or on where it is off by default.")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url)?.bundleIdentifier, bundle != Bundle.main.bundleIdentifier else { return }
        let offByDefault = (controller?.engine.compatRule(bundle)["disabled"] as? Bool) ?? false
        if offByDefault {
            if !settings.enabledApps.contains(bundle) { settings.enabledApps.append(bundle) }
        } else if !settings.disabledApps.contains(bundle) {
            settings.disabledApps.append(bundle)
        }
        settingsChanged()
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
        settingsChanged()
    }

    @objc private func modelChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let m = models.catalog.first(where: { $0.id == id }) else { return }
        switch models.states[m.id] ?? .notInstalled {
        case .installed:
            useModelFile(models.path(m))
        case .downloading:
            models.cancel(m)
        case .verifying:
            break
        case .notInstalled, .failed, .paused:
            download(m)
        }
    }

    @objc private func fileChosen(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { useModelFile(path) }
    }

    @objc private func deleteChosen(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { confirmDeleteModel(path) }
    }

    @objc private func showModelsFolder() {
        try? FileManager.default.createDirectory(at: ModelLocator.modelsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ModelLocator.modelsDir)
    }

    @objc private func openSetup() {
        showOnboarding()
    }

    @objc func openPreferences() {
        let w = preferences ?? PreferencesWindowController(host: self)
        preferences = w
        w.show()
    }

    var updates: UpdateController? { updater }

    @objc private func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// An update was found, skipped or installed, or Sparkle's window for it was looked at:
    /// the menu line, the icon's dot and the Settings line follow.
    private func updateAvailabilityChanged() {
        updateIcon()
        preferences?.refresh()
        writeUpdateReport()
    }

    /// FORETYPE_UPDATE_REPORT=<file> (scripts/sparkle-local-test.sh).
    private static let updateReport = ProcessInfo.processInfo.environment["FORETYPE_UPDATE_REPORT"]

    /// Testing: writes what the menu-bar menu, the icon, Settings ▸ General and the app's open
    /// windows show to FORETYPE_UPDATE_REPORT, and the General pane as a picture to <file>.png.
    /// At launch and after each change.
    private func writeUpdateReport() {
        guard let path = Self.updateReport else { return }
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        var lines = menu.items.map { "menu: " + ($0.isSeparatorItem ? "---" : $0.title) }
        lines.append("icon: " + (MenuBarIcon.image(MenuBarIcon.state, badge: MenuBarIcon.badge).accessibilityDescription ?? ""))
        let pane = GeneralPane(title: L("General"), host: self)
        let png = pane.png()
        lines.append("settings: " + pane.versionText)
        lines += NSApp.windows.filter(\.isVisible).map {
            "window: \($0.title) (\($0.windowController.map { String(describing: type(of: $0)) } ?? "-"))"
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try? png?.write(to: URL(fileURLWithPath: path + ".png"))
    }

    /// Bring-your-own server: llama-server (best: grammar-based token healing) or any
    /// OpenAI-compatible completions endpoint (Ollama, LM Studio, a cloud provider).
    @objc private func configureServer() {
        NSApp.activate(ignoringOtherApps: true)
        let kind = NSPopUpButton()
        kind.addItems(withTitles: Self.backendTitles)
        kind.selectItem(at: Self.backends.firstIndex(of: settings.backend) ?? 0)
        let url = NSTextField(string: settings.backendURL)
        url.placeholderString = "http://127.0.0.1:8080"
        let model = NSTextField(string: settings.backendModel)
        model.placeholderString = L("model name (OpenAI-compatible only)")
        let key = NSSecureTextField(string: "")
        key.placeholderString = settings.backendAPIKey.isEmpty ? L("API key (optional)") : L("API key saved; type to replace")
        let stack = NSStackView(views: [kind, url, model, key])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for f in [url, model, key] { f.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 118)
        let alert = NSAlert()
        alert.messageText = L("Where should suggestions come from?")
        alert.informativeText = L("A llama-server gives the same suggestions as the built-in engine. OpenAI-compatible servers work too, but complete words you have started less well (about half the typing saved). Apple's on-device model needs no download but takes about 0.7 s per suggestion. The API key is stored in your Keychain.")
        alert.accessoryView = stack
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyServer(backend: Self.backends[max(0, kind.indexOfSelectedItem)], url: url.stringValue,
                    model: model.stringValue, apiKey: key.stringValue)
    }

    /// Where suggestions can come from (the server dialog and the Settings window); Apple's
    /// on-device model only where Apple Intelligence is available.
    static var backends: [String] {
        ["local", "llama-server", "openai"] + (AppleModel.isAvailable ? ["apple"] : [])
    }
    static var backendTitles: [String] {
        [L("Built-in (on this Mac)"), "llama.cpp llama-server", L("OpenAI-compatible (Ollama, LM Studio, ...)")]
            + (AppleModel.isAvailable ? [L("Apple on-device model (no download; slower)")] : [])
    }

    @objc private func togglePersonalize() {
        setPersonalize(!settings.personalize)
    }

    @objc private func setStrength(_ sender: NSMenuItem) {
        settings.personalizeStrength = sender.tag
        settingsChanged()
    }

    @objc private func deleteHistory() {
        confirmDeleteHistory()
    }

    @objc private func openInstructionsMenu() {
        openInstructions()
    }

    @objc private func unsnooze(_ sender: NSMenuItem) {
        if let bundle = sender.representedObject as? String { controller?.unsnooze(bundle) }
    }

    @objc private func toggleScreenContext() {
        settings.useScreenContext.toggle()
        settingsChanged()
    }

    @objc private func openScreenRecording() {
        openScreenRecordingSettings()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - PreferencesHost (also the menu's code path)

    var engineStatus: String {
        if let paused = pauseDescription { return paused }
        let state = Self.stateName(engineState)
        return engineDetail.isEmpty ? state : "\(state) \u{2014} \(engineDetail)"
    }

    func settingsChanged() {
        controller?.applySettings()
        preferences?.refresh()
    }

    func setPersonalize(_ on: Bool) {
        if on, !settings.personalize {
            guard let key = HistoryStore.keyHex() else {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("Couldn't create the encryption key")
                alert.informativeText = L("Foretype needs a key in your Keychain to store your writing history encrypted.")
                alert.runModal()
                preferences?.refresh()
                return
            }
            controller?.engine.openHistory(path: HistoryStore.path, keyHex: key)
        }
        settings.personalize = on
        settingsChanged()
    }

    func historyStats() -> (records: Int, words: Int)? {
        controller?.engine.historyStats()
    }

    @objc private func importWritingMenu() { importWriting() }

    /// Text files (.txt, .md) the user picks, split into paragraphs, into the writing history
    /// (the vocabulary bias; no app, so they are never shown as same-app examples). Foretype
    /// can't import Cotypist's history: its database is encrypted with a key only Cotypist
    /// holds.
    func importWriting() {
        guard settings.personalize, let engine = controller?.engine else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = L("Choose text files or folders with your own writing")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK else { return }
        var files: [URL] = []
        for url in panel.urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
               let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                files += walk.compactMap { $0 as? URL }.filter { ["txt", "md"].contains($0.pathExtension.lowercased()) }
            } else {
                files.append(url)
            }
        }
        var items: [(app: String, text: String)] = []
        var bytes = 0
        for f in files.prefix(2000) {
            guard let text = try? String(contentsOf: f, encoding: .utf8), bytes < 20_000_000 else { continue }
            bytes += text.utf8.count
            for p in text.components(separatedBy: "\n\n") {
                let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 20 { items.append(("", String(t.prefix(4000)))) }
            }
        }
        let n = engine.importHistory(items)
        let alert = NSAlert()
        alert.messageText = n.map { LCount($0, "Imported %@ passages", one: "Imported %@ passage") } ?? L("Import failed")
        alert.informativeText = LCount(files.count, "From %@ files. Suggestions lean towards the words you use from the next one on.",
                                       one: "From %@ file. Suggestions lean towards the words you use from the next one on.")
        alert.runModal()
        preferences?.refresh()
    }

    func confirmDeleteHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Delete your writing history?")
        alert.informativeText = L("Foretype forgets everything it learned from your writing. This can't be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            if controller?.engine.clearHistory() != true {
                try? FileManager.default.removeItem(atPath: HistoryStore.path)
            }
        }
        preferences?.refresh()
    }

    /// Applies at once; the encrypted file is written half a second after the last change.
    func setAboutYou(_ details: AboutYou) {
        guard details != aboutYou else { return }
        aboutYou = details
        controller?.detailsJSON = details.coreJSON()
        aboutYouSave?.cancel()
        if aboutYouFromEnvironment { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.aboutYouSave = nil
            if !AboutYouStore.save(self.aboutYou) {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("Couldn't save your details")
                alert.informativeText = L("Foretype needs a key in your Keychain to store your details encrypted. They are used until you quit.")
                alert.runModal()
            }
        }
        aboutYouSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func confirmClearAboutYou() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Delete your details?")
        alert.informativeText = L("Foretype forgets the details you entered in About You. This can't be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            aboutYouSave?.cancel()
            aboutYouSave = nil
            aboutYou = AboutYou()
            if !aboutYouFromEnvironment { AboutYouStore.delete() }
            controller?.detailsJSON = aboutYou.coreJSON()
        }
        preferences?.refresh()
    }

    func openInstructions() {
        let bundle = lastFrontApp?.bundleIdentifier
        let w = InstructionsWindowController(global: settings.instructions, appName: lastFrontApp?.localizedName,
                                             appBundle: bundle, appText: bundle.flatMap { settings.appInstructions[$0] } ?? "")
        w.onSave = { [weak self] global, appText, bundle in
            guard let self else { return }
            self.settings.instructions = global
            if let bundle { self.settings.setAppInstructions(appText, for: bundle) }
            self.settingsChanged()
        }
        instructionsWindow = w
        w.show()
    }

    func openScreenRecordingSettings() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// The file the engine loaded, or the one it would load next (`ModelLocator`), while
    /// the built-in engine is selected.
    func isModelInUse(_ path: String) -> Bool {
        guard settings.backend == "local" else { return false }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let candidates = [loadedModelPath, ModelLocator.find(settings: settings, recommendedFile: models.recommended?.file)]
        return candidates.contains { $0.map { URL(fileURLWithPath: $0).standardizedFileURL.path == p } ?? false }
    }

    func useModelFile(_ path: String) {
        settings.modelPath = path
        settings.backend = "local"
        startEngine()
        preferences?.refresh()
    }

    /// Downloads (or resumes) a catalog model and switches to it once it verifies.
    func download(_ m: ModelInfo) {
        models.download(m) { [weak self] result in
            guard let self, case .success = result else { return }
            self.useModelFile(self.models.path(m))
        }
    }

    func confirmDeleteModel(_ path: String) {
        NSApp.activate(ignoringOtherApps: true)
        let file = models.localFiles().first { $0.path == path }
        let name = file?.name ?? URL(fileURLWithPath: path).lastPathComponent
        let alert = NSAlert()
        if isModelInUse(path) {
            alert.messageText = L("%@ is in use", name)
            alert.informativeText = L("Foretype is using this model. Choose another model or a server first, then delete it.")
            alert.runModal()
            return
        }
        let size = Self.bytes(file?.bytes ?? ModelManager.sizeOnDisk(path))
        alert.messageText = L("Delete %@?", name)
        if file?.incomplete == true {
            alert.informativeText = L("This incomplete download (%@) is removed from the Models folder.", size)
        } else if file?.model != nil {
            alert.informativeText = L("The model file (%@) is removed from this Mac. You can download it again from the Model menu.", size)
        } else {
            alert.informativeText = L("The file (%@) is removed from this Mac. It isn't in Foretype's catalog, so it can't be downloaded again from here.", size)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try models.delete(path: path)
            if settings.modelPath == path { settings.modelPath = nil }
        } catch {
            let failed = NSAlert()
            failed.messageText = L("Couldn't delete %@", name)
            failed.informativeText = error.localizedDescription
            failed.runModal()
        }
        preferences?.modelsChanged()
    }

    func applyServer(backend: String, url: String, model: String, apiKey: String?) {
        settings.backend = backend
        settings.backendURL = url.trimmingCharacters(in: .whitespaces)
        settings.backendModel = model.trimmingCharacters(in: .whitespaces)
        if let apiKey, !apiKey.isEmpty { settings.backendAPIKey = apiKey }
        startEngine()
        preferences?.refresh()
    }
}
