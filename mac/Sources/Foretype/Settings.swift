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

    /// Use text from other apps' windows (D42): off by default, separate from screen
    /// context. FORETYPE_OTHER_APPS=1 or 0 overrides it for testing (the stored value is left
    /// alone; the dev build shares its defaults with the installed app).
    var useOtherApps: Bool {
        get {
            if let env = ProcessInfo.processInfo.environment["FORETYPE_OTHER_APPS"] { return env == "1" }
            return d.bool(forKey: "useOtherApps")
        }
        set { d.set(newValue, forKey: "useOtherApps") }
    }

    /// Apps whose windows are never read as context: password managers until the user
    /// changes the list.
    var neverReadApps: [String] {
        get { d.stringArray(forKey: "neverReadApps") ?? ContextPool.passwordManagers }
        set {
            if newValue == ContextPool.passwordManagers { d.removeObject(forKey: "neverReadApps") } else { d.set(newValue, forKey: "neverReadApps") }
        }
    }

    var neverReadIsDefault: Bool { d.object(forKey: "neverReadApps") == nil }

    /// This Mac's memory in GB.
    static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

    /// The other-apps section's budget in tokens (D42): 512 under 16 GB, 2,048 (provisional)
    /// from 16 GB.
    static var otherAppsTokens: Int { memoryGB >= 16 ? 2048 : 512 }

    /// The built-in engine's longest prompt (D42, D47): 4,096 tokens from 16 GB while other
    /// apps' text is on, so its 2,048-token section fits, else 2,048; under 16 GB always 4,096,
    /// which the q8_0 KV cache holds in the memory 2,048 f16 tokens took (`engineCache`).
    var contextSize: Int { AppSettings.memoryGB < 16 || useOtherApps ? 4096 : 2048 }

    /// The built-in engine's KV cache (D47): q8_0 (half of f16's memory), two prompts held at
    /// once so a new header prefills in the background while the old one serves, and a few
    /// prompts saved in memory for fields the user comes back to. From 16 GB each prompt gets
    /// its whole context; under 16 GB the two share 4,096 cells (today's KV memory) and no
    /// prompt is saved under 12 GB.
    var engineCache: [String: Any] {
        let gb = AppSettings.memoryGB
        return ["kv_type": "q8_0", "slots": 2,
                "kv_cells": gb >= 16 ? 2 * contextSize : 4096,
                "saved_mb": gb >= 16 ? 384 : gb >= 12 ? 128 : 0]
    }

    /// Other apps' text only ever goes to a model on this Mac: never to a server (D42).
    var backendIsOnDevice: Bool { backend == "local" || backend == "apple" }

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
    /// be read from the Keychain (`HistoryStore.Key.locked`), or `historyKeyMismatch`, so
    /// nothing is learned or opened until the user tries again.
    var historyLocked = false

    /// For this run only: the key was read but opens none of the history file, which the core
    /// then keeps as it is (D46). Comes with `historyLocked`; deleting the history ends it.
    var historyKeyMismatch = false

    /// Why the history is locked, for the alert and the Personalization pane.
    var historyLockedNote: String {
        historyKeyMismatch
            ? L("The key in your Keychain doesn't open your writing history. Nothing is learned, and the history is kept as it is in case its key comes back. Delete it to start a new one.")
            : L("Foretype couldn't read its key from the Keychain. Nothing is learned until it can, and your history is kept as it is. Try again later, or delete the history to start a new one.")
    }

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

    /// Where the server API key is kept: the login Keychain, or an in-memory one in the
    /// self-tests.
    var keychain = Keychain.login

    /// What the server fields say about the saved API key, from the last read this run (nil:
    /// not read yet). Refreshing the Settings window uses it instead of asking the Keychain
    /// again, so a denied or cancelled prompt doesn't come back on every refresh.
    private var serverKeyRead: ServerKey.State?

    /// The server API key for the engine: one Keychain read, "" when there is none or it
    /// can't be read (that run goes without; the saved key is left alone).
    func readServerKey() -> String {
        let (key, state) = ServerKey.read(keychain)
        serverKeyRead = state
        if state == .unreadable { Log.debug("server API key: Keychain read failed, none sent this run") }
        return key
    }

    /// What the server fields say about the saved key: as last read, or read now.
    var serverKeyState: ServerKey.State {
        if let s = serverKeyRead { return s }
        _ = readServerKey()
        return serverKeyRead ?? .unreadable
    }

    /// Saves the key typed in a server form (`ServerKey.save`): nothing typed keeps the
    /// saved key as it is, even one that couldn't be read.
    func saveServerKey(typed: String?) -> ServerKey.SaveResult {
        let result = ServerKey.save(typed: typed, keychain)
        if result == .saved { serverKeyRead = .saved }
        return result
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
         "emoji": emoji, "autocorrect": autocorrect, "typo_gate": typoGate, "mid_line": midLine,
         "other_apps_tokens": AppSettings.otherAppsTokens]
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
