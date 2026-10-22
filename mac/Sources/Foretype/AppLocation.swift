import AppKit
import ServiceManagement

/// Where the app runs from, and the things that depend on it: moving it to Applications,
/// relaunching it, and opening it at login. All of these apply to the bundled app only; a bare
/// development binary started from a terminal is left alone.
enum AppLocation {
    static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Running from the disk image, from Downloads, or from a translocated copy (macOS runs a
    /// downloaded app opened in place from a random read-only folder). Sparkle can't update
    /// such a copy, and its permission entries point at a path that goes away.
    static var isOutsideApplications: Bool {
        guard isBundledApp else { return false }
        let path = Bundle.main.bundlePath
        let home = NSHomeDirectory()
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return false }
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") || path.hasPrefix(home + "/Downloads/")
    }

    /// Asks once to move the app to Applications; true when it is moving (the app then quits
    /// and the copy in Applications opens).
    static func offerMove(settings: AppSettings) -> Bool {
        guard isOutsideApplications, !settings.declinedMoveToApplications else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Move Foretype to your Applications folder?")
        alert.informativeText = L("In Applications, Foretype can update itself and keeps the permissions you give it.")
        alert.addButton(withTitle: L("Move to Applications"))
        alert.addButton(withTitle: L("Not Now"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            settings.declinedMoveToApplications = true
            return false
        }
        do {
            try moveToApplications()
            return true
        } catch {
            let failed = NSAlert()
            failed.messageText = L("Foretype couldn\u{2019}t be moved")
            failed.informativeText = error.localizedDescription
            failed.runModal()
            return false
        }
    }

    private static func moveToApplications() throws {
        let fm = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder = fm.isWritableFile(atPath: system.path) ? system
            : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("Foretype.app")
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where app.bundleURL?.standardizedFileURL == dest.standardizedFileURL {
            app.terminate()
        }
        if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
        // The copy keeps the download's quarantine mark; the user already allowed this app.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? xattr.run()
        xattr.waitUntilExit()
        // A copy left in Downloads goes to the Trash once this one has quit.
        let source = Bundle.main.bundlePath
        let trashSource = source.hasPrefix(NSHomeDirectory() + "/Downloads/") ? source : nil
        relaunch(at: dest.path, trashing: trashSource)
    }

    /// Quits and opens the app again (or the copy at `path`), e.g. so a Screen Recording grant
    /// applies: macOS checks it only when the app starts.
    static func relaunch(at path: String = Bundle.main.bundlePath, trashing old: String? = nil) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if [ -n "$3" ]; then mv "$3" "$HOME/.Trash/Foretype $(date +%s).app" 2>/dev/null; fi
        open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(pid), path, old ?? ""]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Open at login

    static var opensAtLogin: Bool {
        isBundledApp && SMAppService.mainApp.status == .enabled
    }

    /// Registers or removes the login item. When macOS wants the user to approve it, opens
    /// System Settings ▸ General ▸ Login Items.
    static func setOpensAtLogin(_ on: Bool) {
        guard isBundledApp else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.debug("login item: \(error)")
        }
        if on, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
