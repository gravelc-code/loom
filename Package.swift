// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "loom",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LoomCore"),
        .executableTarget(
            name: "LoomApp",
            dependencies: ["LoomCore"]
        ),
        .testTarget(name: "LoomCoreTests", dependencies: ["LoomCore"]),
    ]
)
