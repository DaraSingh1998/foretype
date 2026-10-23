import AppKit

/// `Foretype --settings-selftest [DIR]`: builds the Settings window around a stand-in host
/// (the real settings are read, never written) and checks it on made-up screens, never
/// showing it: every pane fits a 13-inch MacBook Air without scrolling (Apps and Model grow
/// with their rows and may scroll), a pane taller than the screen scrolls inside a window
/// that stays clear of the menu bar and the Dock, on a display above the main one too, and
/// the toolbar shows every tab. With DIR, writes each pane as DIR/<n>-<pane>-light.png and
/// -dark.png. Run the bundled binary with `-AppleLanguages '(hi)'` to check Hindi.
enum PreferencesSelfTest {
    /// Visible frames (below the menu bar, above a 48 pt Dock) in Cocoa coordinates.
    static let air13 = NSRect(x: 0, y: 72, width: 1470, height: 956 - 37 - 72)
    static let pro14 = NSRect(x: 0, y: 72, width: 1512, height: 982 - 38 - 72)
    /// A 1080p display above the 14-inch one: its own menu bar, no Dock.
    static let above = NSRect(x: -204, y: 982, width: 1920, height: 1080 - 25)
    static let tiny = NSRect(x: 0, y: 0, width: 1024, height: 420)

    static func run(dir: String?) -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("FAIL: \(what)") }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        GeneralPane.showsUpdatesForTesting = true
        let host = StandInHost()
        let prefs = PreferencesWindowController(host: host)
        guard let window = prefs.window, let content = window.contentView else { return false }
        let tabs = prefs.tabs
        var screen = air13
        tabs.visibleFrame = { _ in screen }
        let chrome = window.frame.height - content.frame.height
        func inside(_ v: NSRect) -> Bool { v.insetBy(dx: -0.5, dy: -0.5).contains(window.frame) }

        // Each pane on a 13-inch MacBook Air.
        for (i, pane) in prefs.panes.enumerated() {
            tabs.selectedTabViewItemIndex = i
            tabs.fit(animated: false)
            let name = pane.title ?? "?"
            let grows = pane is AppsPane || pane is ModelPane
            print(String(format: "%@: %.0f pt of %.0f%@", name, pane.contentHeight, screen.height - chrome,
                         pane.scrolls ? " (scrolls)" : ""))
            check(inside(screen), "\(name): window \(window.frame) outside the Air's screen \(screen)")
            check(grows || !pane.scrolls, "\(name): scrolls on a 13-inch MacBook Air")
            check(abs(content.frame.height - min(pane.contentHeight, floor(screen.height - chrome))) < 1,
                  "\(name): content \(content.frame.height) high for rows of \(pane.contentHeight)")
        }

        // A short screen: tall panes scroll inside a window as tall as the screen.
        screen = tiny
        for (i, pane) in prefs.panes.enumerated() {
            tabs.selectedTabViewItemIndex = i
            tabs.fit(animated: false)
            let name = pane.title ?? "?"
            let tall = pane.contentHeight > screen.height - chrome
            check(inside(screen), "\(name): window \(window.frame) outside the short screen \(screen)")
            check(pane.scrolls == tall, "\(name): scrolls \(pane.scrolls), rows \(pane.contentHeight)")
            if tall {
                check(abs(window.frame.height - screen.height) < 1, "\(name): window \(window.frame.height) high on a \(screen.height) screen")
                let doc = pane.view as? NSScrollView
                check((doc?.documentView?.frame.height ?? 0) > (doc?.contentView.bounds.height ?? .infinity),
                      "\(name): the rows don't extend below the window")
            }
        }

        // Switching panes keeps the window's top edge where the screen has room.
        screen = pro14
        tabs.selectedTabViewItemIndex = 6
        tabs.fit(animated: false)
        window.setFrameTopLeftPoint(NSPoint(x: 300, y: screen.maxY - 40))
        let top = window.frame.maxY
        tabs.selectedTabViewItemIndex = 7
        check(abs(window.frame.maxY - top) < 1 && inside(screen), "switching tabs moved the top edge: \(window.frame)")

        // Hanging off the bottom of a display above the main one: moved back up onto it.
        screen = above
        window.setFrameOrigin(NSPoint(x: 400, y: above.minY - 200))
        tabs.selectedTabViewItemIndex = 0
        tabs.fit(animated: false)
        check(inside(above), "window \(window.frame) not moved onto the display above \(above)")
        window.setFrameOrigin(NSPoint(x: above.maxX - 100, y: above.maxY - 50))
        tabs.fit(animated: false)
        check(inside(above), "window \(window.frame) not moved back from the display's top right corner")

        // An app list is as tall as its rows, between its bounds.
        let list = AppList(minHeight: 44, maxHeight: 280)
        func listHeight(_ n: Int) -> CGFloat {
            list.setRows((0..<n).map { _ in AppList.row(bundle: "com.apple.TextEdit", state: "Off", removeTip: "%@") {} })
            return list.constraints.first { $0.firstAttribute == .height }?.constant ?? 0
        }
        let (one, three, many) = (listHeight(1), listHeight(3), listHeight(30))
        check(one >= 44 && one < three && three < 280 && many == 280, "app list heights \(one), \(three), \(many)")

        // The frame math alone: growing down past the Dock moves the window up, not the top edge off screen.
        let f = PreferencesTabController.frame(content: NSSize(width: 580, height: 500), chrome: NSSize(width: 0, height: 80),
                                               current: NSRect(x: 100, y: 100, width: 580, height: 300), visible: air13)
        check(f == NSRect(x: 100, y: air13.minY, width: 580, height: 580), "frame(): \(f)")

        // Every tab in the toolbar, none in its overflow menu: a window that is never seen.
        screen = air13
        tabs.selectedTabViewItemIndex = 0
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.toolbar?.validateVisibleItems()
        content.layoutSubtreeIfNeeded()
        let shown = window.toolbar?.visibleItems?.count ?? 0
        let all = window.toolbar?.items.count ?? 0
        window.orderOut(nil)
        print("toolbar: \(shown) of \(all) tabs shown in a \(Int(window.frame.width)) pt window")
        check(all == prefs.panes.count && shown == all, "toolbar shows \(shown) of \(all) tabs")

        if let dir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (i, pane) in prefs.panes.enumerated() {
                let name = (pane.title ?? "pane").replacingOccurrences(of: " ", with: "-")
                for dark in [false, true] {
                    let path = "\(dir)/\(i + 1)-\(name)-\(dark ? "dark" : "light").png"
                    check((try? pane.png(dark: dark)?.write(to: URL(fileURLWithPath: path))) != nil, "writing \(path)")
                }
            }
            print("panes written to \(dir)")
        }

        // A locked writing history and locked details: their notes and Try Again still fit.
        host.settings.historyLocked = true
        host.aboutYouLocked = true
        for (i, pane) in prefs.panes.enumerated() where pane is PersonalizationPane || pane is AboutYouPane {
            pane.refresh()
            tabs.selectedTabViewItemIndex = i
            tabs.fit(animated: false)
            let name = pane.title ?? "?"
            print(String(format: "%@ (locked): %.0f pt", name, pane.contentHeight))
            check(inside(screen) && !pane.scrolls, "\(name) (locked): scrolls on a 13-inch MacBook Air")
            if let dir {
                let path = "\(dir)/\(i + 1)-\(name.replacingOccurrences(of: " ", with: "-"))-locked.png"
                check((try? pane.png(dark: false)?.write(to: URL(fileURLWithPath: path))) != nil, "writing \(path)")
            }
        }
        host.settings.historyLocked = false
        host.aboutYouLocked = false
        print(failures == 0 ? "settings self-test passed" : "settings self-test: \(failures) failed")
        return failures == 0
    }
}

