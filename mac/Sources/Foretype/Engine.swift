import CForetypeCore
import Foundation

enum EngineEvent {
    /// `replace`: text before the caret an accept deletes first (emoji, autocorrect), with
    /// `label` saying what it stands for; for a `details` fill, `label` names the detail.
    case suggestion(revision: UInt64, text: String, source: String, ms: Double?, replace: String, label: String)
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
                                 label: o["label"] as? String ?? ""))
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

    /// What a next-word or whole-suggestion accept inserts; delete `replace` first.
    func accept(all: Bool) -> (insert: String, remaining: String, replace: String)? {
        guard let handle, let raw = ft_engine_accept(handle, all ? 1 : 0) else { return nil }
        defer { ft_string_free(raw) }
        guard let data = String(cString: raw).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return (o["insert"] ?? "", o["remaining"] ?? "", o["replace"] ?? "")
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

    func historyStats() -> (records: Int, words: Int) {
        guard let handle, let raw = ft_engine_history_stats(handle) else { return (0, 0) }
        defer { ft_string_free(raw) }
        let o = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Int]) ?? [:]
        return (o["records"] ?? 0, o["words"] ?? 0)
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
