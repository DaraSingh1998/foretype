import CForetypeCore
import Foundation

enum EngineEvent {
    /// `replace`: text before the caret an accept deletes first (emoji, autocorrect), with
    /// `label` saying what it stands for; for a `details` fill, `label` names the detail.
    /// `alternatives`: word alternatives (D50), other phrases for the same text, each with its
    /// own first word; source `alternatives` answers `requestAlternatives` (same text).
    case suggestion(revision: UInt64, text: String, source: String, ms: Double?, replace: String, label: String,
                    alternatives: [String])
    case status(state: String, detail: String)
}

/// Swift face of the Rust core's C ABI. Every method is safe to call from any thread;
/// events arrive on core threads (or synchronously inside `submit`).
final class EngineBridge {
    private var handle: OpaquePointer?
    var onEvent: ((EngineEvent) -> Void)?

    init?(configJSON: String) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        handle = ft_engine_new(configJSON, { ctx, json in
            guard let ctx, let json else { return }
            Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue().dispatch(String(cString: json))
        }, ctx)
        if handle == nil { return nil }
    }

    deinit {
        if let handle { ft_engine_free(handle) }
    }

    /// Stops the engine thread and frees the model (Metal asserts if it outlives exit).
    func shutdown() {
        if let h = handle {
            handle = nil
            ft_engine_free(h)
        }
    }

    private func dispatch(_ json: String) {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = o["type"] as? String else { return }
        switch type {
        case "suggestion":
            onEvent?(.suggestion(revision: (o["revision"] as? NSNumber)?.uint64Value ?? 0,
                                 text: o["text"] as? String ?? "",
                                 source: o["source"] as? String ?? "",
                                 ms: (o["ms"] as? NSNumber)?.doubleValue,
                                 replace: o["replace"] as? String ?? "",
                                 label: o["label"] as? String ?? "",
                                 alternatives: o["alternatives"] as? [String] ?? []))
        case "status":
            onEvent?(.status(state: o["state"] as? String ?? "", detail: o["detail"] as? String ?? ""))
        default:
            break
        }
    }

    func submit(_ snap: FieldSnapshot) {
        guard let handle else { return }
        ft_engine_submit(handle, snap.coreJSON())
    }

    func warm(_ snap: FieldSnapshot) {
        guard let handle else { return }
        ft_engine_warm(handle, snap.coreJSON())
    }

    /// New screen text for the latest snapshot while the user pauses (`ft_engine_refresh`).
    func refresh(_ snap: FieldSnapshot) {
        guard let handle else { return }
        ft_engine_refresh(handle, snap.coreJSON())
    }

    /// What a next-word or whole-suggestion accept inserts; delete `replace` first.
    func accept(all: Bool) -> (insert: String, remaining: String, replace: String)? {
        guard let handle, let raw = ft_engine_accept(handle, all ? 1 : 0) else { return nil }
        defer { ft_string_free(raw) }
        guard let data = String(cString: raw).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return (o["insert"] ?? "", o["remaining"] ?? "", o["replace"] ?? "")
    }

    /// Takes the next word of alternative `index` (0 for Option-1), which becomes the
    /// suggestion; nil when there is no such alternative.
    func acceptAlternative(_ index: Int) -> (insert: String, remaining: String, replace: String)? {
        guard let handle, let raw = ft_engine_accept_alternative(handle, Int32(index)) else { return nil }
        defer { ft_string_free(raw) }
        guard let data = String(cString: raw).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return (o["insert"] ?? "", o["remaining"] ?? "", o["replace"] ?? "")
    }

    /// Asks for alternatives to the suggestion showing for `snap` (the latest snapshot): the
    /// answer is a `.suggestion` event with source `alternatives`, at once or after a search.
    func requestAlternatives(_ snap: FieldSnapshot) {
        guard let handle else { return }
        ft_engine_alternatives(handle, snap.coreJSON())
    }

    func dismiss(fieldKey: UInt64, textBefore: String) {
        guard let handle else { return }
        ft_engine_dismiss(handle, fieldKey, textBefore)
    }

    /// Answers the "shell" backend's requests (Apple's on-device model). Called on the core's
    /// engine thread; may block.
    private var completer: ((String) -> String?)?

    func setCompleter(_ f: @escaping (String) -> String?) {
        guard let handle else { return }
        completer = f
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        ft_engine_set_completer(handle, { ctx, json in
            guard let ctx, let json else { return nil }
            let me = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
            guard let out = me.completer?(String(cString: json)) else { return nil }
            return strdup(out)
        }, ctx)
    }

    /// Settings as the core's JSON (`Controller.coreSettingsJSON`). With `"paused": true` the
    /// core drops its work, frees the model and reports `.status("paused", ...)`; `submit`
    /// and `warm` are then answered or ignored without waking it.
    @discardableResult
    func configure(_ json: String) -> Bool {
        guard let handle else { return false }
        return ft_engine_configure(handle, json)
    }

    /// The user's own details (`AboutYou.coreJSON`), for fills and the prompt's writer line.
    @discardableResult
    func setDetails(_ json: String) -> Bool {
        guard let handle else { return false }
        return ft_engine_set_details(handle, json)
    }

    /// Text from other apps' windows (`ContextPool.Store.json`), sent when the pool changes.
    @discardableResult
    func setContext(_ json: String) -> Bool {
        guard let handle else { return false }
        return ft_engine_set_context(handle, json)
    }

    /// What the core holds of other apps' text and what the last prompt took from it
    /// (`ft_engine_context_report`), for the "What Foretype sees" window. Read only.
    func contextReport() -> ContextReport? {
        guard let handle, let raw = ft_engine_context_report(handle) else { return nil }
        defer { ft_string_free(raw) }
        return try? JSONDecoder().decode(ContextReport.self, from: Data(String(cString: raw).utf8))
    }

    func historyStats() -> (records: Int, words: Int) {
        let o = historyStatsJSON()
        return (o["records"] as? Int ?? 0, o["words"] as? Int ?? 0)
    }

    /// The history file is there but its key opens none of it (or it can't be read): the
    /// core keeps it as it is and records nothing until it is deleted.
    var historyKeyMismatch: Bool { historyStatsJSON()["locked"] as? Bool ?? false }

    private func historyStatsJSON() -> [String: Any] {
        guard let handle, let raw = ft_engine_history_stats(handle) else { return [:] }
        defer { ft_string_free(raw) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any]) ?? [:]
    }

    /// Adds earlier writing as `(app, text)` records; returns how many were kept (texts under
    /// 20 characters are skipped), or nil on error.
    func importHistory(_ items: [(app: String, text: String)]) -> Int? {
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: items.map { ["app": $0.app, "text": $0.text] }),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let n = ft_engine_import_history(handle, json)
        return n < 0 ? nil : Int(n)
    }

    @discardableResult
    func clearHistory() -> Bool {
        guard let handle else { return false }
        return ft_engine_clear_history(handle)
    }

    @discardableResult
    func openHistory(path: String, keyHex: String) -> Bool {
        guard let handle else { return false }
        return ft_engine_open_history(handle, path, keyHex)
    }

    func compatRule(_ bundleId: String) -> [String: Any] {
        guard let handle, let raw = ft_engine_compat_rule(handle, bundleId) else { return [:] }
        defer { ft_string_free(raw) }
        let data = String(cString: raw).data(using: .utf8) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// `ft_engine_context_report`'s JSON. Tokens are the core's estimate, the budget's unit.
struct ContextReport: Decodable, Equatable {
    struct Passage: Decodable, Equatable {
        /// The window's header line in the prompt ("Microsoft Word — Q3 Budget Review.docx").
        var label: String
        var app: String
        var bundle_id: String
        var ordinal: Int
        var tokens: Int
        var text: String
    }

    struct Last: Decodable, Equatable {
        /// Seconds since 1970.
        var at: Double
        var tokens: Int
        /// The prompt ran without its section, which didn't fit the model's context.
        var left_out: Bool
        /// Passages it held whose window has left the pool since (not shown).
        var gone: Int
        var passages: [Passage]
    }

    /// A server makes suggestions: nothing from other apps is kept or sent.
    var server = false
    var windows = 0
    var passages = 0
    var budget = 0
    var changes = 0
    var last: Last?
}

/// The website a page belongs to (`ft_site_of`): its `host` ("mail.google.com") and the
/// `domain` its organisation shares ("google.com", the host itself when it has no shorter one).
/// A website's instructions are kept under the host, or under "*." and the domain for every
/// page of the domain (`AppSettings.siteInstructions`).
struct Site: Decodable, Equatable {
    let host: String
    let domain: String

    /// Nil for a page that isn't http(s).
    static func of(url: String) -> Site? {
        guard !url.isEmpty, let raw = ft_site_of(url) else { return nil }
        defer { ft_string_free(raw) }
        return try? JSONDecoder().decode(Site.self, from: Data(String(cString: raw).utf8))
    }

    /// The key for this host only, or for every page of the domain.
    func key(wholeDomain: Bool) -> String { wholeDomain ? "*." + domain : host }

    /// The keys a note for this page can be kept under: the host and the whole domain (on
    /// google.com itself too, where the domain's also covers mail.google.com), or the host
    /// alone for an IP address.
    var keys: [String] {
        let address = host.hasPrefix("[") || host.allSatisfy { $0.isNumber || $0 == "." }
        return address ? [host] : [key(wholeDomain: false), key(wholeDomain: true)]
    }

    /// Whether a key covers more than one host ("*.google.com").
    static func isDomainKey(_ key: String) -> Bool { key.hasPrefix("*.") }

    /// How a key reads in Settings: "mail.google.com", or "All of google.com".
    static func describe(_ key: String) -> String {
        isDomainKey(key) ? L("All of %@", String(key.dropFirst(2))) : key
    }
}

/// The custom instructions a fresh install starts with (`core/data/default-instructions.json`).
struct DefaultInstructions: Decodable {
    let global: String
    /// By bundle ID, added after `global` in that app.
    let apps: [String: String]

    static let shared: DefaultInstructions = {
        let none = DefaultInstructions(global: "", apps: [:])
        guard let raw = ft_default_instructions() else { return none }
        defer { ft_string_free(raw) }
        return (try? JSONDecoder().decode(DefaultInstructions.self, from: Data(String(cString: raw).utf8))) ?? none
    }()
}
