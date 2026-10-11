import Foundation
import LinuxPlugin
import NativeWorkspace

/// What a Linux command left behind, as the guest reported it.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int?
    public let signal: String?
    public let stdout: String
    public let stderr: String
    public let cancelled: Bool
    public let timedOut: Bool

    init(_ answer: [String: Any]) {
        exitCode = answer["code"] as? Int
        signal = answer["signal"] as? String
        stdout = answer["stdout"] as? String ?? ""
        stderr = answer["stderr"] as? String ?? ""
        cancelled = answer["cancelled"] as? Bool ?? false
        timedOut = answer["timeout"] as? Bool ?? false
    }
}

public enum ExecuteOutcome: Equatable {
    /// The writer is confirmed stopped; its changes are committed and held drafts rebased.
    case completed(CommandResult, LeaseRelease)
    /// Nothing ran: a fixed code from admission, the lease, or the guest's refusal before spawn.
    case refused(String)
    case cancelledBeforeDispatch
    /// The writer may still be running or its end was not confirmed. The lease stays held and the
    /// command is never replayed.
    case writerUnknown(CommandResult?)
    /// The command ran inside a terminal that holds the lease; the lease stays with that terminal and
    /// its writes are committed when the terminal's prompt is idle again.
    case joined(CommandResult)
}

/// A terminal route the guest refused, or a terminal answer that could not be confirmed.
public struct TerminalError: Error, Equatable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

public enum TerminalWrite: Equatable {
    /// The input reached the pty; `leased` says the terminal now holds the write lease.
    case written(leased: Bool)
    /// Not written: a fixed code from admission, the lease, or the guest. `GUEST_UNREACHABLE` means the
    /// answer was lost while no new lease was at stake, so the input may or may not have reached the pty.
    case refused(String)
    /// The lease was sent but the guest's answer was lost; the lease stays held as writer unknown.
    case writerUnknown
}

public struct TerminalRead: Equatable {
    public struct Exit: Equatable { public let code: Int?; public let signal: String? }
    public let data: Data
    public let next: Int
    /// Output older than the requested offset that the guest no longer had.
    public let dropped: Int
    /// Set once the shell has exited and all its output was read.
    public let exited: Exit?
    public let activity: TerminalActivity
    public let leased: Bool
    /// The terminal's lease ended with this read: its writes are committed and held drafts rebased.
    public let release: LeaseRelease?
}

/// `idle`, `busy` or `unknown`, from the shell's own prompt hooks and the pty's foreground group; the
/// revision changes whenever the shell or the foreground group moves on.
public struct TerminalActivity: Equatable {
    public let state: String
    public let revision: Int
}

public struct TerminalForeground: Equatable {
    public let processGroupId: Int
    public let inputWaiting: Bool
}

public enum CancelOutcome: Equatable {
    /// The task had not been dispatched; it never will be.
    case cancelledBeforeDispatch
    /// The guest accepted the cancellation; the task's own outcome reports when the writer stopped.
    case requested
    /// The guest could not be reached in time: the lease stays held as writer unknown.
    case writerUnknown
    /// The task had already ended; its own outcome stands.
    case finished
}

public enum UnknownWriterRelease: Equatable {
    case released(LeaseRelease)
    /// The live guest still runs the writer; the lease stays held.
    case stillRunning
    /// The live guest could not confirm; the lease stays held.
    case unreachable
    case noUnknownWriter
    case storeFailed
}

/// One project's authority for native tools and durable workspace access. Linux execution delegates
/// to the process owner, while both paths share this project's store lock.
public final class ProjectGateway: @unchecked Sendable {
    public static let writerUnknownCode = "WRITER_UNKNOWN"
    public let project: String
    private let execution: LinuxExecution
    private let access: LinuxExecution.Project
    private let rpc: GuestRPC
    private var store: WorkspaceStore { access.store }
    private var storeLock: NSLock { access.storeLock }

    public init(project: String, store: WorkspaceStore, plugin: LinuxPlugin, rpc: GuestRPC,
                cancelWindow: TimeInterval = 35, joinWait: TimeInterval = 30,
                execution: LinuxExecution? = nil) {
        self.project = project; self.rpc = rpc
        let owner = execution ?? LinuxExecution(plugin: plugin, rpc: rpc)
        self.execution = owner
        self.access = owner.register(project: project, store: store, cancelWindow: cancelWindow, joinWait: joinWait)
    }

    public var lease: Lease? { storeLock.lock(); defer { storeLock.unlock() }; return store.lease }

    /// Bring-up step after the ready proof: tells the fresh guest the durable epoch. Binding never
    /// grants a writer.
    public func attach() throws {
        storeLock.lock(); let epoch = store.epoch; storeLock.unlock()
        _ = try rpc.call("/bind", ["epoch": epoch])
    }

    public func nativeRead(_ path: RelativePath) throws -> ReadResult {
        storeLock.lock(); defer { storeLock.unlock() }; return try store.nativeRead(path)
    }

    public func nativeWrite(_ path: RelativePath, _ data: Data, base: String?) throws -> WriteResult {
        storeLock.lock(); defer { storeLock.unlock() }; return try store.nativeWrite(path, data, base: base)
    }

    /// Runs native tool work that holds the same store (`NativeFileService`, path space, search, git)
    /// serialized with every other store access. `body` must not call back into this gateway.
    public func withStore<T>(_ body: (WorkspaceStore) throws -> T) rethrows -> T {
        storeLock.lock(); defer { storeLock.unlock() }; return try body(store)
    }

    public func execute(_ id: String, task: LinuxPlugin.Task, argv: [String], timeoutMs: Int,
                        secrets: [String: String] = [:], cwd: String = "/workspace") -> ExecuteOutcome {
        access.execute(id, task: task, argv: argv, timeoutMs: timeoutMs, secrets: secrets, cwd: cwd)
    }
    public func cancel(_ id: String) -> CancelOutcome { execution.cancel(id) }
    public func guestExited(status: Int32?) { execution.guestExited(status: status) }
    public func releaseUnknownWriter() -> UnknownWriterRelease { access.releaseUnknownWriter() }
    public func openTerminal(_ id: String, argv: [String], cwd: String, cols: Int, rows: Int,
                             env: [String: String] = [:], terminalType: String? = nil) throws -> Int {
        try execution.openTerminal(access, id: id, argv: argv, cwd: cwd, cols: cols, rows: rows, env: env, terminalType: terminalType)
    }
    public func writeTerminal(_ id: String, _ data: Data) -> TerminalWrite { access.writeTerminal(id, data) }
    public func readTerminal(_ id: String, offset: Int, waitMs: Int) throws -> TerminalRead { try access.readTerminal(id, offset: offset, waitMs: waitMs) }
    public func resizeTerminal(_ id: String, cols: Int, rows: Int) throws { try access.resizeTerminal(id, cols: cols, rows: rows) }
    public func signalTerminal(_ id: String, signal: String) throws -> Int { try access.signalTerminal(id, signal: signal) }
    public func inspectTerminal(_ id: String) throws -> (foreground: TerminalForeground?, activity: TerminalActivity) { try access.inspectTerminal(id) }
    @discardableResult public func closeTerminal(_ id: String, graceMs: Int = 1000) throws -> LeaseRelease? {
        try execution.closeTerminal(access, id: id, graceMs: graceMs)
    }
}
