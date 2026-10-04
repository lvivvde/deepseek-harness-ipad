import Foundation
#if os(macOS)
import Darwin
#endif
import XCTest
@testable import HarnessRuntime

final class RuntimeConfigurationTests: XCTestCase {
    func testPreparingAnInstalledRuntimeNeverOverwritesExistingUserDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("Runtime")
        let userData = directory.appendingPathComponent("UserData")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        let manifest = """
        {"formatVersion":1,"kernel":"Image","initramfs":"initramfs.gz",
         "systemDisk":"system.raw","userDiskSeed":"user-seed.raw","memoryMiB":2048}
        """
        try Data(manifest.utf8).write(to: resources.appendingPathComponent("runtime.json"))
        for name in ["Image", "initramfs.gz", "system.raw", "user-seed.raw"] {
            try Data("bundled-seed".utf8).write(to: resources.appendingPathComponent(name))
        }
        let userDisk = userData.appendingPathComponent("user.raw")
        try Data("existing-project-and-credentials".utf8).write(to: userDisk)

        let configuration = try RuntimeConfiguration.prepare(resources: resources, userData: userData)

        XCTAssertEqual(configuration.userDisk, userDisk)
        XCTAssertEqual(try Data(contentsOf: userDisk), Data("existing-project-and-credentials".utf8))
    }

    func testConnectedControlChannelsAndLoopbackOnlyPreviewForwards() {
        let file = URL(fileURLWithPath: "/tmp/test.raw")
        let runtime = RuntimeConfiguration(kernel: file, initramfs: file, systemDisk: file, userDisk: file, memoryMiB: 2048)
        let arguments = runtime.qemuArguments(firmwareDirectory: file, transferToken: "test", serialFD: 10, controlFD: 11)
        XCTAssertTrue(arguments.contains("socket,id=serial0,fd=10"))
        XCTAssertTrue(arguments.contains("socket,id=control0,fd=11"))
        let network = arguments[arguments.firstIndex(of: "-netdev")! + 1]
        XCTAssertTrue(network.contains("hostfwd=tcp:127.0.0.1:28080-:2999"))
        XCTAssertTrue(network.contains("hostfwd=tcp:127.0.0.1:5173-:40002"))
        XCTAssertFalse(network.contains("hostfwd=tcp:0.0.0.0"))
        XCTAssertFalse(PreviewServer.accepts(port: 28080))
        XCTAssertTrue(PreviewServer.accepts(port: 5173))
    }

    func testUserDiskCapacityRejectsShrinkingAndProtectsHostFreeSpace() throws {
        let normal = UserDiskStatus(capacityBytes: 16 << 30, allocatedBytes: 1 << 30, hostAvailableBytes: 2 << 30)
        XCTAssertEqual(try normal.growthBytes(toGiB: 64), 68_719_476_736)
        XCTAssertEqual(try normal.growthBytes(toGiB: 16), 17_179_869_184, "Allow completing a previously interrupted growth")
        XCTAssertThrowsError(try normal.growthBytes(toGiB: 8)) { XCTAssertEqual($0 as? UserDiskError, .shrinkUnsupported) }
        XCTAssertThrowsError(try normal.growthBytes(toGiB: 65)) { XCTAssertEqual($0 as? UserDiskError, .invalidSize) }
        let low = UserDiskStatus(capacityBytes: 8 << 30, allocatedBytes: 1 << 30, hostAvailableBytes: 2_147_483_647)
        XCTAssertTrue(low.isHostSpaceLow)
        XCTAssertThrowsError(try low.growthBytes(toGiB: 16)) { XCTAssertEqual($0 as? UserDiskError, .lowSpace) }
    }

    func testUserDiskGrowsSparselyAndIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("Runtime")
        let userData = directory.appendingPathComponent("UserData")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let manifest = """
        {"formatVersion":1,"kernel":"Image","initramfs":"initramfs.gz",
         "systemDisk":"system.raw","userDiskSeed":"user-seed.raw","memoryMiB":2048,"userDiskMiB":8192}
        """
        try Data(manifest.utf8).write(to: resources.appendingPathComponent("runtime.json"))
        for name in ["Image", "initramfs.gz", "system.raw", "user-seed.raw"] {
            try Data("bundled-seed".utf8).write(to: resources.appendingPathComponent(name))
        }

        let disk = try RuntimeConfiguration.prepare(resources: resources, userData: userData).userDisk
        _ = try RuntimeConfiguration.prepare(resources: resources, userData: userData)

        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        XCTAssertEqual(try handle.read(upToCount: 12), Data("bundled-seed".utf8))
        XCTAssertEqual(try handle.seekToEnd(), 8192 * 1024 * 1024)
        let allocated = try disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? .max
        XCTAssertLessThan(allocated, 64 * 1024 * 1024)
        let status = try UserDiskStatus.read(disk: disk)
        XCTAssertEqual(status.capacityBytes, 8 << 30)
        XCTAssertLessThan(status.allocatedBytes, 64 << 20)
        XCTAssertGreaterThan(status.hostAvailableBytes, 0)
        #if os(macOS)
        XCTAssertEqual(truncate(disk.path, 17_179_869_184), 0)
        XCTAssertEqual(try UserDiskStatus.read(disk: disk).capacityBytes, 17_179_869_184, "Settings must observe growth performed by QEMU, not a cached size")
        #endif
        #if os(macOS)
        // macOS can return false for this URL key despite writing its real backup exclusion attribute.
        XCTAssertGreaterThan(getxattr(userData.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0), 0)
        #else
        XCTAssertEqual(try userData.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #endif
    }
}
