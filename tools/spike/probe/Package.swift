// swift-tools-version:5.9
// Phase 0 spike: Accessibility + event-tap probe for an inline-autocomplete agent.
import PackageDescription

let package = Package(
    name: "axprobe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "axprobe",
            path: "Sources/axprobe",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
