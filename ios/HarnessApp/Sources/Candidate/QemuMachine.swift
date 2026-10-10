#if os(macOS)
import Darwin
import Foundation
import HarnessHost

/// The macOS VM: Homebrew `qemu-system-aarch64` as a child process, booted once with `GuestArguments`.
/// Serial and QEMU output go only to `logs`, a private directory.
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
        port = try GuestArguments.freePort()
        rpc = GatedGuestRPC(port: port, token: configuration.token)
    }

    public var exited: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    public func boot(workspace: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard process == nil, !ended else { throw CandidateError("VM_ALREADY_STARTED") }
        try FileManager.default.createDirectory(atPath: configuration.logs, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = GuestArguments.machine(
            inputs: configuration.inputs, workspace: workspace, port: port,
            serial: "file,id=serial,path=" + GuestArguments.option(configuration.logs + "/serial-private.log"))
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
}
#endif
