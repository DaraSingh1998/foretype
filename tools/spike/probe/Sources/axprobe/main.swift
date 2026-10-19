import AppKit
import ApplicationServices
import Carbon

let usage = """
axprobe: Phase 0 Accessibility / event-tap probe. Prints one JSON object per line.

Modes (default: watch until Ctrl-C):
  --check                 print permissions/environment line and exit
  --once                  snapshot the focused field once and exit
  --bench N               snapshot the focused field N times, print per-call latency stats, exit

Options:
  --chromium-ax           set AXManualAccessibility / AXEnhancedUserInterface on Chromium and
                          Electron apps when they become frontmost (restored on exit)
  --timeout-ms MS         global AX messaging timeout (default 80)
  --poll-ms MS            watch-mode poll interval (default 200)
  --duration S            exit watch mode after S seconds
  --no-keys               do not install the listen-only CGEventTap
  --log-chars             include typed characters in key lines (off by default)
  --type TEXT             synthesise TEXT as keystrokes into the frontmost app (watch mode)
  --type-start-ms MS      delay before typing (default 1500)
  --type-interval-ms MS   delay between characters (default 150)
  --goto-end              press Cmd+Down before typing
  --type-only-in BUNDLEID type only while this app is frontmost (checked before every key)
  --wait-trust            poll until Accessibility is granted instead of exiting
  --request-listen        ask for Input Monitoring (CGRequestListenEventAccess) before the tap
"""

struct Options {
    var check = false, once = false, bench: Int?
    var chromiumAX = false, keys = true, logChars = false, waitTrust = false, gotoEnd = false, requestListen = false
    var timeoutMs = 80.0, pollMs = 200, duration: Double?
    var typeText: String?, typeStartMs = 1500, typeIntervalMs = 150, typeOnlyIn: String?
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) -> String {
        guard !args.isEmpty else { Out.err("missing value for \(flag)"); exit(64) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--check": o.check = true
        case "--once": o.once = true
        case "--bench": o.bench = Int(value(a))
        case "--chromium-ax": o.chromiumAX = true
        case "--timeout-ms": o.timeoutMs = Double(value(a)) ?? 80
        case "--poll-ms": o.pollMs = Int(value(a)) ?? 200
        case "--duration": o.duration = Double(value(a))
        case "--no-keys": o.keys = false
        case "--log-chars": o.logChars = true
        case "--type": o.typeText = value(a)
        case "--type-start-ms": o.typeStartMs = Int(value(a)) ?? 1500
        case "--type-interval-ms": o.typeIntervalMs = Int(value(a)) ?? 150
        case "--goto-end": o.gotoEnd = true
        case "--type-only-in": o.typeOnlyIn = value(a)
        case "--wait-trust": o.waitTrust = true
        case "--request-listen": o.requestListen = true
        case "-h", "--help": print(usage); exit(0)
        default: Out.err("unknown argument \(a)\n\n\(usage)"); exit(64)
        }
    }
    return o
}

func environment(_ o: Options) -> [String: Any] {
    var line: [String: Any] = [
        "type": "env",
        "axTrusted": AXIsProcessTrusted(),
        "listenEventAccess": CGPreflightListenEventAccess(),
        "postEventAccess": CGPreflightPostEventAccess(),
        "secureInput": IsSecureEventInputEnabled(),
        "voiceOverRunning": NSWorkspace.shared.isVoiceOverEnabled,
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "timeoutMs": o.timeoutMs,
        "chromiumAX": o.chromiumAX,
        "pid": Int(getpid()),
    ]
    if let parent = NSRunningApplication(processIdentifier: getppid()) { line["parentApp"] = parent.bundleIdentifier }
    return line
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[Int((p / 100 * Double(s.count - 1)).rounded())]
}

func stats(_ xs: [Double]) -> [String: Any] {
    ["n": xs.count, "p50": r3(percentile(xs, 50)), "p90": r3(percentile(xs, 90)),
     "max": r3(xs.max() ?? .nan), "mean": r3(xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count))]
}

