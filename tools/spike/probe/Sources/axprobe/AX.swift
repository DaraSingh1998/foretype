import ApplicationServices
import Foundation

func axErrName(_ e: AXError) -> String {
    switch e {
    case .success: return "ok"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete" // also what a messaging timeout looks like
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "axError\(e.rawValue)"
    }
}

/// Records every AX round trip with its latency and result, so each snapshot
/// carries its own timing breakdown.
final class CallLog {
    struct Call { let label: String; let err: AXError; let ms: Double }
    private(set) var calls: [Call] = []
    var focusSource: String?

    /// Records a non-AX step (e.g. an AppKit lookup) alongside the AX calls.
    func note(_ label: String, ok: Bool, ms: Double) {
        calls.append(Call(label: label, err: ok ? .success : .failure, ms: ms))
    }

    func copy(_ el: AXUIElement, _ attr: String, label: String? = nil) -> CFTypeRef? {
        var v: CFTypeRef?
        let t = Clock.nowNs()
        let e = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        calls.append(Call(label: label ?? attr, err: e, ms: Clock.ms(since: t)))
        return e == .success ? v : nil
    }

    func copyParam(_ el: AXUIElement, _ attr: String, _ param: CFTypeRef, label: String) -> CFTypeRef? {
        var v: CFTypeRef?
        let t = Clock.nowNs()
        let e = AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, param, &v)
        calls.append(Call(label: label, err: e, ms: Clock.ms(since: t)))
        return e == .success ? v : nil
    }

    @discardableResult
    func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef, label: String? = nil) -> AXError {
        let t = Clock.nowNs()
        let e = AXUIElementSetAttributeValue(el, attr as CFString, value)
        calls.append(Call(label: label ?? "set:\(attr)", err: e, ms: Clock.ms(since: t)))
        return e
    }

    var totalMs: Double { calls.reduce(0) { $0 + $1.ms } }

    var json: [[String: Any]] {
        calls.map { ["call": $0.label, "err": axErrName($0.err), "ms": r3($0.ms)] }
    }
}

func asElement(_ v: CFTypeRef?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

private func axValue(_ v: CFTypeRef?, _ type: AXValueType) -> AXValue? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let av = v as! AXValue
    return AXValueGetType(av) == type ? av : nil
}

func axRange(_ v: CFTypeRef?) -> CFRange? {
    guard let av = axValue(v, .cfRange) else { return nil }
    var r = CFRange()
    return AXValueGetValue(av, .cfRange, &r) ? r : nil
}

func axRect(_ v: CFTypeRef?) -> CGRect? {
    guard let av = axValue(v, .cgRect) else { return nil }
    var r = CGRect.zero
    return AXValueGetValue(av, .cgRect, &r) ? r : nil
}

func axPoint(_ v: CFTypeRef?) -> CGPoint? {
    guard let av = axValue(v, .cgPoint) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(av, .cgPoint, &p) ? p : nil
}

func axSize(_ v: CFTypeRef?) -> CGSize? {
    guard let av = axValue(v, .cgSize) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(av, .cgSize, &s) ? s : nil
}

func makeRange(_ location: Int, _ length: Int) -> AXValue {
    var r = CFRange(location: location, length: length)
    return AXValueCreate(.cfRange, &r)!
}

func rangeJSON(_ r: CFRange?) -> Any {
    guard let r else { return NSNull() }
    return ["location": r.location, "length": r.length]
}

func boolValue(_ v: CFTypeRef?) -> Bool? {
    guard let v, CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue((v as! CFBoolean))
}

/// Global display bounds in AX coordinates (top-left origin of the main display).
func displayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}
