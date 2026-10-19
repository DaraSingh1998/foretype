import AppKit
import ApplicationServices

/// Chromium/Electron accessibility priming (`--chromium-ax`).
/// Chromium builds its AX tree lazily; Electron honours AXManualAccessibility, Chrome
/// itself needs the VoiceOver signal AXEnhancedUserInterface.
enum WebAX {
    enum Engine: String { case chromium, electron, other }

    private static var engineCache: [pid_t: Engine] = [:]
    private static let cacheLock = NSLock()
    /// Values found before we touched each app, restored on exit.
    private static var original: [pid_t: (manual: Bool?, enhanced: Bool?)] = [:]

    private static let chromiumBundlePrefixes = [
        "com.google.Chrome", "org.chromium.", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "ai.perplexity.comet",
    ]

    static func engine(for pid: pid_t) -> Engine {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let e = engineCache[pid] { return e }
        var e = Engine.other
        if let app = NSRunningApplication(processIdentifier: pid) {
            let fw = app.bundleURL?.appendingPathComponent("Contents/Frameworks").path
            let names = fw.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0) } ?? []
            if names.contains("Electron Framework.framework") {
                e = .electron
            } else if let id = app.bundleIdentifier, chromiumBundlePrefixes.contains(where: { id.hasPrefix($0) }) {
                e = .chromium
            } else if names.contains(where: { $0.hasSuffix("Framework.framework") &&
                ($0.contains("Chrome") || $0.contains("Chromium")) }) {
                e = .chromium
            }
        }
        engineCache[pid] = e
        return e
    }

    /// Sets the flags, reads them back immediately and again after 100 ms (Tabber saw
    /// Chrome clear AXEnhancedUserInterface within ~50 ms of activation) and re-asserts.
    static func prime(pid: pid_t, reason: String) {
        let kind = engine(for: pid)
        guard kind != .other else { return }
        let app = AXUIElementCreateApplication(pid)
        let log = CallLog()
        let manualBefore = boolValue(log.copy(app, "AXManualAccessibility"))
        let enhancedBefore = boolValue(log.copy(app, "AXEnhancedUserInterface"))
        if original[pid] == nil { original[pid] = (manualBefore, enhancedBefore) }

        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        let manualErr = log.set(app, "AXManualAccessibility", kCFBooleanTrue)
        var enhancedErr: AXError?
        if !voiceOver, kind == .chromium || manualErr != .success {
            enhancedErr = log.set(app, "AXEnhancedUserInterface", kCFBooleanTrue)
        }
        let manualAfter = boolValue(log.copy(app, "AXManualAccessibility"))
        let enhancedAfter = boolValue(log.copy(app, "AXEnhancedUserInterface"))

        var line: [String: Any] = [
            "type": "webPrime", "reason": reason, "app": Snapshot.appInfo(pid),
            "voiceOverRunning": voiceOver,
            "before": ["AXManualAccessibility": orNull(manualBefore), "AXEnhancedUserInterface": orNull(enhancedBefore)],
            "setManual": axErrName(manualErr),
            "setEnhanced": enhancedErr.map { axErrName($0) } ?? "skipped",
            "after": ["AXManualAccessibility": orNull(manualAfter), "AXEnhancedUserInterface": orNull(enhancedAfter)],
        ]
        line["calls"] = log.json
        Out.emit(line)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            let log2 = CallLog()
            let m = boolValue(log2.copy(app, "AXManualAccessibility"))
            let en = boolValue(log2.copy(app, "AXEnhancedUserInterface"))
            var reasserted: [String] = []
            if manualErr == .success, m != true { log2.set(app, "AXManualAccessibility", kCFBooleanTrue); reasserted.append("AXManualAccessibility") }
            if enhancedErr == .success, en != true { log2.set(app, "AXEnhancedUserInterface", kCFBooleanTrue); reasserted.append("AXEnhancedUserInterface") }
            Out.emit(["type": "webPrimeReadback", "afterMs": 100, "app": Snapshot.appInfo(pid),
                      "AXManualAccessibility": orNull(m), "AXEnhancedUserInterface": orNull(en),
                      "reasserted": reasserted, "calls": log2.json])
        }
    }

    /// Puts AXEnhancedUserInterface / AXManualAccessibility back the way we found them,
    /// since the enhanced flag disturbs window managers.
    static func restoreAll() {
        for (pid, orig) in original {
            let app = AXUIElementCreateApplication(pid)
            let log = CallLog()
            if orig.enhanced != true { log.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
            if orig.manual != true { log.set(app, "AXManualAccessibility", kCFBooleanFalse) }
            Out.emit(["type": "webRestore", "app": Snapshot.appInfo(pid), "calls": log.json])
        }
        original.removeAll()
    }
}
