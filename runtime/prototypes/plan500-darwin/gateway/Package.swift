// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Plan500Gateway",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "Plan500Gateway", targets: ["Plan500Gateway"])],
    targets: [
        .target(name: "Plan500Gateway"),
        .executableTarget(name: "plan500-gateway", dependencies: ["Plan500Gateway"]),
        .testTarget(name: "Plan500GatewayTests", dependencies: ["Plan500Gateway"])
    ]
)
