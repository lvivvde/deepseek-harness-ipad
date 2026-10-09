import Darwin
import Foundation

/// Whether this process can run the Linux compatibility plugin at all. Decided once at App start,
/// before any Linux preparation. The Darwin 9P backend of the bundled QEMU weak-links the private
/// `pthread_fchdir_np` (see docs/research/plan500-darwin.md); without it the plugin is unavailable.
public enum LinuxAvailability: Equatable, Sendable {
    public enum Reason: String, Sendable { case privateSymbolMissing = "LINUX_PRIVATE_SYMBOL_MISSING" }

    case available
    case unavailable(Reason)

    public static let privateSymbol = "pthread_fchdir_np"

    /// Production passes no resolver. The resolver parameter is the test seam; formal builds have no
    /// switch that forces the missing branch.
    public static func detect(_ resolves: (String) -> Bool = symbolResolves) -> LinuxAvailability {
        resolves(privateSymbol) ? .available : .unavailable(.privateSymbolMissing)
    }

    /// Looks the symbol up in the already-loaded images (RTLD_DEFAULT), which is what a weak import
    /// in the QEMU framework binds against.
    public static func symbolResolves(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }
}

/// Process-wide Linux plugin lifecycle and task admission. One instance per App process: QEMU is
/// started at most once, and a failure is not retried inside the same process (ADR 0003).
public final class LinuxPlugin: @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        case cold, preparing, ready, failed
        case unavailable(LinuxAvailability.Reason)
    }

    public enum ExecutionPath: String, Codable, Sendable { case native, linux, unsupported }

    /// Execution path is chosen from the task before it starts and never changes afterwards.
    public enum Task: Equatable, Sendable {
        case native(String)
        case shell(String)
        /// Command hooks run through the shell capability, so they need Linux.
        case hook(String)

        public var path: ExecutionPath {
            switch self {
            case .native: return .native
            case .shell, .hook: return .linux
            }
        }
    }

    public enum Admission: Equatable, Sendable {
        case native
        case linux
        case cancelledBeforeDispatch
        /// Explicit, immediate refusal with a fixed code; never a wait.
        case refused(String)
    }

    public static let notEnabledCode = "LINUX_PLUGIN_NOT_ENABLED"
    public static let prepareFailedCode = "LINUX_PREPARE_FAILED"

    public let availability: LinuxAvailability
    private let launcher: () throws -> Void
    private let queue: DispatchQueue
    private let condition = NSCondition()
    private var current: Phase

    public init(availability: LinuxAvailability, queue: DispatchQueue = .global(qos: .userInitiated),
                launcher: @escaping () throws -> Void) {
        self.availability = availability
        self.launcher = launcher
        self.queue = queue
        if case .unavailable(let reason) = availability { current = .unavailable(reason) } else { current = .cold }
    }

    public var phase: Phase { condition.lock(); defer { condition.unlock() }; return current }

    /// Opening a project never waits for Linux; a plugin-enabled project starts preparation.
    @discardableResult
    public func open(pluginEnabled: Bool) -> Phase { pluginEnabled ? prepare() : phase }

    /// Starts preparation once. Unavailable, preparing, ready and failed are all left unchanged.
    @discardableResult
    public func prepare() -> Phase {
        condition.lock()
        guard current == .cold else { defer { condition.unlock() }; return current }
        current = .preparing
        condition.unlock()
        queue.async { [self] in
            let next: Phase
            do { try launcher(); next = .ready } catch { next = .failed }
            condition.lock(); current = next; condition.broadcast(); condition.unlock()
        }
        return .preparing
    }

    /// Wakes waiting admissions so they can re-check their cancellation.
    public func wake() { condition.lock(); condition.broadcast(); condition.unlock() }

    /// Decides where a task may run. Linux tasks of an enabled project wait for real ready, start
    /// preparation if needed, and are refused at once when the plugin cannot run.
    public func admit(_ task: Task, pluginEnabled: Bool, isCancelled: () -> Bool) -> Admission {
        guard task.path == .linux else { return .native }
        guard pluginEnabled else { return .refused(Self.notEnabledCode) }
        prepare()
        condition.lock(); defer { condition.unlock() }
        while true {
            if isCancelled() { return .cancelledBeforeDispatch }
            switch current {
            case .ready: return .linux
            case .failed: return .refused(Self.prepareFailedCode)
            case .unavailable(let reason): return .refused(reason.rawValue)
            case .cold, .preparing: condition.wait()
            }
        }
    }

    public func declaration(pluginEnabled: Bool) -> CapabilityDeclaration {
        CapabilityDeclaration(phase: phase, pluginEnabled: pluginEnabled)
    }
}

/// Per-item record of where each capability runs (`native`, `linux`, `unsupported`) and whether it
/// is usable now, with a fixed reason when it is not.
public struct CapabilityDeclaration: Codable, Equatable, Sendable {
    public struct Plugin: Codable, Equatable, Sendable {
        public let enabled: Bool
        public let state: String
        public let reason: String?
        public let requiredPrivateSymbol: String
    }

    public struct Item: Codable, Equatable, Sendable {
        public let name: String
        public let path: LinuxPlugin.ExecutionPath
        public let available: Bool
        public let reason: String?
    }

    public let plugin: Plugin
    public let items: [Item]

    /// First formal scope. `none` 9P cannot place FIFOs or Unix sockets in the shared workspace.
    public static let scope: [(String, LinuxPlugin.ExecutionPath)] = [
        ("session", .native), ("fs.read", .native), ("fs.write", .native), ("fs.edit", .native),
        ("fs.search", .native), ("git.read", .native), ("review", .native), ("drafts", .native),
        ("shell", .linux), ("subprocess", .linux), ("hook.command", .linux),
        ("workspace.fifo", .unsupported), ("workspace.unix-socket", .unsupported),
    ]

    public init(phase: LinuxPlugin.Phase, pluginEnabled: Bool) {
        let state: String, reason: String?
        switch (phase, pluginEnabled) {
        case (.unavailable(let why), _): state = "UNAVAILABLE"; reason = why.rawValue
        case (_, false): state = "NOT_ENABLED"; reason = LinuxPlugin.notEnabledCode
        case (.cold, true): state = "COLD"; reason = nil
        case (.preparing, true): state = "PREPARING"; reason = nil
        case (.ready, true): state = "READY"; reason = nil
        case (.failed, true): state = "FAILED"; reason = LinuxPlugin.prepareFailedCode
        }
        plugin = Plugin(enabled: pluginEnabled, state: state, reason: reason,
                        requiredPrivateSymbol: LinuxAvailability.privateSymbol)
        // Cold or preparing Linux items are still usable: their tasks wait for ready.
        let linuxUsable = state == "COLD" || state == "PREPARING" || state == "READY"
        items = Self.scope.map { name, path in
            switch path {
            case .native: return Item(name: name, path: path, available: true, reason: nil)
            case .linux: return Item(name: name, path: path, available: linuxUsable, reason: linuxUsable ? nil : reason)
            case .unsupported: return Item(name: name, path: path, available: false, reason: "SHARE_MODE_NONE")
            }
        }
    }
}
