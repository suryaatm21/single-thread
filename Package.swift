// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "single-thread",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SingleThread", targets: ["SingleThread"]),
    ],
    targets: [
        // Pure logic: no AppKit, fully unit tested.
        .target(name: "SingleThreadCore"),
        // The menu-bar app and its command-line subcommands.
        .executableTarget(
            name: "SingleThread",
            dependencies: ["SingleThreadCore"]
        ),
        .testTarget(
            name: "SingleThreadCoreTests",
            dependencies: ["SingleThreadCore"]
        ),
    ],
    // Accessibility and CoreFoundation callbacks are C APIs; Swift 6 strict
    // concurrency adds noise there without catching real bugs in this app.
    swiftLanguageModes: [.v5]
)
