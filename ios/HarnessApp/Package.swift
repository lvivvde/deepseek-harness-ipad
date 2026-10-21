// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeepSeekHarness",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "NativeWorkspace", targets: ["NativeWorkspace"]),
        .library(name: "LinuxPlugin", targets: ["LinuxPlugin"]),
        .library(name: "ModelGateway", targets: ["ModelGateway"]),
        .library(name: "NativeTools", targets: ["NativeTools"]),
        .library(name: "HarnessHost", targets: ["HarnessHost"]),
        .library(name: "HarnessCore", targets: ["HarnessCore"])
    ],
    targets: [
        .target(name: "NativeWorkspace", path: "Sources/Workspace"),
        .executableTarget(name: "workspace-crash-probe", dependencies: ["NativeWorkspace"], path: "Tools/WorkspaceCrashProbe"),
        .testTarget(name: "NativeWorkspaceTests", dependencies: ["NativeWorkspace", "workspace-crash-probe"],
                    path: "WorkspaceTests"),
        .target(name: "LinuxPlugin", path: "Sources/LinuxPlugin"),
        .testTarget(name: "LinuxPluginTests", dependencies: ["LinuxPlugin"], path: "LinuxPluginTests"),
        .target(name: "ModelGateway", path: "Sources/ModelGateway"),
        .testTarget(name: "ModelGatewayTests", dependencies: ["ModelGateway"], path: "ModelGatewayTests"),
        .target(name: "NativeTools", dependencies: ["NativeWorkspace"], path: "Sources/NativeTools"),
        .executableTarget(name: "native-tools-probe", dependencies: ["NativeTools"], path: "Tools/NativeToolsProbe"),
        .testTarget(name: "NativeToolsTests", dependencies: ["NativeTools"], path: "NativeToolsTests"),
        .target(name: "HarnessHost", dependencies: ["NativeWorkspace", "LinuxPlugin"], path: "Sources/Host"),
        .testTarget(name: "HarnessHostTests", dependencies: ["HarnessHost", "NativeWorkspace", "LinuxPlugin"], path: "HostTests"),
        .target(name: "HarnessCore", dependencies: ["HarnessHost", "NativeWorkspace", "NativeTools", "LinuxPlugin", "ModelGateway"],
                path: "Sources/Core"),
        .executableTarget(name: "home-recovery-probe", dependencies: ["HarnessCore", "NativeWorkspace"], path: "Tools/HomeRecoveryProbe"),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore", "HarnessHost", "LinuxPlugin"], path: "CoreTests")
    ]
)
