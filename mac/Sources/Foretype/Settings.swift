import Foundation

/// User settings persisted in UserDefaults and mirrored into the core as JSON.
final class AppSettings {
    private let d = UserDefaults.standard

    static let lengthPresets: [(name: String, words: Int)] = [
        ("Short (2 words)", 2), ("Medium (4 words)", 4), ("Long (7 words)", 7), ("Very long (10 words)", 10),
    ]

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    var lengthWords: Int {
        get { d.object(forKey: "lengthWords") as? Int ?? 4 }
        set { d.set(newValue, forKey: "lengthWords") }
    }

    var instructions: String {
        get { d.string(forKey: "instructions") ?? "" }
        set { d.set(newValue, forKey: "instructions") }
    }

    /// Apps the user switched off.
    var disabledApps: [String] {
        get { d.stringArray(forKey: "disabledApps") ?? [] }
        set { d.set(newValue, forKey: "disabledApps") }
    }

    /// Apps that are off by default (terminals, editors) but the user switched on.
    var enabledApps: [String] {
        get { d.stringArray(forKey: "enabledApps") ?? [] }
        set { d.set(newValue, forKey: "enabledApps") }
    }

    /// Read on-screen text near the field (needs Screen Recording). On by default, as in
    /// Cotypist; nothing is captured until macOS grants the permission.
    var useScreenContext: Bool {
        get { d.object(forKey: "useScreenContext") as? Bool ?? true }
        set { d.set(newValue, forKey: "useScreenContext") }
    }

    var askedForScreenRecording: Bool {
        get { d.bool(forKey: "askedForScreenRecording") }
        set { d.set(newValue, forKey: "askedForScreenRecording") }
    }

    var modelPath: String? {
        get { d.string(forKey: "modelPath") }
        set { d.set(newValue, forKey: "modelPath") }
    }

    /// FORETYPE_ONLY_APPS=bundle.id,other.id restricts suggestions to those apps
    /// (a safety net for development and automated tests).
    var onlyApps: [String] {
        (ProcessInfo.processInfo.environment["FORETYPE_ONLY_APPS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var coreDict: [String: Any] {
        ["enabled": enabled, "length_words": lengthWords, "instructions": instructions,
         "disabled_apps": disabledApps, "enabled_apps": enabledApps, "only_apps": onlyApps]
    }

    func coreJSON() -> String {
        String(data: try! JSONSerialization.data(withJSONObject: coreDict), encoding: .utf8)!
    }
}

/// Finds a GGUF model: $FORETYPE_MODEL, the saved path, then
/// ~/Library/Application Support/Foretype/Models (preferring the 1.7B default tier).
enum ModelLocator {
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foretype/Models")
    }

    static func find(settings: AppSettings) -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FORETYPE_MODEL"], fm.fileExists(atPath: env) { return env }
        if let saved = settings.modelPath, fm.fileExists(atPath: saved) { return saved }
        let files = ((try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? []).filter { $0.hasSuffix(".gguf") }.sorted()
        let pick = files.first { $0.contains("1.7B") } ?? files.first
        return pick.map { modelsDir.appendingPathComponent($0).path }
    }
}
