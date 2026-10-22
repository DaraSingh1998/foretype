import AppKit
import IOKit.ps

/// What the power rules look at.
struct PowerState: Equatable {
    /// The Mac has an internal battery (the battery settings are hidden otherwise).
    var hasBattery = false
    var onBattery = false
    /// Charge of the internal battery, 0-100; nil without one.
    var batteryPercent: Int?
    var lowPowerMode = false
    var thermal = ProcessInfo.ThermalState.nominal

    static func read() -> PowerState {
        var s = PowerState()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.thermal = ProcessInfo.processInfo.thermalState
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return s }
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            s.onBattery = (type as String) == kIOPMBatteryPowerKey
        }
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            s.hasBattery = true
            if let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                s.batteryPercent = current * 100 / max
            }
        }
        return s
    }
}

/// Follows the power source, battery charge, Low Power Mode and the thermal state through
/// their notifications (no polling). Main thread.
final class PowerMonitor {
    private(set) var state = PowerState.read()
    var onChange: ((PowerState) -> Void)?
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // Fires when the power source changes and as the charge moves (about once per percent).
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            // Posted on any thread.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }

    private func refresh() {
        let now = PowerState.read()
        guard now != state else { return }
        state = now
        onChange?(now)
    }
}

/// Follows sleep, the screen lock, display sleep and fast user switching, during which
/// Foretype always pauses. Main thread.
final class SessionMonitor {
    enum Event { case sleep, lock, displaySleep }
    var onChange: ((Event, Bool) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Whether the login session's screen is locked now.
    static var isScreenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        watch(ws, NSWorkspace.willSleepNotification) { $0(.sleep, true) }
        watch(ws, NSWorkspace.didWakeNotification) { report in
            // A Mac that locks on sleep may report the lock only after it wakes.
            if SessionMonitor.isScreenLocked { report(.lock, true) }
            report(.sleep, false)
        }
        watch(ws, NSWorkspace.screensDidSleepNotification) { $0(.displaySleep, true) }
        watch(ws, NSWorkspace.screensDidWakeNotification) { $0(.displaySleep, false) }
        // Another user's session in front: nothing here is being typed.
        watch(ws, NSWorkspace.sessionDidResignActiveNotification) { $0(.lock, true) }
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification) { report in
            if !SessionMonitor.isScreenLocked { report(.lock, false) }
        }
        let dist = DistributedNotificationCenter.default()
        watch(dist, Notification.Name("com.apple.screenIsLocked")) { $0(.lock, true) }
        watch(dist, Notification.Name("com.apple.screenIsUnlocked")) { $0(.lock, false) }
        if SessionMonitor.isScreenLocked { onChange?(.lock, true) }
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name,
                       _ handle: @escaping (_ report: (Event, Bool) -> Void) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.debug("session: \(name.rawValue)")
            handle { event, on in self.onChange?(event, on) }
        }
        observers.append((center, token))
    }
}
