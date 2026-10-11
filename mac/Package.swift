// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PerchMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PerchMac", targets: ["PerchMac"])],
    targets: [
        .target(name: "PerchSupport"),
        .executableTarget(name: "PerchMac", dependencies: ["PerchSupport"]),
        .testTarget(name: "PerchSupportTests", dependencies: ["PerchSupport"])
    ]
)
