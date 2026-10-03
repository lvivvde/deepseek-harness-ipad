// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HarnessRuntime",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "HarnessRuntime", targets: ["HarnessRuntime"])],
    targets: [
        .target(name: "HarnessRuntime", path: "Sources/Core"),
        .testTarget(name: "HarnessRuntimeTests", dependencies: ["HarnessRuntime"], path: "Tests")
    ]
)
