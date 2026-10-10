import Darwin
import Foundation
import HarnessHost

/// The iPad VM: the QEMU library loaded into this process and run once on its own thread with
/// `GuestArguments`. The serial console and a QMP control channel are socket pairs, so nothing listens
/// on a path or port besides the agent's forward. `stop` asks QMP to quit, which ends QEMU's main loop;
/// a library-loaded QEMU cannot be restarted, so the machine never boots twice.
public final class EmbeddedMachine: GuestMachine, @unchecked Sendable {
    /// Runs QEMU with these arguments (`argv[0]` first) and returns its status once it has ended.
    public typealias Engine = ([String]) -> Int32

    public struct Configuration {
        /// `Image`, `initramfs.gz` and `system.raw`.
        public let inputs: String
        /// QEMU's data directory (`-L`).
        public let firmware: String
        public let token: String
        public let logs: String
        public init(inputs: String, firmware: String, token: String, logs: String) {
            self.inputs = inputs; self.firmware = firmware; self.token = token; self.logs = logs
        }
    }

    public let rpc: GuestRPC
    public var onExit: ((Int32?) -> Void)?
    private let configuration: Configuration
    private let engine: Engine
    private let port: UInt16
    private let lock = NSLock()
    private var started = false
    private var ended = false
    private var quitting = false
    /// This side of the QMP socket pair, while QEMU runs.
    private var control: Int32 = -1

    public init(_ configuration: Configuration, engine: @escaping Engine) throws {
        self.configuration = configuration; self.engine = engine
        port = try GuestArguments.freePort()
        rpc = GatedGuestRPC(port: port, token: configuration.token)
    }

    public var exited: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    public func boot(workspace: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { throw CandidateError("VM_ALREADY_STARTED") }
        try FileManager.default.createDirectory(atPath: configuration.logs, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let serial = Self.socketPair() else { throw CandidateError("VM_START_FAILED") }
        guard let qmp = Self.socketPair() else {
            close(serial.0); close(serial.1)
            throw CandidateError("VM_START_FAILED")
        }
        started = true
        control = qmp.0
        let drains = DispatchGroup()
        Self.drain(serial.0, to: configuration.logs + "/serial-private.log", drains)
        Self.drain(qmp.0, to: configuration.logs + "/qmp-private.log", drains)
        let arguments = ["qemu-aarch64-softmmu", "-L", configuration.firmware]
            + GuestArguments.machine(inputs: configuration.inputs, workspace: workspace, port: port,
                                     serial: "socket,id=serial,fd=\(serial.1)")
            + ["-chardev", "socket,id=qmp,fd=\(qmp.1)", "-mon", "chardev=qmp,mode=control"]
        let thread = Thread { [self] in
            let status = engine(arguments)
            lock.lock(); ended = true; control = -1; lock.unlock()
            // QEMU no longer writes (or never started): end the drains, then close this side of both pairs.
            shutdown(serial.0, SHUT_RDWR); shutdown(qmp.0, SHUT_RDWR)
            drains.wait()
            close(serial.0); close(qmp.0)
            onExit?(status)
        }
        thread.name = "candidate.qemu"
        thread.stackSize = 8 << 20
        thread.start()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started, !ended, !quitting else { return }
        quitting = true
        let request = #"{"execute":"qmp_capabilities"}"# + "\n" + #"{"execute":"quit"}"# + "\n"
        _ = request.withCString { write(control, $0, strlen($0)) }
    }

    /// Copies one socket's output to a private log until it ends. The machine closes the socket afterwards.
    private static func drain(_ fd: Int32, to path: String, _ group: DispatchGroup) {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = FileHandle(forWritingAtPath: path)
        group.enter()
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                try? log?.write(contentsOf: Data(buffer[..<count]))
            }
            try? log?.close()
            group.leave()
        }
        thread.start()
    }

    private static func socketPair() -> (Int32, Int32)? {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }
        var enabled: Int32 = 1
        for fd in descriptors { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) }
        return (descriptors[0], descriptors[1])
    }

    // MARK: The QEMU library

    private static let once = NSLock()
    private static var loaded = false

    private typealias Initialize = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                                   UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias Step = @convention(c) () -> Void

    /// The engine for the bundled `qemu-aarch64-softmmu` framework: `qemu_init`, `qemu_main_loop`,
    /// `qemu_cleanup`. Its global state cannot be reset, so only the first call in a process runs QEMU;
    /// later calls return -3. -1: the library did not load; -2: a symbol is missing.
    public static func library(at path: String) -> Engine {
        { arguments in
            once.lock()
            let first = !loaded
            loaded = true
            once.unlock()
            guard first else { return -3 }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return -1 }
            guard let initialize = dlsym(handle, "qemu_init"), let mainLoop = dlsym(handle, "qemu_main_loop"),
                  let cleanup = dlsym(handle, "qemu_cleanup") else { dlclose(handle); return -2 }
            var argv = arguments.map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = [nil]
            defer { argv.forEach { free($0) } }
            let status = unsafeBitCast(initialize, to: Initialize.self)(Int32(arguments.count), &argv, &envp)
            if status == 0 {
                unsafeBitCast(mainLoop, to: Step.self)()
                unsafeBitCast(cleanup, to: Step.self)()
            }
            // The library stays loaded: cleanup does not make its global state restartable.
            return status
        }
    }
}
