import AppKit

/// What an app is built on, read from its bundle, for apps the compatibility database doesn't
/// list: an Electron app ships `Electron Framework.framework` (or a renamed copy, with its
/// code in `Resources/app.asar`) and needs the same accessibility priming as the listed ones
/// (`AXManualAccessibility`). An app on OpenAI's "owl" runtime (`owl-electron-app.json`, the
/// ChatGPT/Codex app) looks like Electron but only answers Chrome's `AXEnhancedUserInterface`.
/// Cached per bundle ID; any thread.
enum AppKind {
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    /// "electron" for an Electron app, else nil.
    static func detected(_ bundleId: String) -> String? {
        lock.lock()
        if let known = cache[bundleId] { lock.unlock(); return known }
        lock.unlock()
        let kind = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).flatMap(kind(of:))
        lock.lock()
        cache[bundleId] = kind
        lock.unlock()
        return kind
    }

    /// "electron" when the app bundle at `url` holds the Electron framework, or an app archive
    /// beside a renamed one; "chromium" for an owl app.
    static func kind(of url: URL) -> String? {
        let fm = FileManager.default
        let resources = url.appendingPathComponent("Contents/Resources")
        if fm.fileExists(atPath: resources.appendingPathComponent("owl-electron-app.json").path) { return "chromium" }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let archive = resources.appendingPathComponent("app.asar")
        return fm.fileExists(atPath: framework.path) || fm.fileExists(atPath: archive.path) ? "electron" : nil
    }

    /// `--electron-selftest`: made-up bundles in a temporary folder.
    static func selfTest() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foretype-appkind-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let electron = dir.appendingPathComponent("Chat.app")
        let renamed = dir.appendingPathComponent("Agent.app")
        let owl = dir.appendingPathComponent("Owl.app")
        let native = dir.appendingPathComponent("Notes.app")
        do {
            try FileManager.default.createDirectory(at: owl.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data().write(to: owl.appendingPathComponent("Contents/Resources/app.asar"))
            try Data("{}".utf8).write(to: owl.appendingPathComponent("Contents/Resources/owl-electron-app.json"))
            try FileManager.default.createDirectory(at: electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: renamed.appendingPathComponent("Contents/Frameworks/Agent Framework.framework"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: renamed.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data().write(to: renamed.appendingPathComponent("Contents/Resources/app.asar"))
            try FileManager.default.createDirectory(at: native.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        } catch {
            print("electron self-test: \(error)")
            return false
        }
        let ok = kind(of: electron) == "electron" && kind(of: renamed) == "electron" && kind(of: owl) == "chromium" && kind(of: native) == nil
            && detected("invalid.foretype.nothing") == nil
        print(ok ? "electron self-test passed" : "electron self-test FAILED")
        return ok
    }
}
