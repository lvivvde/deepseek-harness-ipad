import Foundation
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
        XCTAssertEqual(try userData.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
