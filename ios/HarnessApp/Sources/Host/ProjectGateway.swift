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

/// The single authority over one project: native reads and writes go through the durable
/// `WorkspaceStore`, Linux commands run under its write lease. All store access is serialized
/// here; no lock is held while a guest RPC is in flight, so native writes keep working as drafts.
public final class ProjectGateway: @unchecked Sendable {
    public static let writerUnknownCode = "WRITER_UNKNOWN"

    public let project: String
    private let store: WorkspaceStore
    private let plugin: LinuxPlugin
    private let rpc: GuestRPC
    /// Guards the store and `dispatched`. Never held during a guest RPC.
    private let storeLock = NSLock()
    private enum Operation { case waiting, dispatching, finished }
    /// Guards `operations` and `cancelled`. Lock order: plugin, then `operationsLock`; `storeLock`,
    /// then `operationsLock`.
    private let operationsLock = NSLock()
    private var operations: [String: Operation] = [:]
    private var cancelled = Set<String>()
    /// Fences this process sent to its guest. A writer-unknown lease outside this set was left by an
    /// earlier App process, whose in-process VM is gone.
    private var dispatched = Set<Int>()
    private let cancelWindow: TimeInterval

    /// `cancelWindow` bounds how long a cancellation retries the guest before leaving the writer unknown.
    public init(project: String, store: WorkspaceStore, plugin: LinuxPlugin, rpc: GuestRPC, cancelWindow: TimeInterval = 35) {
        self.project = project; self.store = store; self.plugin = plugin; self.rpc = rpc; self.cancelWindow = cancelWindow
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

    /// Runs a Linux task once. The execution path is fixed before it starts; a task that may have had
    /// side effects is never rerun here or on another executor. An operation id runs at most once per
    /// gateway, even after it was cancelled.
    public func execute(_ id: String, task: LinuxPlugin.Task, argv: [String], timeoutMs: Int,
                        secrets: [String: String] = [:]) -> ExecuteOutcome {
        operationsLock.lock()
        guard operations[id] == nil else { operationsLock.unlock(); return .refused("DUPLICATE_OPERATION") }
        operations[id] = .waiting
        operationsLock.unlock()
        defer { operationsLock.lock(); operations[id] = .finished; operationsLock.unlock() }
        let admission = plugin.admit(task, project: project) { [self] in
            operationsLock.lock(); defer { operationsLock.unlock() }; return cancelled.contains(id)
        }
        switch admission {
        case .linux:
            operationsLock.lock(); defer { operationsLock.unlock() }
            if cancelled.contains(id) { return .cancelledBeforeDispatch }
            operations[id] = .dispatching
        case .native: return .refused("PATH_REFUSED")
        case .cancelledBeforeDispatch: return .cancelledBeforeDispatch
        case .refused(let code): return .refused(code)
        }
        let lease: Lease
        do {
            storeLock.lock(); defer { storeLock.unlock() }
            switch try store.acquireLease(id) {
            case .busy(let held): return .refused(held.state == .writerUnknown ? Self.writerUnknownCode : "LEASE_BUSY")
            case .granted(let granted): lease = granted
            }
            dispatched.insert(lease.fence)
            // The ledger entry is durable before the command can have any effect.
            try store.toolStarted(id)
            operationsLock.lock(); let stop = cancelled.contains(id); operationsLock.unlock()
            if stop {
                _ = try store.releaseLease(fence: lease.fence, reason: .refused)
                try store.toolFinished(id, outcome: "CANCELLED")
                return .cancelledBeforeDispatch
            }
        } catch { return .refused("STORE_FAILED") }
        var request: [String: Any] = ["id": id, "projectId": project, "argv": argv, "timeoutMs": timeoutMs,
                                      "cwd": "/workspace", "lease": ["epoch": lease.epoch, "fence": lease.fence]]
        if !secrets.isEmpty { request["secretEnv"] = secrets }
        let answer: [String: Any]
        do { answer = try rpc.call("/execute", request) }
        catch GuestRPCError.refused(let code) {
            // Every agent refusal happens before spawn: nothing can hold the writable view.
            storeLock.lock(); defer { storeLock.unlock() }
            _ = try? store.releaseLease(fence: lease.fence, reason: .refused)
            try? store.toolFinished(id, outcome: "REFUSED")
            return .refused(code ?? "GUEST_REFUSED")
        } catch {
            storeLock.lock(); defer { storeLock.unlock() }
            return writerUnknown(lease, id, nil)
        }
        let result = CommandResult(answer)
        storeLock.lock(); defer { storeLock.unlock() }
        // Only the guest's confirmation that every process of the command is gone ends the writer.
        guard answer["writerQuiescent"] as? Bool == true else { return writerUnknown(lease, id, result) }
        do {
            guard let release = try store.releaseLease(fence: lease.fence, reason: .completed) else { return writerUnknown(lease, id, result) }
            try store.toolFinished(id, outcome: "COMPLETED")
            return .completed(result, release)
        } catch { return writerUnknown(lease, id, result) }
    }

    /// Stops a task. Before dispatch this has no side effects. During dispatch only the idempotent
    /// guest `/cancel` is retried, never `/execute`; if the guest cannot confirm in time, the writer
    /// is unknown and the lease stays held.
    public func cancel(_ id: String) -> CancelOutcome {
        operationsLock.lock()
        cancelled.insert(id)
        let state = operations[id]
        operationsLock.unlock()
        switch state {
        case nil, .waiting?:
            plugin.wake()
            return .cancelledBeforeDispatch
        case .finished?:
            return .finished
        case .dispatching?:
            break
        }
        let deadline = Date().addingTimeInterval(cancelWindow)
        while Date() < deadline {
            operationsLock.lock(); let now = operations[id]; operationsLock.unlock()
            if now == .finished { return .finished }
            if let answer = try? rpc.call("/cancel", ["id": id]), answer["cancelled"] as? Bool == true { return .requested }
            Thread.sleep(forTimeInterval: 0.05)
        }
        storeLock.lock(); defer { storeLock.unlock() }
        if let lease = store.lease, lease.operation == id { try? store.markWriterUnknown(fence: lease.fence) }
        return .writerUnknown
    }

    /// QEMU of this project's guest exited. Diagnostics are saved and Linux fails for the rest of the
    /// process; the exit confirms a writer this process dispatched stopped, so its lease is released as
    /// `GUEST_TERMINATED`. A lease left by an earlier process still waits for `releaseUnknownWriter`.
    public func guestExited(status: Int32?) {
        plugin.vmExited(status: status)
        storeLock.lock(); defer { storeLock.unlock() }
        if let lease = store.lease, dispatched.contains(lease.fence) {
            _ = try? store.releaseLease(fence: lease.fence, reason: .guestTerminated)
        }
    }

    /// Releases a writer-unknown lease once its writer is known to have stopped: the live guest revokes
    /// the fence, or the lease was left by an earlier App process. Never automatic: the caller asks the
    /// user first, because whatever the lost writer left in the workspace is committed as is.
    public func releaseUnknownWriter() -> UnknownWriterRelease {
        storeLock.lock()
        guard let lease = store.lease, lease.state == .writerUnknown else { storeLock.unlock(); return .noUnknownWriter }
        let live = dispatched.contains(lease.fence)
        storeLock.unlock()
        if live {
            let answer: [String: Any]
            do { answer = try rpc.call("/revoke", ["epoch": lease.epoch, "fence": lease.fence]) } catch { return .unreachable }
            guard answer["revoked"] as? Bool == true else { return .stillRunning }
        }
        storeLock.lock(); defer { storeLock.unlock() }
        do {
            guard let release = try store.releaseLease(fence: lease.fence, reason: .reconciled) else { return .noUnknownWriter }
            return .released(release)
        } catch { return .storeFailed }
    }

    /// Caller holds `storeLock`. The lease stays held; the tool call is recorded as unknown, never replayed.
    private func writerUnknown(_ lease: Lease, _ id: String, _ result: CommandResult?) -> ExecuteOutcome {
        try? store.markWriterUnknown(fence: lease.fence)
        try? store.toolFinished(id, outcome: WorkspaceStore.unknownOutcome)
        return .writerUnknown(result)
    }
}
