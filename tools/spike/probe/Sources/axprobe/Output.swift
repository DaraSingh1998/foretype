import Foundation
import CoreGraphics

/// Monotonic clock helpers (CLOCK_UPTIME_RAW, nanoseconds).
enum Clock {
    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static func ms(since t: UInt64) -> Double { Double(nowNs() &- t) / 1e6 }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Lag between a CGEvent timestamp and now. Documented as nanoseconds since boot, but
    /// some macOS builds report mach ticks, so accept whichever reading is plausible.
    static func eventLagMs(_ ts: UInt64) -> Double? {
        let nowNs = nowNs()
        if ts <= nowNs, nowNs - ts < 10_000_000_000 { return Double(nowNs - ts) / 1e6 }
        let nowTicks = mach_absolute_time()
        if ts <= nowTicks {
            let ticks = nowTicks - ts
            let ns = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
            if ns < 10e9 { return ns / 1e6 }
        }
        return nil
    }
}

func orNull<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

func rectJSON(_ r: CGRect?) -> Any {
    guard let r else { return NSNull() }
    return ["x": r3(Double(r.origin.x)), "y": r3(Double(r.origin.y)),
            "w": r3(Double(r.size.width)), "h": r3(Double(r.size.height))]
}

private func unwrapAny(_ v: Any) -> Any? {
    let m = Mirror(reflecting: v)
    guard m.displayStyle == .optional else { return v }
    guard let child = m.children.first else { return nil }
    return unwrapAny(child.value)
}

/// Converts arbitrary AX/CF values into something JSONSerialization accepts.
func jsonSafe(_ value: Any) -> Any {
    guard let v = unwrapAny(value) else { return NSNull() }
    switch v {
    case let s as String: return s
    case let d as [String: Any]: return d.mapValues { jsonSafe($0) }
    case let a as [Any]: return a.map { jsonSafe($0) }
    case let d as NSDictionary:
        var out: [String: Any] = [:]
        for (k, val) in d { out["\(k)"] = jsonSafe(val) }
        return out
    case let a as NSArray: return a.map { jsonSafe($0) }
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        let d = n.doubleValue
        return d.isFinite ? n : NSNull()
    case is NSNull: return v
    default:
        let obj = v as AnyObject
        if CFGetTypeID(obj) == CGColor.typeID {
            let c = obj as! CGColor
            return ["cgColor": (c.components ?? []).map { r3(Double($0)) }]
        }
        return String(describing: v)
    }
}

/// One JSON object per line on stdout; diagnostics go to stderr.
enum Out {
    private static let lock = NSLock()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func emit(_ obj: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        var o = obj
        o["ts"] = iso.string(from: Date())
        o["uptimeS"] = r3(Double(Clock.nowNs()) / 1e9)
        let safe = jsonSafe(o)
        guard JSONSerialization.isValidJSONObject(safe),
              let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            FileHandle.standardError.write("axprobe: could not encode \(obj["type"] ?? "?") line\n".data(using: .utf8)!)
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    static func err(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
