import Foundation

struct RuntimeConfiguration: Sendable {
    let kernel: URL
    let initramfs: URL
    let systemDisk: URL
    let userDisk: URL
    let memoryMiB: Int

    private struct Manifest: Decodable {
        let formatVersion: Int
        let kernel: String
        let initramfs: String
        let systemDisk: String
        let userDiskSeed: String
        let memoryMiB: Int
        let userDiskMiB: Int?
    }

    static func prepare(resources: URL, userData: URL) throws -> RuntimeConfiguration {
        let manager = FileManager.default
        let manifestURL = resources.appendingPathComponent("runtime.json")
        guard manager.fileExists(atPath: manifestURL.path) else { throw RuntimeConfigurationError.missingRuntime }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw RuntimeConfigurationError.invalidResource }
        guard manifest.formatVersion == 1 else { throw RuntimeConfigurationError.incompatibleRuntime }
        guard (128...2048).contains(manifest.memoryMiB) else { throw RuntimeConfigurationError.invalidResource }
        if let size = manifest.userDiskMiB, !(512...65536).contains(size) { throw RuntimeConfigurationError.invalidResource }
        func resource(_ name: String) throws -> URL {
            guard !name.isEmpty, name != ".", name != "..",
                  name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                throw RuntimeConfigurationError.invalidResource
            }
            let url = resources.appendingPathComponent(name)
            guard isRegularFile(url) else { throw RuntimeConfigurationError.missingResource }
            return url
        }
        let kernel = try resource(manifest.kernel)
        let initramfs = try resource(manifest.initramfs)
        let systemDisk = try resource(manifest.systemDisk)
        let seed = try resource(manifest.userDiskSeed)
        let disk = userData.appendingPathComponent("user.raw")
        do {
            try manager.createDirectory(at: userData, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: disk.path) {
                let temporary = userData.appendingPathComponent("seed-\(UUID().uuidString).tmp")
                defer { try? manager.removeItem(at: temporary) }
                try manager.copyItem(at: seed, to: temporary)
                // moveItem refuses to replace an existing destination, including a race.
                try manager.moveItem(at: temporary, to: disk)
            }
            guard isRegularFile(disk) else { throw RuntimeConfigurationError.userDiskUnavailable }
            // Credentials and projects stay on this device; backups go through explicit export only.
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var directory = userData
            try directory.setResourceValues(excluded)
            if let size = manifest.userDiskMiB { try grow(disk, toMiB: size) }
        } catch { throw RuntimeConfigurationError.userDiskUnavailable }
        return RuntimeConfiguration(kernel: kernel, initramfs: initramfs, systemDisk: systemDisk,
                                    userDisk: disk, memoryMiB: manifest.memoryMiB)
    }

    /// Extends the file as a sparse tail; the guest grows ext4 online. Never shrinks or rewrites data.
    private static func grow(_ disk: URL, toMiB size: Int) throws {
        let target = UInt64(size) * 1024 * 1024
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        if try handle.seekToEnd() < target { try handle.truncate(atOffset: target) }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular &&
            (attributes?[.size] as? NSNumber)?.uint64Value ?? 0 > 0
    }

    func qemuArguments(firmwareDirectory: URL, transferToken: String = ProjectTransfer.sessionToken,
                       serialFD: Int? = nil, controlFD: Int? = nil) -> [String] {
        // QEMU -drive parses commas, including commas in containing directory names.
        func drivePath(_ url: URL) -> String { url.path.replacingOccurrences(of: ",", with: ",,") }
        let serial = serialFD.map { "socket,id=serial0,fd=\($0)" } ??
            "socket,id=serial0,host=127.0.0.1,port=\(RuntimePorts.serial),server=on,wait=off"
        let control = controlFD.map { ["-chardev", "socket,id=control0,fd=\($0)", "-qmp", "chardev:control0"] } ??
            ["-qmp", "tcp:127.0.0.1:\(RuntimePorts.control),server=on,wait=off"]
        let forwards = ["hostfwd=tcp:127.0.0.1:\(RuntimePorts.page)-:2999",
                        "hostfwd=tcp:127.0.0.1:\(RuntimePorts.transfer)-:3002",
                        "hostfwd=tcp:127.0.0.1:\(RuntimePorts.previewCatalog)-:3003"] +
            RuntimePorts.previewFallback.enumerated().map { "hostfwd=tcp:127.0.0.1:\($0.element)-:\(40000 + $0.offset)" }
        return ["qemu-aarch64-softmmu", "-L", firmwareDirectory.path,
                "-machine", "virt", "-cpu", "cortex-a72", "-smp", "1", "-m", String(memoryMiB),
                "-accel", "tcg", "-nodefaults", "-display", "none", "-monitor", "none",
                "-chardev", serial, "-serial", "chardev:serial0"] + control + [
                "-netdev", "user,id=net0," + forwards.joined(separator: ","),
                "-device", "virtio-net-pci,netdev=net0", "-kernel", kernel.path,
                "-initrd", initramfs.path, "-append", "console=ttyAMA0 rdinit=/init harness.transfer=\(transferToken)",
                "-drive", "file=\(drivePath(systemDisk)),if=none,id=system,format=raw,readonly=on",
                "-device", "virtio-blk-pci,drive=system",
                "-drive", "file=\(drivePath(userDisk)),if=none,id=user,format=raw",
                "-device", "virtio-blk-pci,drive=user"]
    }
}

enum RuntimeConfigurationError: Error, LocalizedError {
    case missingRuntime
    case incompatibleRuntime
    case invalidResource
    case missingResource
    case userDiskUnavailable

    var errorDescription: String? {
        switch self {
        case .missingRuntime: return "此构建尚未包含运行时，请安装包含运行时的版本"
        case .incompatibleRuntime: return "运行时格式不兼容，请安装匹配的应用版本"
        case .invalidResource: return "运行时资源配置无效，请重新安装应用"
        case .missingResource: return "运行时资源不完整，请重新安装应用"
        case .userDiskUnavailable: return "无法准备用户数据盘；原有数据未被重置"
        }
    }
}
