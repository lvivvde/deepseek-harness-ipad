#if os(macOS)
import Darwin
import Foundation
import HarnessHost

/// The macOS vertical slice's VM: Homebrew `qemu-system-aarch64` under TCG, booted once with the
/// project's workspace as its 9P share (`security_model=none`) and the guest agent forwarded to a
/// loopback port. Serial and QEMU output go only to `logs`, a private directory.
public final class QemuMachine: GuestMachine, @unchecked Sendable {
    public struct Configuration {
        public let executable: String
        /// `Image`, `initramfs.gz` and `system.raw`.
        public let inputs: String
        public let token: String
        public let logs: String
        public init(executable: String = "/opt/homebrew/bin/qemu-system-aarch64", inputs: String, token: String, logs: String) {
            self.executable = executable; self.inputs = inputs; self.token = token; self.logs = logs
        }
    }

    public let rpc: GuestRPC
    public var onExit: ((Int32?) -> Void)?
    private let configuration: Configuration
    private let port: UInt16
    private let lock = NSLock()
    private var process: Process?
    private var ended = false

    public init(_ configuration: Configuration) throws {
        self.configuration = configuration
        port = try Self.freePort()
        rpc = GatedGuestRPC(port: port, token: configuration.token)
    }

    public var exited: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    public func boot(workspace: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard process == nil, !ended else { throw CandidateError("VM_ALREADY_STARTED") }
        try FileManager.default.createDirectory(atPath: configuration.logs, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let inputs = configuration.inputs
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = [
            "-machine", "virt", "-cpu", "cortex-a72", "-smp", "1", "-m", "1024", "-accel", "tcg",
            "-nodefaults", "-display", "none", "-monitor", "none",
            "-chardev", "file,id=serial,path=" + Self.option(configuration.logs + "/serial-private.log"), "-serial", "chardev:serial",
            "-kernel", inputs + "/Image", "-initrd", inputs + "/initramfs.gz", "-append", "console=ttyAMA0 rdinit=/init",
            "-drive", "file=" + Self.option(inputs + "/system.raw") + ",if=none,id=system,format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=system",
            "-netdev", "user,id=net,restrict=on,hostfwd=tcp:127.0.0.1:\(port)-:4500", "-device", "virtio-net-pci,netdev=net,romfile=",
            "-fsdev", "local,id=workspace,path=" + Self.option(workspace) + ",security_model=none,writeout=immediate",
            "-device", "virtio-9p-pci,fsdev=workspace,mount_tag=workspace",
        ]
        let log = configuration.logs + "/qemu-private.log"
        FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: log)
        process.terminationHandler = { [weak self] finished in self?.finished(finished.terminationStatus) }
        try process.run()
        self.process = process
    }

    public func stop() {
        lock.lock(); let running = ended ? nil : process; lock.unlock()
        guard let running else { return }
        running.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func finished(_ status: Int32) {
        lock.lock(); let first = !ended; ended = true; lock.unlock()
        if first { onExit?(status) }
    }

    /// QEMU option values split on commas; a literal comma is doubled.
    static func option(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CandidateError("PORT_UNAVAILABLE") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else { throw CandidateError("PORT_UNAVAILABLE") }
        return UInt16(bigEndian: address.sin_port)
    }
}
#endif
