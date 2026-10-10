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

/// Linux plugin lifecycle and task admission, per project. One instance per App process: QEMU is
/// started at most once, and a failure is not retried inside the same process (ADR 0003). The guest
/// mounts exactly one project, so Linux binds to the first plugin-enabled project opened; another
/// plugin project in the same process is unavailable until the App is closed and reopened.
public final class LinuxPlugin: @unchecked Sendable {
    /// `disabled → preparing → ready | failed | unavailable`, with a fixed reason code where it applies.
    public enum Phase: Equatable, Sendable {
        case disabled, preparing, ready
        case failed(String)
        case unavailable(String)
    }

    public enum ExecutionPath: String, Codable, Sendable { case native, linux, unsupported }

    /// Execution path is chosen from the task before it starts and never changes afterwards.
    public enum Task: Equatable, Sendable {
        case native(String)
        case shell(String)
        /// Command hooks run through the shell capability, so they need Linux.
        case hook(String)
        /// A repository-changing Git operation and the hooks it runs (#39 gate 5). Git reads stay native.
        case git(String)
        /// An interactive terminal session: a pty in the guest that holds the write lease only while a
        /// command runs in it.
        case terminal(String)

        public var path: ExecutionPath {
            switch self {
            case .native: return .native
            case .shell, .hook, .git, .terminal: return .linux
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
    public static let boundToOtherProjectCode = "LINUX_BOUND_TO_OTHER_PROJECT"
    public static let vmExitedCode = "LINUX_VM_EXITED"

    /// A launcher error with a fixed code, recorded as the failure's cause. Any other error is recorded
    /// as `LAUNCH_ERROR`, so no free text from the guest or QEMU reaches the diagnostics.
    public struct LaunchFailure: Error, Equatable, Sendable {
        public let code: String
        public init(_ code: String) { self.code = code }
    }

    /// Fixed-field record saved when Linux fails, before the failure is published. The user is then
    /// asked to close and reopen the App; Linux never restarts inside the process.
    public struct Diagnostic: Codable, Equatable, Sendable {
        public let code: String
        public let project: String
        /// Phase of the guest when it failed: `PREPARING` or `READY`.
        public let stage: String
        public let status: Int32?
        public let cause: String?

        public init(code: String, project: String, stage: String, status: Int32? = nil, cause: String? = nil) {
            self.code = code; self.project = project; self.stage = stage; self.status = status; self.cause = cause
        }
    }

    public let availability: LinuxAvailability
    private let launcher: (String) throws -> Void
    private let diagnostics: (Diagnostic) -> Void
    private let queue: DispatchQueue
    private let condition = NSCondition()
    /// Serializes failures, so only the first is saved and published.
    private let failing = NSLock()
    private var enabled: [String: Bool] = [:]
    private var bound: String?
    /// Phase of the bound project's guest; meaningless while `bound` is nil.
    private var guest: Phase = .disabled

    /// `launcher` boots the guest for the given project and returns only after its verified ready proof.
    /// `diagnostics` must save the record durably before returning; it is called without any plugin lock.
    public init(availability: LinuxAvailability, queue: DispatchQueue = .global(qos: .userInitiated),
                launcher: @escaping (String) throws -> Void, diagnostics: @escaping (Diagnostic) -> Void = { _ in }) {
        self.availability = availability
        self.launcher = launcher
        self.diagnostics = diagnostics
        self.queue = queue
    }

    /// The project Linux is bound to in this process, if any.
    public var boundProject: String? { condition.lock(); defer { condition.unlock() }; return bound }

    public func phase(of project: String) -> Phase {
        condition.lock(); defer { condition.unlock() }; return phaseLocked(project)
    }

    private func phaseLocked(_ project: String) -> Phase {
        guard enabled[project] == true else { return .disabled }
        if case .unavailable(let reason) = availability { return .unavailable(reason.rawValue) }
        guard let bound else { return .disabled }
        return bound == project ? guest : .unavailable(Self.boundToOtherProjectCode)
    }

    /// Opening a project never waits for Linux. The first plugin-enabled project binds Linux and starts
    /// its preparation; reopening never prepares again.
    @discardableResult
    public func open(project: String, pluginEnabled: Bool) -> Phase {
        condition.lock()
        enabled[project] = pluginEnabled
        guard pluginEnabled, availability == .available, bound == nil else {
            defer { condition.unlock() }; return phaseLocked(project)
        }
        bound = project; guest = .preparing
        condition.unlock()
        queue.async { [self] in
            do {
                try launcher(project)
                condition.lock(); if guest == .preparing { guest = .ready }; condition.broadcast(); condition.unlock()
            } catch {
                let cause = (error as? LaunchFailure)?.code ?? "LAUNCH_ERROR"
                fail(Diagnostic(code: Self.prepareFailedCode, project: project, stage: "PREPARING", cause: cause))
            }
        }
        return .preparing
    }

    /// The bound guest's QEMU exited. Ignored before any launch and after an earlier failure.
    public func vmExited(status: Int32?) {
        condition.lock()
        let stage: String
        switch guest {
        case .preparing: stage = "PREPARING"
        case .ready: stage = "READY"
        default: condition.unlock(); return
        }
        let project = bound ?? ""
        condition.unlock()
        fail(Diagnostic(code: Self.vmExitedCode, project: project, stage: stage, status: status))
    }

    /// Saves the record, then publishes the failure once. The first failure of the guest wins.
    private func fail(_ record: Diagnostic) {
        failing.lock(); defer { failing.unlock() }
        condition.lock(); let live = guest == .preparing || guest == .ready; condition.unlock()
        guard live else { return }
        diagnostics(record)
        condition.lock(); guest = .failed(record.code); condition.broadcast(); condition.unlock()
    }

    /// Wakes waiting admissions so they can re-check their cancellation.
    public func wake() { condition.lock(); condition.broadcast(); condition.unlock() }

    /// Decides where a task may run. A Linux task waits only for its own project's preparation, and is
    /// refused at once when that project cannot run Linux.
    public func admit(_ task: Task, project: String, isCancelled: () -> Bool) -> Admission {
        guard task.path == .linux else { return .native }
        condition.lock(); defer { condition.unlock() }
        while true {
            if isCancelled() { return .cancelledBeforeDispatch }
            switch phaseLocked(project) {
            case .ready: return .linux
            case .preparing: condition.wait()
            case .disabled: return .refused(Self.notEnabledCode)
            case .failed(let reason), .unavailable(let reason): return .refused(reason)
            }
        }
    }

    public func declaration(project: String) -> CapabilityDeclaration {
        CapabilityDeclaration(phase: phase(of: project), availability: availability)
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
        ("shell", .linux), ("subprocess", .linux), ("hook.command", .linux), ("git.write", .linux),
        ("workspace.fifo", .unsupported), ("workspace.unix-socket", .unsupported),
    ]

    public init(phase: LinuxPlugin.Phase, availability: LinuxAvailability) {
        let state: String, reason: String?
        switch (phase, availability) {
        case (.disabled, .unavailable(let why)): state = "UNAVAILABLE"; reason = why.rawValue
        case (.disabled, .available): state = "NOT_ENABLED"; reason = LinuxPlugin.notEnabledCode
        case (.preparing, _): state = "PREPARING"; reason = nil
        case (.ready, _): state = "READY"; reason = nil
        case (.failed(let why), _): state = "FAILED"; reason = why
        case (.unavailable(let why), _): state = "UNAVAILABLE"; reason = why
        }
        let pluginEnabled = phase != .disabled
        plugin = Plugin(enabled: pluginEnabled, state: state, reason: reason,
                        requiredPrivateSymbol: LinuxAvailability.privateSymbol)
        // Preparing Linux items are still usable: their tasks wait for ready.
        let linuxUsable = state == "PREPARING" || state == "READY"
        items = Self.scope.map { name, path in
            switch path {
            case .native: return Item(name: name, path: path, available: true, reason: nil)
            case .linux: return Item(name: name, path: path, available: linuxUsable, reason: linuxUsable ? nil : reason)
            case .unsupported: return Item(name: name, path: path, available: false, reason: "SHARE_MODE_NONE")
            }
        }
    }
}
