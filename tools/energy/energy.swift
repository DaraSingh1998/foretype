// Measures the energy a command uses on Apple silicon, without sudo.
//
// Reads the SoC's "Energy Model" counters through IOReport (the private framework behind
// powermetrics; macmon reads it the same way), once before and once after the command, and
// subtracts the idle power measured for the same length of time first.
//
//   swift tools/energy/energy.swift [--idle SECONDS] -- COMMAND [ARGS...]
//
// --idle defaults to 20 s; 0 skips the baseline. On macOS 27 the CPU, ANE and DRAM counters
// read zero unless the meter runs as root (sudo); the GPU counter is readable by anyone, and
// inference runs on the GPU. Output, on stderr after the command's own:
//   energy: cpu 12.34 J, gpu 5.67 J, ane 0.00 J, dram 1.23 J, total 19.24 J over 41.2 s
//   idle:   total 4.10 J over 20.0 s (0.199 W)
//   net:    11.04 J (total minus idle power over the run)
import Foundation

typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias SimpleGetInteger = @convention(c) (CFDictionary, Int32) -> Int64

guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
    FileHandle.standardError.write("energy: cannot load IOReport\n".data(using: .utf8)!)
    exit(1)
}
func sym<T>(_ name: String, _: T.Type) -> T {
    guard let p = dlsym(lib, name) else { fatalError("energy: \(name) missing") }
    return unsafeBitCast(p, to: T.self)
}
let copyChannels = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self)
let createSubscription = sym("IOReportCreateSubscription", CreateSubscription.self)
let createSamples = sym("IOReportCreateSamples", CreateSamples.self)
let createDelta = sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self)
let channelName = sym("IOReportChannelGetChannelName", ChannelString.self)
let unitLabel = sym("IOReportChannelGetUnitLabel", ChannelString.self)
let integerValue = sym("IOReportSimpleGetIntegerValue", SimpleGetInteger.self)

struct Meter {
    let sub: OpaquePointer
    let channels: CFMutableDictionary

    init() {
        guard let chans = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, chans) else {
            fatalError("energy: no Energy Model channels (not Apple silicon?)")
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let s = createSubscription(nil, desired, &subbed, 0, nil), let subbed else {
            fatalError("energy: IOReport subscription failed")
        }
        sub = s
        channels = subbed.takeRetainedValue()
    }

    func sample() -> CFDictionary {
        guard let s = createSamples(sub, channels, nil)?.takeRetainedValue() else { fatalError("energy: sample failed") }
        return s
    }

    /// Joules per channel name between two samples.
    func joules(from a: CFDictionary, to b: CFDictionary) -> [String: Double] {
        guard let delta = createDelta(a, b, nil)?.takeRetainedValue() as? [String: Any],
              let items = delta["IOReportChannels"] as? [CFDictionary] else { return [:] }
        var out: [String: Double] = [:]
        for item in items {
            guard let name = channelName(item)?.takeUnretainedValue() as String? else { continue }
            let unit = (unitLabel(item)?.takeUnretainedValue() as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
            let scale: Double
            switch unit {
            case "mJ": scale = 1e-3
            case "uJ", "µJ": scale = 1e-6
            case "nJ": scale = 1e-9
            default: continue
            }
            out[name, default: 0] += Double(integerValue(item, 0)) * scale
        }
        return out
    }
}

/// The SoC-level totals (per-cluster channels such as PCPU0 or ECPU are already included).
func summary(_ j: [String: Double]) -> (cpu: Double, gpu: Double, ane: Double, dram: Double) {
    (j["CPU Energy"] ?? 0, j["GPU Energy"] ?? 0, j["ANE"] ?? 0, j["DRAM"] ?? 0)
}

var args = Array(CommandLine.arguments.dropFirst())
var idleSeconds = 20.0
if let i = args.firstIndex(of: "--idle"), i + 1 < args.count {
    idleSeconds = Double(args[i + 1]) ?? idleSeconds
    args.removeSubrange(i...(i + 1))
}
guard let dash = args.firstIndex(of: "--"), dash + 1 < args.count else {
    FileHandle.standardError.write("usage: energy.swift [--idle SECONDS] -- COMMAND [ARGS...]\n".data(using: .utf8)!)
    exit(2)
}
let command = Array(args[(dash + 1)...])
let meter = Meter()
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

var idleWatts = 0.0
if idleSeconds > 0 {
    let a = meter.sample()
    Thread.sleep(forTimeInterval: idleSeconds)
    let s = summary(meter.joules(from: a, to: meter.sample()))
    let total = s.cpu + s.gpu + s.ane + s.dram
    idleWatts = total / idleSeconds
    err(String(format: "idle:   total %.2f J over %.1f s (%.3f W)", total, idleSeconds, idleWatts))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = command
let t0 = Date()
let before = meter.sample()
do { try p.run() } catch { err("energy: cannot run \(command[0]): \(error)"); exit(1) }
p.waitUntilExit()
let after = meter.sample()
let secs = Date().timeIntervalSince(t0)
let s = summary(meter.joules(from: before, to: after))
let total = s.cpu + s.gpu + s.ane + s.dram
err(String(format: "energy: cpu %.2f J, gpu %.2f J, ane %.2f J, dram %.2f J, total %.2f J over %.1f s",
           s.cpu, s.gpu, s.ane, s.dram, total, secs))
if idleSeconds > 0 {
    err(String(format: "net:    %.2f J (total minus idle power over the run)", total - idleWatts * secs))
}
if s.cpu == 0 && getuid() != 0 {
    err("note:   CPU/ANE/DRAM counters read 0 without root on this macOS; run with sudo to include them")
}
exit(p.terminationStatus)