/// Lets the main run loop deliver AX replies and timers while we wait.
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

func primeFocusedIfAsked(_ o: Options) {
    guard o.chromiumAX, let (_, pid) = Snapshot.focusedApp(CallLog()) else { return }
    if WebAX.engine(for: pid) != .other {
        WebAX.prime(pid: pid, reason: "cli")
        pump(0.5) // Chromium builds its tree lazily after the flag flips
    }
}

func runBench(_ o: Options, n: Int) {
    if o.chromiumAX { Out.emit(Snapshot.take(reason: "bench:beforePrime").json) }
    primeFocusedIfAsked(o)
    var perCall: [String: [Double]] = [:]
    var errors: [String: [String: Int]] = [:]
    var totals: [Double] = []
    var first: [String: Any]?
    for _ in 0..<n {
        let t = Clock.nowNs()
        let (json, _) = Snapshot.take(reason: "bench")
        totals.append(Clock.ms(since: t))
        if first == nil { first = json }
        for c in (json["calls"] as? [[String: Any]]) ?? [] {
            let label = c["call"] as! String, err = c["err"] as! String
            perCall[label, default: []].append(c["ms"] as! Double)
            if err != "ok" { errors[label, default: [:]][err, default: 0] += 1 }
        }
        pump(0.01)
    }
    if let first { Out.emit(first) }
    Out.emit(["type": "bench", "iterations": n, "app": first?["app"] ?? NSNull(), "role": first?["role"] ?? NSNull(),
              "snapshotMs": stats(totals), "perCall": perCall.mapValues(stats), "errors": errors])
}

func shutdown(_ o: Options) -> Never {
    KeyTap.stop()
    if o.chromiumAX { WebAX.restoreAll() }
    Out.emit(Probe.shared.summary)
    exit(0)
}

// MARK: - Entry

let opts = parseOptions()
// Global messaging timeout: applies to every element that has no per-element override.
AXUIElementSetMessagingTimeout(Snapshot.systemWide, Float(opts.timeoutMs / 1000))
Snapshot.timeoutMs = opts.timeoutMs > 0 ? opts.timeoutMs : 6000

Out.emit(environment(opts))
if opts.check { exit(0) }

if !AXIsProcessTrusted() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    Out.err("axprobe: Accessibility not granted. Enable it for the app that launched this process "
        + "(System Settings > Privacy & Security > Accessibility), then re-run.")
    guard opts.waitTrust else { exit(2) }
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 1) }
    Out.emit(environment(opts))
}

if opts.once {
    if opts.chromiumAX { Out.emit(Snapshot.take(reason: "once:beforePrime").json) }
    primeFocusedIfAsked(opts)
    Out.emit(Snapshot.take(reason: "once").json)
    if opts.chromiumAX { WebAX.restoreAll() }
    exit(0)
}

if let n = opts.bench {
    runBench(opts, n: max(1, n))
    if opts.chromiumAX { WebAX.restoreAll() }
    exit(0)
}

// Watch mode.
KeyTap.logChars = opts.logChars
if opts.requestListen, !CGPreflightListenEventAccess() {
    Out.emit(["type": "listenAccessRequest", "granted": CGRequestListenEventAccess()])
}
if opts.keys { KeyTap.start() }
Probe.shared.chromiumAX = opts.chromiumAX
Probe.shared.pollMs = opts.pollMs
Probe.shared.start()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { shutdown(opts) }
    s.resume()
    return s
}

if let text = opts.typeText {
    Typer.run(text: text, startDelayMs: opts.typeStartMs, intervalMs: opts.typeIntervalMs, gotoEnd: opts.gotoEnd,
              onlyIn: opts.typeOnlyIn) {}
}
if let d = opts.duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + d) { shutdown(opts) }
}

withExtendedLifetime(signalSources) { CFRunLoopRun() }
