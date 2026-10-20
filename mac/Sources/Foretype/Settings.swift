import Foundation
import Security

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

    /// End a suggestion at the end of a sentence instead of running on into the next one.
    var stopAtSentenceEnd: Bool {
        get { d.object(forKey: "stopAtSentenceEnd") as? Bool ?? true }
        set { d.set(newValue, forKey: "stopAtSentenceEnd") }
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

    /// Learn from the user's writing (opt-in, off by default).
    var personalize: Bool {
        get { d.bool(forKey: "personalize") }
        set { d.set(newValue, forKey: "personalize") }
    }

    /// 0 gentle, 1 balanced, 2 strong.
    var personalizeStrength: Int {
        get { d.object(forKey: "personalizeStrength") as? Int ?? 1 }
        set { d.set(newValue, forKey: "personalizeStrength") }
    }

    /// "local" (built-in llama.cpp), "llama-server" or "openai".
    var backend: String {
        get { d.string(forKey: "backend") ?? "local" }
        set { d.set(newValue, forKey: "backend") }
    }

    var backendURL: String {
        get { d.string(forKey: "backendURL") ?? "http://127.0.0.1:8080" }
        set { d.set(newValue, forKey: "backendURL") }
    }

    var backendModel: String {
        get { d.string(forKey: "backendModel") ?? "" }
        set { d.set(newValue, forKey: "backendModel") }
    }

    /// API key for a server backend, kept in the Keychain (only read when a server is used).
    var backendAPIKey: String {
        get { Keychain.get("backend-api-key").flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set { Keychain.set("backend-api-key", newValue.data(using: .utf8), label: "Foretype server API key") }
    }

    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    /// Extra instructions per bundle ID.
    var appInstructions: [String: String] {
        get { d.dictionary(forKey: "appInstructions") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "appInstructions") }
    }

    var modelPath: String? {
        get { d.string(forKey: "modelPath") }
        set { d.set(newValue, forKey: "modelPath") }
    }

    /// FORETYPE_ONLY_APPS=bundle.id,other.id restricts suggestions to those apps
    /// (a safety net for development and automated tests). An entry can also be a pid, to
    /// allow one process of an app that runs several (a test Chrome next to the user's own).
    var onlyApps: [String] {
        (ProcessInfo.processInfo.environment["FORETYPE_ONLY_APPS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether FORETYPE_ONLY_APPS lets Foretype read or prime this app.
    func onlyAppsAllow(pid: pid_t, bundleId: String) -> Bool {
        let only = onlyApps
        return only.isEmpty || only.contains(bundleId) || only.contains(String(pid))
    }

    var coreDict: [String: Any] {
        ["enabled": enabled, "length_words": lengthWords, "stop_at_sentence_end": stopAtSentenceEnd,
         "instructions": instructions,
         "app_instructions": appInstructions, "disabled_apps": disabledApps, "enabled_apps": enabledApps,
         // The core filters by bundle ID and can't express a pid entry; then the tracker, which
         // never reads an app this list rejects, is the only filter.
         "only_apps": onlyApps.contains { pid_t($0) != nil } ? [] : onlyApps,
         "personalize": personalize, "personalize_strength": personalizeStrength]
    }

    func coreJSON() -> String {
        String(data: try! JSONSerialization.data(withJSONObject: coreDict), encoding: .utf8)!
    }
}

/// Generic-password items for this app in the login Keychain.
enum Keychain {
    private static let service = "dev.foretype.Foretype"

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    @discardableResult
    static func set(_ account: String, _ data: Data?, label: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let data, !data.isEmpty else { return true }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// The personalization history's location and its encryption key, kept in the Keychain.
/// The key is only created or read when personalization is on.
enum HistoryStore {
    static var path: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foretype/history.bin").path
    }

    /// The 256-bit key as hex, created on first use.
    static func keyHex() -> String? {
        if let data = Keychain.get("history-key"), data.count == 32 {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        var key = Data(count: 32)
        let ok = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) } == errSecSuccess
        guard ok, Keychain.set("history-key", key, label: "Foretype writing history key") else { return nil }
        return key.map { String(format: "%02x", $0) }.joined()
    }
}

/// Finds a GGUF model: $FORETYPE_MODEL, the saved path, then
/// ~/Library/Application Support/Foretype/Models (preferring the 1.7B default tier).
enum ModelLocator {
    /// FORETYPE_MODELS_DIR overrides the location (tests).
    static var modelsDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FORETYPE_MODELS_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foretype/Models")
    }

    static func find(settings: AppSettings, recommendedFile: String? = nil) -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FORETYPE_MODEL"], fm.fileExists(atPath: env) { return env }
        if let saved = settings.modelPath, fm.fileExists(atPath: saved) { return saved }
        let files = ((try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? []).filter { $0.hasSuffix(".gguf") }.sorted()
        let pick = files.first { $0 == recommendedFile } ?? files.first
        return pick.map { modelsDir.appendingPathComponent($0).path }
    }
}
