// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DriveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DriveCore", targets: ["DriveCore"]),
    ],
    targets: [
        .target(name: "DriveCore"),
        .testTarget(name: "DriveCoreTests", dependencies: ["DriveCore"]),
    ],
    swiftLanguageModes: [.v6]
)
