// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AwakeCore"),
        .executableTarget(name: "Awake", dependencies: ["AwakeCore"]),
        .testTarget(name: "AwakeCoreTests", dependencies: ["AwakeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
