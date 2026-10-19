import CForetypeCore
import Foundation

enum EngineEvent {
    case suggestion(revision: UInt64, text: String, source: String, ms: Double?)
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
                                 ms: (o["ms"] as? NSNumber)?.doubleValue))
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

    /// `(insert, remaining)` for next-word or whole-suggestion accept.
    func accept(all: Bool) -> (insert: String, remaining: String)? {
        guard let handle, let raw = ft_engine_accept(handle, all ? 1 : 0) else { return nil }
        defer { ft_string_free(raw) }
        guard let data = String(cString: raw).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return (o["insert"] ?? "", o["remaining"] ?? "")
    }

    func dismiss(fieldKey: UInt64, textBefore: String) {
        guard let handle else { return }
        ft_engine_dismiss(handle, fieldKey, textBefore)
    }

    @discardableResult
    func configure(_ json: String) -> Bool {
        guard let handle else { return false }
        return ft_engine_configure(handle, json)
    }

    func compatRule(_ bundleId: String) -> [String: Any] {
        guard let handle, let raw = ft_engine_compat_rule(handle, bundleId) else { return [:] }
        defer { ft_string_free(raw) }
        let data = String(cString: raw).data(using: .utf8) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
