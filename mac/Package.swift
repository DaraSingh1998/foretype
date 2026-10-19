// swift-tools-version:5.9
// Foretype macOS shell: Accessibility capture, ghost-text overlay, key tap and insertion,
// linked against the Rust core (../core) as a static library.
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let coreLibDir = packageDir.appendingPathComponent("../core/target/release").standardized.path

let package = Package(
    name: "Foretype",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CForetypeCore", path: "Sources/CForetypeCore"),
        .executableTarget(
            name: "Foretype",
            dependencies: ["CForetypeCore"],
            path: "Sources/Foretype",
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir]),
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
            ]
        ),
    ]
)
