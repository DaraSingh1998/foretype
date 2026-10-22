import Foundation

/// Why Foretype is paused, if it is. Paused means nothing runs: no field reads, no event
/// taps, no screen captures, no model in memory (`Controller.setPaused`).
///
/// Three kinds of reason, any one enough:
/// - the user's own pause, until a time or until they resume; kept in UserDefaults
///   (`pausedUntil`), so it survives a relaunch or an update;
/// - the power rules (`PowerPolicy`); "Resume Anyway" sets the current ones aside until they
///   end or the Mac is plugged in;
/// - the system: sleep, a locked screen, display sleep (always, and never set aside).
///
/// Main thread.
final class PauseState {
    /// In order of precedence, for the one the menu names.
    enum PowerReason: String, CaseIterable {
        case thermal, batteryLow, lowPower, battery
    }

    enum SystemReason: String, CaseIterable {
        case sleep, lock, displaySleep
    }

    /// The user's pause ends then; `Date.distantFuture` is "until I resume".
    private(set) var userUntil: Date?
    /// Power reasons in effect: the policy's minus the ones set aside.
    private(set) var power: Set<PowerReason> = []
    private var powerActive: Set<PowerReason> = []
    private var setAside: Set<PowerReason> = []
    private(set) var system: Set<SystemReason> = []
    var onChange: (() -> Void)?
    private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before pausing existed, "Suggestions On" switched off was a pause with no end.
        if defaults.object(forKey: "enabled") as? Bool == false {
            defaults.set(Date.distantFuture, forKey: "pausedUntil")
        }
        defaults.removeObject(forKey: "enabled")
        if let until = defaults.object(forKey: "pausedUntil") as? Date, until > Date() {
            userUntil = until
            schedule()
        } else {
            defaults.removeObject(forKey: "pausedUntil")
        }
    }

    var isUserPaused: Bool { userUntil.map { $0 > Date() } ?? false }
    var isPaused: Bool { isUserPaused || !power.isEmpty || !system.isEmpty }
    /// The power rules would pause, but the user said to resume anyway.
    var powerSetAside: Bool { !setAside.isEmpty }
    var powerReason: PowerReason? { PowerReason.allCases.first { power.contains($0) } }
    var systemReason: SystemReason? { SystemReason.allCases.first { system.contains($0) } }
    /// The user's pause has no end time.
    var untilResumed: Bool { isUserPaused && userUntil == .distantFuture }

    /// Pauses until `until`, or until the user resumes (nil).
    func pause(until: Date?) {
        userUntil = until ?? .distantFuture
        defaults.set(userUntil, forKey: "pausedUntil")
        schedule()
        Log.debug("pause: user until \(until.map { "\($0)" } ?? "resumed")")
        onChange?()
    }

    /// Ends the user's pause (the power and system reasons stay).
    func resume() {
        guard userUntil != nil else { return }
        clearUser()
        Log.debug("pause: user resumed")
        onChange?()
    }

    /// The policy's current pause reasons. Reasons set aside stay so while they last; a new
    /// one pauses again. Plugging in (`justPluggedIn`) ends every set-aside.
    func setPower(_ reasons: Set<PowerReason>, justPluggedIn: Bool) {
        if justPluggedIn { setAside.removeAll() }
        setAside.formIntersection(reasons)
        powerActive = reasons
        update()
    }

    /// "Resume Anyway": sets the power reasons in effect aside.
    func setPowerAside() {
        setAside.formUnion(powerActive)
        Log.debug("pause: power reasons set aside: \(setAside.map(\.rawValue).sorted())")
        update(force: true)
    }

    func setSystem(_ reason: SystemReason, _ on: Bool) {
        if on { system.insert(reason) } else { system.remove(reason) }
        expireIfDue()
        update(force: true)
    }

    /// After a wake: a timer does not count time asleep, so a pause may have ended unseen.
    func expireIfDue() {
        if let until = userUntil, until <= Date() { clearUser() }
    }

    private func update(force: Bool = false) {
        let now = powerActive.subtracting(setAside)
        guard force || now != power else { return }
        power = now
        onChange?()
    }

    private func clearUser() {
        userUntil = nil
        defaults.removeObject(forKey: "pausedUntil")
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let until = userUntil, until != .distantFuture else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.expireIfDue()
            Log.debug("pause: user pause ended")
            self.onChange?()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

extension PauseState {
    /// `Foretype --pause-selftest`: the power rules, setting them aside, the migration and the
    /// saved pause, in a defaults suite of its own. Needs no permissions.
    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ what: String) {
            if !c { print("FAILED: \(what)"); ok = false }
        }
        let decide = { (s: PowerState, b: PowerPolicy.BatteryMode, l: PowerPolicy.LowPowerMode, below: Int) in
            PowerPolicy.decide(s, battery: b, lowPower: l, pauseBelow: below)
        }
        var s = PowerState(hasBattery: true, onBattery: false, batteryPercent: 15)
        check(decide(s, .save, .pause, 20) == .init(), "plugged in: full speed, low charge ignored")
        s.onBattery = true
        check(decide(s, .save, .pause, 0) == .init(pause: [], saveEnergy: true), "battery: save energy")
        check(decide(s, .full, .pause, 0) == .init(), "battery, full speed")
        check(decide(s, .pause, .pause, 20).pause == [.battery, .batteryLow], "battery: pause, and below 20%")
        s.lowPowerMode = true
        check(decide(s, .full, .pause, 0).pause == [.lowPower], "Low Power Mode pauses")
        check(decide(s, .full, .save, 0) == .init(pause: [], saveEnergy: true), "Low Power Mode saves energy")
        s = PowerState(thermal: .serious)
        check(decide(s, .save, .pause, 0) == .init(pause: [], saveEnergy: true), "serious thermal state saves energy")
        s.thermal = .critical
        check(decide(s, .save, .pause, 0).pause == [.thermal], "critical thermal state pauses")

        let name = "dev.foretype.selftest.\(ProcessInfo.processInfo.processIdentifier)"
        guard let d = UserDefaults(suiteName: name) else { return false }
        defer { d.removePersistentDomain(forName: name) }
        d.set(false, forKey: "enabled")
        var p = PauseState(defaults: d)
        check(p.untilResumed && d.object(forKey: "enabled") == nil, "Suggestions Off becomes paused until resumed")
        p.resume()
        check(!p.isPaused && d.object(forKey: "pausedUntil") == nil, "resume clears the saved pause")
        p.pause(until: Date().addingTimeInterval(600))
        check(PauseState(defaults: d).isUserPaused, "a timed pause survives a relaunch")
        d.set(Date().addingTimeInterval(-5), forKey: "pausedUntil")
        check(!PauseState(defaults: d).isPaused, "an ended pause is dropped at launch")
        p = PauseState(defaults: d)
        p.setPower([.lowPower], justPluggedIn: false)
        check(p.powerReason == .lowPower, "power reason pauses")
        p.setPowerAside()
        check(!p.isPaused && p.powerSetAside, "Resume Anyway")
        p.setPower([.lowPower, .batteryLow], justPluggedIn: false)
        check(p.powerReason == .batteryLow, "a new reason pauses again")
        p.setPower([], justPluggedIn: false)
        p.setPower([.lowPower], justPluggedIn: false)
        check(p.powerReason == .lowPower, "a reason that ended and came back pauses again")
        p.setPowerAside()
        p.setPower([.lowPower], justPluggedIn: true)
        check(p.powerReason == .lowPower, "plugging in ends Resume Anyway")
        p.setPower([], justPluggedIn: false)
        p.setSystem(.lock, true)
        check(p.isPaused && p.systemReason == .lock, "a locked screen pauses")
        p.setSystem(.lock, false)
        check(!p.isPaused, "unlocking resumes")
        print(ok ? "Pause self-test passed" : "Pause self-test FAILED")
        return ok
    }
}

