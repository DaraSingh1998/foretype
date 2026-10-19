// swift-tools-version:5.9
// Foretype macOS shell: Accessibility capture, ghost-text overlay, key tap and insertion,
// linked against the Rust core (../core) as a static library.
//
// FORETYPE_SPARKLE=1 adds the Sparkle 2 updater (release builds); default builds don't fetch it.
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let coreLibDir = packageDir.appendingPathComponent("../core/target/release").standardized.path
let useSparkle = ProcessInfo.processInfo.environment["FORETYPE_SPARKLE"] == "1"

var appDependencies: [Target.Dependency] = ["CForetypeCore"]
var extraLinker: [String] = []
if useSparkle {
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
    extraLinker = ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]
}

let package = Package(
    name: "Foretype",
    platforms: [.macOS(.v14)],
    dependencies: useSparkle ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")] : [],
    targets: [
        .systemLibrary(name: "CForetypeCore", path: "Sources/CForetypeCore"),
        .executableTarget(
            name: "Foretype",
            dependencies: appDependencies,
            path: "Sources/Foretype",
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir] + extraLinker),
                .linkedLibrary("foretype_core"),
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
