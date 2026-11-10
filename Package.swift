// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BarLens",
    // Compiler deployment baseline for SwiftPM 5.9 (so `swift test` can run in
    // standard CI environments); runtime requires macOS 27.0+ (enforced via
    // LSMinimumSystemVersion in Resources/Info.plist and MBPrivateAPIAvailable()).
    platforms: [.macOS(.v14)],
    targets: [
        // Isolates every call into Apple's private menu bar API.
        .target(
            name: "CMenuBarPrivate",
            path: "Sources/CMenuBarPrivate"
        ),
        // The UI app / agent channel.
        .target(
            name: "DividerIPC",
            path: "Sources/DividerIPC"
        ),
        // Draws the menu bar trigger, Liquid Glass floating bar, and Settings UI.
        // Must never hold the assertion itself — see AgentCommand.
        .executableTarget(
            name: "BarLens",
            dependencies: ["CMenuBarPrivate", "DividerIPC"],
            path: "Sources/BarLens"
        ),
        // Holds the assertion. Has no status items of its own, which is the
        // whole point of it being a separate process.
        .executableTarget(
            name: "BarLensAgent",
            dependencies: ["CMenuBarPrivate", "DividerIPC"],
            path: "Sources/BarLensAgent"
        ),
        .testTarget(
            name: "BarLensTests",
            dependencies: ["BarLens", "DividerIPC"],
            path: "Tests/BarLensTests"
        ),
    ]
)
