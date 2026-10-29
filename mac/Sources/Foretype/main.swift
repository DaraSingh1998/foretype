import AppKit

if CommandLine.arguments.contains("--ocr-selftest") {
    exit(ScreenContextProvider.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--font-selftest") {
    exit(FontMatcher.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--about-selftest") {
    exit(AboutYouStore.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--keychain-selftest") {
    exit(KeychainSelfTest.run() ? 0 : 1)
}
if CommandLine.arguments.contains("--stats-selftest") {
    exit(UsageStats.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--geometry-selftest") {
    exit(ScreenGeometry.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--context-selftest") {
    exit(ContextPool.selfTest() ? 0 : 1)
}
// --context-view-selftest [DIR]: the "What Foretype sees" window on made-up data; DIR gets PNGs.
if let i = CommandLine.arguments.firstIndex(of: "--context-view-selftest") {
    let next = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
    exit(ContextViewerController.selfTest(dir: next.flatMap { $0.hasPrefix("-") ? nil : $0 }) ? 0 : 1)
}
if CommandLine.arguments.contains("--ocr-bench") {
    exit(ContextPool.ocrBench() ? 0 : 1)
}
// --settings-selftest [DIR]: the Settings window on made-up screens; DIR gets a PNG per pane.
if let i = CommandLine.arguments.firstIndex(of: "--settings-selftest") {
    let next = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
    exit(PreferencesSelfTest.run(dir: next.flatMap { $0.hasPrefix("-") ? nil : $0 }) ? 0 : 1)
}
if CommandLine.arguments.contains("--esc-selftest") {
    exit(EscState.selfTest() ? 0 : 1)
}
// --alternatives-selftest [DIR]: the picker's state logic; DIR gets the card as PNGs.
if let i = CommandLine.arguments.firstIndex(of: "--alternatives-selftest") {
    let next = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
    exit(PickerState.selfTest(dir: next.flatMap { $0.hasPrefix("-") ? nil : $0 }) ? 0 : 1)
}
// --ghost-selftest [DIR]: the ghost text's wrapping layout; DIR gets wrapped examples as PNGs.
if let i = CommandLine.arguments.firstIndex(of: "--ghost-selftest") {
    let next = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
    exit(GhostPanel.selfTest(dir: next.flatMap { $0.hasPrefix("-") ? nil : $0 }) ? 0 : 1)
}
if CommandLine.arguments.contains("--electron-selftest") {
    exit(AppKind.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--compat-scan") {
    exit(CompatScan.run() ? 0 : 1)
}
if CommandLine.arguments.contains("--pause-selftest") {
    exit(PauseState.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--caret-selftest") {
    exit(PixelCaretSelfTest.run() ? 0 : 1)
}
// --caret-measure PID TITLE [POSITIONS]: pixel caret vs AX caret in a document you opened.
if let i = CommandLine.arguments.firstIndex(of: "--caret-measure"), i + 2 < CommandLine.arguments.count,
   let pid = pid_t(CommandLine.arguments[i + 1]) {
    let n = i + 3 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 3]) ?? 12 : 12
    // ScreenCaptureKit needs a window-server connection; never shows a Dock icon or takes focus.
    NSApplication.shared.setActivationPolicy(.prohibited)
    exit(CaretBench.run(pid: pid, title: CommandLine.arguments[i + 2], positions: n) ? 0 : 1)
}
// --capture-probe PID X Y W H: window vs display capture of a region, pixels changed per frame.
if let i = CommandLine.arguments.firstIndex(of: "--capture-probe"), i + 5 < CommandLine.arguments.count,
   let pid = pid_t(CommandLine.arguments[i + 1]) {
    let v = CommandLine.arguments[(i + 2)...(i + 5)].compactMap { Double($0) }
    NSApplication.shared.setActivationPolicy(.prohibited)
    // Waits (up to 3 minutes) for the app to come to the front, then for its caret to settle.
    for _ in 0..<1800 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
    sleep(2)
    exit(WindowCapture.probe(pid: pid, region: CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--resume-selftest"), i + 1 < CommandLine.arguments.count {
    exit(ModelManager.resumeSelfTest(id: CommandLine.arguments[i + 1]) ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--download-selftest"), i + 1 < CommandLine.arguments.count {
    exit(ModelManager.selfTest(id: CommandLine.arguments[i + 1]) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
