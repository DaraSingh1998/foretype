import Foundation

/// User settings persisted in UserDefaults and mirrored into the core as JSON.
final class AppSettings {
    private let d = UserDefaults.standard

    static var lengthPresets: [(name: String, words: Int)] {
        [(L("Short (2 words)"), 2), (L("Medium (4 words)"), 4), (L("Long (7 words)"), 7), (L("Very long (10 words)"), 10)]
    }

    /// `personalizeStrength` 0, 1 and 2, as the menu and the Settings window name them.
    static var strengthNames: [String] { [L("Gentle"), L("Balanced"), L("Strong")] }

    /// On battery: full speed, save energy (the default) or pause.
    var batteryMode: PowerPolicy.BatteryMode {
        get { d.string(forKey: "batteryMode").flatMap(PowerPolicy.BatteryMode.init(rawValue:)) ?? .save }
        set { d.set(newValue.rawValue, forKey: "batteryMode") }
    }

    /// In Low Power Mode: save energy or pause (the default).
    var lowPowerMode: PowerPolicy.LowPowerMode {
        get { d.string(forKey: "lowPowerMode").flatMap(PowerPolicy.LowPowerMode.init(rawValue:)) ?? .pause }
        set { d.set(newValue.rawValue, forKey: "lowPowerMode") }
    }

    /// Pause on battery below this charge, in percent; 0 (the default) never.
    var pauseBelowBattery: Int {
        get { d.integer(forKey: "pauseBelowBattery") }
        set { d.set(newValue, forKey: "pauseBelowBattery") }
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

    /// Offer the emoji for a typed `:name`.
    var emoji: Bool {
        get { d.object(forKey: "emoji") as? Bool ?? true }
        set { d.set(newValue, forKey: "emoji") }
    }

    /// Offer the spell checker's correction for a misspelled word just finished.
    var autocorrect: Bool {
        get { d.object(forKey: "autocorrect") as? Bool ?? true }
        set { d.set(newValue, forKey: "autocorrect") }
    }

    /// No suggestion while the word being typed can't become a real word.
    var typoGate: Bool {
        get { d.object(forKey: "typoGate") as? Bool ?? true }
        set { d.set(newValue, forKey: "typoGate") }
    }

    /// Suggest in the middle of a line too (shown as a card under the caret).
    var midLine: Bool {
        get { d.bool(forKey: "midLine") }
        set { d.set(newValue, forKey: "midLine") }
    }

    /// The note for every app: the default one until the user saves their own (an empty one
    /// too). Saving the default text again goes back to following the defaults, which may
    /// change in later versions.
    var instructions: String {
        get { d.string(forKey: "instructions") ?? DefaultInstructions.shared.global }
        set {
            if newValue == DefaultInstructions.shared.global {
                d.removeObject(forKey: "instructions")
            } else {
                d.set(newValue, forKey: "instructions")
            }
        }
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

    /// "Not Now" to moving the app into Applications (asked once).
    var declinedMoveToApplications: Bool {
        get { d.bool(forKey: "declinedMoveToApplications") }
        set { d.set(newValue, forKey: "declinedMoveToApplications") }
    }

    /// Learn from the user's writing (opt-in, off by default).
    var personalize: Bool {
        get { d.bool(forKey: "personalize") }
        set { d.set(newValue, forKey: "personalize") }
    }

    /// For this run only, never saved: personalization is on but the history's key couldn't
    /// be read from the Keychain (`HistoryStore.Key.locked`), so nothing is learned or opened
    /// until the user tries again.
    var historyLocked = false

    /// Personalization as the core sees it: on, and its history open.
    var learning: Bool { personalize && !historyLocked }

    /// 0 gentle, 1 balanced, 2 strong.
    var personalizeStrength: Int {
        get { d.object(forKey: "personalizeStrength") as? Int ?? 1 }
        set { d.set(newValue, forKey: "personalizeStrength") }
    }

    /// "local" (built-in llama.cpp), "llama-server", "openai" or "apple" (Foundation Models).
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
        get { Keychain.login.get("backend-api-key").data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set { Keychain.login.set("backend-api-key", newValue.data(using: .utf8), label: "Foretype server API key") }
    }

    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    /// Extra instructions per bundle ID: the defaults, overridden by the user's own (an empty
    /// one switches an app's default off).
    var appInstructions: [String: String] {
        DefaultInstructions.shared.apps.merging(ownAppInstructions) { _, own in own }
    }

    private var ownAppInstructions: [String: String] {
        d.dictionary(forKey: "appInstructions") as? [String: String] ?? [:]
    }

    /// Saves an app's note; the app's default text (or nothing, when it has none) is stored as
    /// "follow the defaults".
    func setAppInstructions(_ text: String, for bundle: String) {
        var own = ownAppInstructions
        own[bundle] = text == (DefaultInstructions.shared.apps[bundle] ?? "") ? nil : text
        d.set(own, forKey: "appInstructions")
    }

    var instructionsAreDefault: Bool {
        d.object(forKey: "instructions") == nil && ownAppInstructions.isEmpty
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
        ["length_words": lengthWords, "stop_at_sentence_end": stopAtSentenceEnd,
         "instructions": instructions,
         "app_instructions": appInstructions, "disabled_apps": disabledApps, "enabled_apps": enabledApps,
         // The core filters by bundle ID and can't express a pid entry; then the tracker, which
         // never reads an app this list rejects, is the only filter.
         "only_apps": onlyApps.contains { pid_t($0) != nil } ? [] : onlyApps,
         "personalize": learning, "personalize_strength": personalizeStrength,
         "emoji": emoji, "autocorrect": autocorrect, "typo_gate": typoGate, "mid_line": midLine]
    }

    func coreJSON() -> String {
        String(data: try! JSONSerialization.data(withJSONObject: coreDict), encoding: .utf8)!
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
