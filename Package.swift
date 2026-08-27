// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PenBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TabletCore", targets: ["TabletCore"]),
        .executable(name: "penbridge", targets: ["PenBridge"]),
        .executable(name: "PenBridgeApp", targets: ["PenBridgeApp"]),
    ],
    targets: [
        // The IOKit and CoreGraphics callback plumbing is single-threaded by
        // construction (one run loop owns the device), so Swift 5 mode keeps the
        // interop readable instead of wrapping every C callback in concurrency ceremony.
        .target(name: "TabletCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "PenBridge", dependencies: ["TabletCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PenBridgeApp", dependencies: ["TabletCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "TabletCoreTests", dependencies: ["TabletCore"]),
    ]
)