/// The Settings window's host for the self-test: the real settings and models folder, read
/// only; in-memory statistics and pause; does nothing when a control asks.
private final class StandInHost: PreferencesHost {
    let settings = AppSettings()
    let models = ModelManager()
    let stats = UsageStats(storage: .init(load: { nil }, save: { _ in }))
    let pause: PauseState
    private let suite = "dev.foretype.settings-selftest.\(ProcessInfo.processInfo.processIdentifier)"

    init() {
        pause = PauseState(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

    var engineStatus: String { "ready \u{2014} Qwen3-1.7B-Base.Q4_K_M.gguf" }
    var aboutYou: AboutYou { AboutYou() }
    var aboutYouLocked = false
    var updates: UpdateController? { nil }
    var pauseDescription: String? { nil }
    var powerState: PowerState {
        var p = PowerState()
        p.hasBattery = true
        return p
    }

    func settingsChanged() {}
    func setPersonalize(_ on: Bool) {}
    func retryHistory() {}
    func historyStats() -> (records: Int, words: Int)? { nil }
    func confirmDeleteHistory() {}
    func openInstructions() {}
    func openScreenRecordingSettings() {}
    func isModelInUse(_ path: String) -> Bool { false }
    func useModelFile(_ path: String) {}
    func download(_ m: ModelInfo) {}
    func confirmDeleteModel(_ path: String) {}
    func applyServer(backend: String, url: String, model: String, apiKey: String?) {}
    func importWriting() {}
    func addAppException() {}
    func setAboutYou(_ details: AboutYou) {}
    func confirmClearAboutYou() {}
    func retryAboutYou() {}
    func pauseSuggestions(until: Date?) {}
    func resumeSuggestions() {}
    func powerSettingsChanged() {}
}
