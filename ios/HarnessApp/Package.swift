// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HarnessRuntime",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HarnessRuntime", targets: ["HarnessRuntime"]),
        .library(name: "NativeWorkspace", targets: ["NativeWorkspace"]),
        .library(name: "LinuxPlugin", targets: ["LinuxPlugin"]),
        .library(name: "ModelGateway", targets: ["ModelGateway"]),
        .library(name: "UserDataMigration", targets: ["UserDataMigration"]),
        .library(name: "NativeTools", targets: ["NativeTools"])
    ],
    targets: [
        .target(name: "HarnessRuntime", path: "Sources/Core"),
        .testTarget(name: "HarnessRuntimeTests", dependencies: ["HarnessRuntime"], path: "Tests"),
        .target(name: "NativeWorkspace", path: "Sources/Workspace"),
        .executableTarget(name: "workspace-crash-probe", dependencies: ["NativeWorkspace"], path: "Tools/WorkspaceCrashProbe"),
        .testTarget(name: "NativeWorkspaceTests", dependencies: ["NativeWorkspace", "workspace-crash-probe"],
                    path: "WorkspaceTests"),
        .target(name: "LinuxPlugin", path: "Sources/LinuxPlugin"),
        .testTarget(name: "LinuxPluginTests", dependencies: ["LinuxPlugin"], path: "LinuxPluginTests"),
        .target(name: "ModelGateway", path: "Sources/ModelGateway"),
        .testTarget(name: "ModelGatewayTests", dependencies: ["ModelGateway"], path: "ModelGatewayTests"),
        .target(name: "UserDataMigration", path: "Sources/Migration"),
        .executableTarget(name: "migration-crash-probe", dependencies: ["UserDataMigration"], path: "Tools/MigrationCrashProbe"),
        .testTarget(name: "UserDataMigrationTests", dependencies: ["UserDataMigration", "migration-crash-probe"],
                    path: "MigrationTests"),
        .target(name: "NativeTools", dependencies: ["NativeWorkspace"], path: "Sources/NativeTools"),
        .executableTarget(name: "native-tools-probe", dependencies: ["NativeTools"], path: "Tools/NativeToolsProbe"),
        .testTarget(name: "NativeToolsTests", dependencies: ["NativeTools"], path: "NativeToolsTests")
    ]
)
