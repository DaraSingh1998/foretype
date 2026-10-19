import AppKit
import ApplicationServices
import Carbon

/// Watch mode: AXObserver notifications on the frontmost app, plus a poll that both
/// catches what notifications miss and records that it had to (source = "poll").
final class Probe {
    static let shared = Probe()

    var chromiumAX = false
    var pollMs = 200

    private var currentPid: pid_t = 0
    private var observer: AXObserver?
    private var lastSignature: Signature?
    private var lastSecureInput: Bool?
    private var notificationCounts: [String: Int] = [:]
    private var pollCatches = 0
    private var emitted = 0
    private var timer: Timer?

    private static let notifications = [
        "AXFocusedUIElementChanged", "AXSelectedTextChanged", "AXValueChanged", "AXFocusedWindowChanged",
    ]

    private static let axCallback: AXObserverCallback = { _, _, name, _ in
        Probe.shared.onNotification(name as String)
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Double(pollMs) / 1000, repeats: true) { _ in
            Probe.shared.tick()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Probe.shared.appChanged(to: app.processIdentifier, source: "workspaceActivate")
        }
    }

    var summary: [String: Any] {
        ["type": "summary", "snapshotsEmitted": emitted, "notifications": notificationCounts,
         "changesOnlySeenByPoll": pollCatches, "keyDowns": KeyState.keyDowns]
    }

    private func tick() {
        let secure = IsSecureEventInputEnabled()
        if secure != lastSecureInput {
            lastSecureInput = secure
            var line: [String: Any] = ["type": "secureInput", "enabled": secure]
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
               let holder = session["kCGSSessionSecureInputPID"] as? Int {
                line["holder"] = Snapshot.appInfo(pid_t(holder))
            }
            Out.emit(line)
        }
        let log = CallLog()
        guard let (_, pid) = Snapshot.focusedApp(log) else { return }
        if pid != currentPid {
            appChanged(to: pid, source: "poll")
            return
        }
        guard let quick = Snapshot.quickSignature() else { return }
        if pollKey(quick) != lastSignature.map(pollKey), emitSnapshot(reason: "poll", force: false) {
            pollCatches += 1
        }
    }

    /// Fields the cheap poll read can compare against a full snapshot.
    private func pollKey(_ s: Signature) -> [Int] { [Int(s.pid), s.elementHash] + s.selection }

    func appChanged(to pid: pid_t, source: String) {
        guard pid != currentPid, pid > 0 else { return }
        currentPid = pid
        registerObserver(pid: pid)
        if chromiumAX { WebAX.prime(pid: pid, reason: "activate") }
        emitSnapshot(reason: "appActivated:\(source)", force: true)
    }

    private func registerObserver(pid: pid_t) {
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
        }
        var obs: AXObserver?
        let createErr = AXObserverCreate(pid, Probe.axCallback, &obs)
        var results: [String: String] = [:]
        if createErr == .success, let obs {
            let app = AXUIElementCreateApplication(pid)
            for n in Probe.notifications {
                results[n] = axErrName(AXObserverAddNotification(obs, app, n as CFString, nil))
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = obs
        }
        Out.emit(["type": "observer", "app": Snapshot.appInfo(pid),
                  "create": axErrName(createErr), "notifications": results])
    }

    private func onNotification(_ name: String) {
        notificationCounts[name, default: 0] += 1
        emitSnapshot(reason: name, force: name == "AXFocusedUIElementChanged")
    }

    /// Emits a full snapshot when focus, selection, marked range or length changed.
    @discardableResult
    private func emitSnapshot(reason: String, force: Bool) -> Bool {
        let sinceKey = KeyState.msSinceLastKeyDown
        var (json, sig) = Snapshot.take(reason: reason)
        if !force, let sig, sig == lastSignature { return false }
        lastSignature = sig ?? lastSignature
        json["msSinceLastKeyDown"] = sinceKey.map { r3($0) } ?? NSNull()
        emitted += 1
        Out.emit(json)
        return true
    }
}
