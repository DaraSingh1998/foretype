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
if CommandLine.arguments.contains("--stats-selftest") {
    exit(UsageStats.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--geometry-selftest") {
    exit(ScreenGeometry.selfTest() ? 0 : 1)
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