/// The menu's and Settings' pause lengths.
enum PauseChoice: Int, CaseIterable {
    case minutes15, hour1, tomorrow, untilResumed

    var title: String {
        switch self {
        case .minutes15: return L("For 15 Minutes")
        case .hour1: return L("For 1 Hour")
        case .tomorrow: return L("Until Tomorrow")
        case .untilResumed: return L("Until I Resume")
        }
    }

    /// When the pause ends; nil for until resumed. "Tomorrow" is 6 in the morning.
    var until: Date? {
        let now = Date()
        switch self {
        case .minutes15: return now.addingTimeInterval(15 * 60)
        case .hour1: return now.addingTimeInterval(60 * 60)
        case .tomorrow:
            let cal = Calendar.current
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            return cal.date(byAdding: .hour, value: 6, to: tomorrow)
        case .untilResumed: return nil
        }
    }
}

/// What the battery, Low Power Mode, the battery level and the temperature ask for.
enum PowerPolicy {
    /// Settings ▸ General ▸ On battery.
    enum BatteryMode: String, CaseIterable {
        case full, save, pause
    }

    /// Settings ▸ General ▸ Low Power Mode.
    enum LowPowerMode: String, CaseIterable {
        case save, pause
    }

    /// Battery-level thresholds offered (0 = off).
    static let batteryLevels = [0, 10, 20, 30]

    struct Decision: Equatable {
        var pause: Set<PauseState.PowerReason> = []
        /// Lighter suggestions: greedy, no prefetch, an 80 ms mid-word wait, no screen OCR,
        /// the model freed after a minute idle.
        var saveEnergy = false
    }

    static func decide(_ s: PowerState, battery: BatteryMode, lowPower: LowPowerMode, pauseBelow: Int) -> Decision {
        var d = Decision()
        if s.onBattery {
            switch battery {
            case .full: break
            case .save: d.saveEnergy = true
            case .pause: d.pause.insert(.battery)
            }
            if pauseBelow > 0, let p = s.batteryPercent, p < pauseBelow { d.pause.insert(.batteryLow) }
        }
        if s.lowPowerMode {
            switch lowPower {
            case .save: d.saveEnergy = true
            case .pause: d.pause.insert(.lowPower)
            }
        }
        switch s.thermal {
        case .serious: d.saveEnergy = true
        case .critical: d.pause.insert(.thermal)
        default: break
        }
        return d
    }
}
