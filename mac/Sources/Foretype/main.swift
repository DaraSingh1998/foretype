import AppKit

if CommandLine.arguments.contains("--ocr-selftest") {
    exit(ScreenContextProvider.selfTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--font-selftest") {
    exit(FontMatcher.selfTest() ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--download-selftest"), i + 1 < CommandLine.arguments.count {
    exit(ModelManager.selfTest(id: CommandLine.arguments[i + 1]) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
