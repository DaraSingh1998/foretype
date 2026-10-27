import AppKit

/// What an app is built on, read from its bundle, for apps the compatibility database doesn't
/// list: an Electron app ships `Electron Framework.framework` and needs the same
/// accessibility priming as the listed ones (`AXManualAccessibility`). Cached per bundle ID;
/// any thread.
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

    /// "electron" when the app bundle at `url` holds the Electron framework.
    static func kind(of url: URL) -> String? {
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path) ? "electron" : nil
    }

    /// `--electron-selftest`: made-up bundles in a temporary folder.
    static func selfTest() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foretype-appkind-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let electron = dir.appendingPathComponent("Chat.app")
        let native = dir.appendingPathComponent("Notes.app")
        do {
            try FileManager.default.createDirectory(at: electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: native.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        } catch {
            print("electron self-test: \(error)")
            return false
        }
        let ok = kind(of: electron) == "electron" && kind(of: native) == nil && detected("invalid.foretype.nothing") == nil
        print(ok ? "electron self-test passed" : "electron self-test FAILED")
        return ok
    }
}
