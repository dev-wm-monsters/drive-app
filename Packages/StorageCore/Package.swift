// swift-tools-version: 6.0
import PackageDescription

// StorageCore: pure-Swift, Foundation-only core for the B01 spike.
// Builds and tests on Linux; linked into the macOS app, the FSKit extension
// and the StorageService LaunchAgent. No external dependencies.
let package = Package(
    name: "StorageCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .executable(name: "fixture-check", targets: ["fixture-check"]),
    ],
    targets: [
        .target(name: "StorageCore"),
        // CLI logic lives in a library target so tests can drive it without spawning processes.
        .target(name: "FixtureCheckKit", dependencies: ["StorageCore"]),
        .executableTarget(name: "fixture-check", dependencies: ["FixtureCheckKit"]),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore", "FixtureCheckKit"]),
    ],
    swiftLanguageModes: [.v6]
)
