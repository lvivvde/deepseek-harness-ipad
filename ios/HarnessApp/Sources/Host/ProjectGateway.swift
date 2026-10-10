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
    /// The lease a terminal holds while a command runs in it. Guarded by `storeLock`.
    private struct TerminalLease {
        let terminal: String
        let fence: Int
        /// The ledger entry for this run of the terminal.
        let call: String
        /// Model commands running inside the terminal's view.
        var joined = Set<String>()
        /// `/terminal/unlease` is in flight; a command waits for it instead of joining.
        var releasing = false
    }
    private var terminalLease: TerminalLease?
    /// Leased runs per terminal, for distinct ledger ids. Guarded by `storeLock`.
    private var terminalRuns: [String: Int] = [:]
    /// Serializes a terminal's lease changes (a leased write, its release, close). Lock order:
    /// `terminalLock`, then `storeLock`.
    private let terminalLock = NSLock()
    private let joinWait: TimeInterval

    /// `cancelWindow` bounds how long a cancellation retries the guest before leaving the writer unknown.
    /// `joinWait` bounds how long a command waits for a terminal's lease release that is in flight.
    public init(project: String, store: WorkspaceStore, plugin: LinuxPlugin, rpc: GuestRPC, cancelWindow: TimeInterval = 35,
                joinWait: TimeInterval = 30) {
        self.project = project; self.store = store; self.plugin = plugin; self.rpc = rpc; self.cancelWindow = cancelWindow
        self.joinWait = joinWait
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

    /// Runs a Linux task once. The execution path is fixed before it starts; a task that may have had
    /// side effects is never rerun here or on another executor. An operation id runs at most once per
    /// gateway, even after it was cancelled. `cwd` is a guest path inside `/workspace`.
    public func execute(_ id: String, task: LinuxPlugin.Task, argv: [String], timeoutMs: Int,
                        secrets: [String: String] = [:], cwd: String = "/workspace") -> ExecuteOutcome {
        guard Self.insideWorkspace(cwd) else { return .refused("CWD_REFUSED") }
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
        var acquired: Lease?
        var join: String?
        let joinDeadline = Date().addingTimeInterval(joinWait)
        do {
            storeLock.lock(); defer { storeLock.unlock() }
            while acquired == nil {
                switch try store.acquireLease(id) {
                case .granted(let granted): acquired = granted
                case .busy(let held):
                    guard held.state == .active, let terminal = terminalLease, terminal.fence == held.fence else {
                        return .refused(held.state == .writerUnknown ? Self.writerUnknownCode : "LEASE_BUSY")
                    }
                    // A terminal's release in flight decides whether this command joins it or takes a fresh lease.
                    if terminal.releasing {
                        guard Date() < joinDeadline else { return .refused("LEASE_BUSY") }
                        storeLock.unlock(); Thread.sleep(forTimeInterval: 0.05); storeLock.lock()
                        continue
                    }
                    acquired = held; join = terminal.terminal
                    terminalLease?.joined.insert(id)
                }
            }
            let lease = acquired!
            dispatched.insert(lease.fence)
            // The ledger entry is durable before the command can have any effect.
            try store.toolStarted(id)
            operationsLock.lock(); let stop = cancelled.contains(id); operationsLock.unlock()
            if stop {
                if join == nil { _ = try store.releaseLease(fence: lease.fence, reason: .refused) } else { terminalLease?.joined.remove(id) }
                try store.toolFinished(id, outcome: "CANCELLED")
                return .cancelledBeforeDispatch
            }
        } catch {
            storeLock.lock(); if join != nil { terminalLease?.joined.remove(id) }; storeLock.unlock()
            return .refused("STORE_FAILED")
        }
        let lease = acquired!
        var request: [String: Any] = ["id": id, "projectId": project, "argv": argv, "timeoutMs": timeoutMs,
                                      "cwd": cwd, "lease": ["epoch": lease.epoch, "fence": lease.fence]]
        if !secrets.isEmpty { request["secretEnv"] = secrets }
        if let join { request["join"] = join }
        let answer: [String: Any]
        do { answer = try rpc.call("/execute", request) }
        catch GuestRPCError.refused(let code) {
            // Every agent refusal happens before spawn: nothing can hold the writable view.
            storeLock.lock(); defer { storeLock.unlock() }
            if join == nil { _ = try? store.releaseLease(fence: lease.fence, reason: .refused) } else { terminalLease?.joined.remove(id) }
            try? store.toolFinished(id, outcome: "REFUSED")
            return .refused(code ?? "GUEST_REFUSED")
        } catch {
            storeLock.lock(); defer { storeLock.unlock() }
            return writerUnknown(lease, id, nil)
        }
        let result = CommandResult(answer)
        storeLock.lock(); defer { storeLock.unlock() }
        if join != nil {
            guard answer["writerQuiescent"] as? Bool == true, answer["joined"] as? Bool == true else { return writerUnknown(lease, id, result) }
            terminalLease?.joined.remove(id)
            do { try store.toolFinished(id, outcome: "COMPLETED") } catch { return writerUnknown(lease, id, result) }
            return .joined(result)
        }
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
        if let lease = store.lease, lease.operation == id || terminalLease?.joined.contains(id) == true {
            markWriterUnknown(lease.fence)
        }
        return .writerUnknown
    }

    /// QEMU of this project's guest exited. Diagnostics are saved and Linux fails for the rest of the
    /// process; the exit confirms a writer this process dispatched stopped, so its lease is released as
    /// `GUEST_TERMINATED`. A lease left by an earlier process still waits for `releaseUnknownWriter`.
    public func guestExited(status: Int32?) {
        plugin.vmExited(status: status)
        storeLock.lock(); defer { storeLock.unlock() }
        if let terminal = terminalLease { try? store.toolFinished(terminal.call, outcome: WorkspaceStore.unknownOutcome) }
        terminalLease = nil
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

    // MARK: Terminal

    /// Bytes that make an idle shell run something: Enter, Ctrl-J, Ctrl-O (operate-and-get-next) and the
    /// Ctrl-X prefix (edit-and-execute-command). Only input carrying one of them takes the write lease.
    static let runKeys: Set<UInt8> = [0x0a, 0x0d, 0x0f, 0x18]
    static let terminalShell = ["/bin/bash", "-i"]

    /// Opens a shell on a pty in the guest. Its view of the workspace stays read-only until a line is
    /// run in it; `cwd` is a guest path inside `/workspace`.
    public func openTerminal(_ id: String, argv: [String], cwd: String, cols: Int, rows: Int,
                             env: [String: String] = [:], terminalType: String? = nil) throws -> Int {
        guard Self.insideWorkspace(cwd) else { throw TerminalError("CWD_REFUSED") }
        // Only an interactive bash reports its idle prompt, which is what ends a terminal's lease.
        guard argv == Self.terminalShell else { throw TerminalError("ARGV_REFUSED") }
        switch plugin.admit(.terminal(id), project: project, isCancelled: { false }) {
        case .linux: break
        case .refused(let code): throw TerminalError(code)
        case .native, .cancelledBeforeDispatch: throw TerminalError("PATH_REFUSED")
        }
        var request: [String: Any] = ["id": id, "projectId": project, "argv": argv, "cwd": cwd, "cols": cols, "rows": rows,
                                      "env": env, "shellActivity": true]
        if let terminalType { request["terminalType"] = terminalType }
        let answer = try terminalCall("/terminal/open", request)
        guard let pid = answer["pid"] as? Int else { throw TerminalError("TERMINAL_START_FAILED") }
        return pid
    }

    /// Sends input to the pty. Input that runs a line at an idle prompt first takes the write lease for
    /// the terminal, so the command writes through; a busy lease refuses it at once.
    public func writeTerminal(_ id: String, _ data: Data) -> TerminalWrite {
        terminalLock.lock(); defer { terminalLock.unlock() }
        var body: [String: Any] = ["id": id, "data": data.base64EncodedString()]
        var granted: TerminalLease?
        storeLock.lock()
        if let held = terminalLease, held.terminal == id, let lease = store.lease, lease.fence == held.fence {
            body["lease"] = ["epoch": lease.epoch, "fence": lease.fence]
        } else if data.contains(where: Self.runKeys.contains) {
            let run = (terminalRuns[id] ?? 0) + 1
            let call = "terminal:\(id):\(run)"
            do {
                switch try store.acquireLease(call) {
                case .busy(let held):
                    storeLock.unlock(); return .refused(held.state == .writerUnknown ? Self.writerUnknownCode : "LEASE_BUSY")
                case .granted(let lease):
                    terminalRuns[id] = run
                    dispatched.insert(lease.fence)
                    granted = TerminalLease(terminal: id, fence: lease.fence, call: call)
                    terminalLease = granted
                    body["lease"] = ["epoch": lease.epoch, "fence": lease.fence]
                    // The ledger entry is durable before the line can have any effect.
                    try store.toolStarted(call)
                }
            } catch {
                if let granted { terminalLease = nil; _ = try? store.releaseLease(fence: granted.fence, reason: .refused) }
                storeLock.unlock(); return .refused("STORE_FAILED")
            }
        }
        storeLock.unlock()
        do {
            let answer = try rpc.call("/terminal/write", body)
            return .written(leased: answer["leased"] as? Bool ?? false)
        } catch GuestRPCError.refused(let code) {
            // The guest refuses before it remounts or writes anything.
            if let granted {
                storeLock.lock(); defer { storeLock.unlock() }
                terminalLease = nil
                _ = try? store.releaseLease(fence: granted.fence, reason: .refused)
                try? store.toolFinished(granted.call, outcome: "REFUSED")
            }
            return .refused(code ?? "GUEST_REFUSED")
        } catch {
            guard let granted else { return .refused("GUEST_UNREACHABLE") }
            storeLock.lock(); defer { storeLock.unlock() }
            markWriterUnknown(granted.fence)
            return .writerUnknown
        }
    }

    /// Long-polls the terminal's output from `offset`. When the guest reports the leased terminal back at
    /// an idle prompt, the lease is released here and its writes committed.
    public func readTerminal(_ id: String, offset: Int, waitMs: Int) throws -> TerminalRead {
        let answer = try terminalCall("/terminal/read", ["id": id, "offset": offset, "waitMs": waitMs])
        let release = answer["releasable"] as? Bool == true ? releaseTerminal(id) : nil
        let exited = (answer["exited"] as? [String: Any]).map { TerminalRead.Exit(code: $0["code"] as? Int, signal: $0["signal"] as? String) }
        return TerminalRead(data: Data(base64Encoded: answer["data"] as? String ?? "") ?? Data(), next: answer["next"] as? Int ?? offset,
                            dropped: answer["dropped"] as? Int ?? 0, exited: exited, activity: Self.activity(answer),
                            leased: release == nil && answer["leased"] as? Bool == true, release: release)
    }

    public func resizeTerminal(_ id: String, cols: Int, rows: Int) throws {
        _ = try terminalCall("/terminal/resize", ["id": id, "cols": cols, "rows": rows])
    }

    /// Signals the pty's foreground process group; returns that group. The shell itself is never killed.
    public func signalTerminal(_ id: String, signal: String) throws -> Int {
        let answer = try terminalCall("/terminal/signal", ["id": id, "signal": signal])
        guard let group = answer["processGroupId"] as? Int else { throw TerminalError("FOREGROUND_UNKNOWN") }
        return group
    }

    /// The pty's foreground group and whether it waits for input; releases an idle terminal's lease.
    public func inspectTerminal(_ id: String) throws -> (foreground: TerminalForeground?, activity: TerminalActivity) {
        let answer = try terminalCall("/terminal/inspect", ["id": id])
        if answer["releasable"] as? Bool == true { _ = releaseTerminal(id) }
        let foreground = (answer["foreground"] as? [String: Any]).flatMap { value in
            (value["processGroupId"] as? Int).map { TerminalForeground(processGroupId: $0, inputWaiting: value["inputWaiting"] as? Bool ?? false) }
        }
        return (foreground, Self.activity(answer))
    }

    /// Hangs up the terminal and ends what still runs in it. A lease it held is released with its
    /// writes; if the guest cannot confirm that, the terminal stays open and this throws.
    @discardableResult
    public func closeTerminal(_ id: String, graceMs: Int = 1000) throws -> LeaseRelease? {
        terminalLock.lock(); defer { terminalLock.unlock() }
        storeLock.lock(); let leased = terminalLease.flatMap { $0.terminal == id ? $0 : nil }; storeLock.unlock()
        var body: [String: Any] = ["id": id, "graceMs": graceMs]
        if let leased { body["fence"] = leased.fence }
        let answer = try terminalCall("/terminal/close", body)
        storeLock.lock(); defer { storeLock.unlock() }
        guard answer["closed"] as? Bool == true else { throw TerminalError("TERMINAL_BUSY") }
        terminalRuns[id] = nil
        guard let held = terminalLease, held.terminal == id else { return nil }
        if answer["releasedFence"] as? Int == held.fence { return completeTerminalLease(held) }
        // The terminal is gone but nothing confirmed its lease ended: never leave that lease active.
        markWriterUnknown(held.fence)
        return nil
    }

    /// Ends the terminal's lease once the guest confirms nothing writes through its view any more: the
    /// prompt is idle with no file open for writing, or the shell has exited. Otherwise the lease stays.
    private func releaseTerminal(_ id: String) -> LeaseRelease? {
        terminalLock.lock(); defer { terminalLock.unlock() }
        storeLock.lock()
        guard let held = terminalLease, held.terminal == id, held.joined.isEmpty, store.lease?.fence == held.fence,
              store.lease?.state == .active else { storeLock.unlock(); return nil }
        terminalLease?.releasing = true
        storeLock.unlock()
        let answer: [String: Any]?
        var stale = false
        do { answer = try rpc.call("/terminal/unlease", ["id": id, "fence": held.fence]) }
        catch GuestRPCError.refused(let code) { answer = nil; stale = code == "LEASE_STALE" }
        catch { answer = nil }
        storeLock.lock(); defer { storeLock.unlock() }
        // The VM may have exited meanwhile and already settled this lease.
        guard let current = terminalLease, current.fence == held.fence else { return nil }
        terminalLease?.releasing = false
        if answer?["writerQuiescent"] as? Bool == true { return completeTerminalLease(current) }
        // The guest no longer knows this lease: nothing can confirm its writers stopped.
        if stale { markWriterUnknown(held.fence) }
        return nil
    }

    /// Caller holds `storeLock`.
    private func completeTerminalLease(_ held: TerminalLease) -> LeaseRelease? {
        terminalLease = nil
        guard let release = try? store.releaseLease(fence: held.fence, reason: .completed) else {
            try? store.markWriterUnknown(fence: held.fence)
            try? store.toolFinished(held.call, outcome: WorkspaceStore.unknownOutcome)
            return nil
        }
        try? store.toolFinished(held.call, outcome: "COMPLETED")
        return release
    }

    private func terminalCall(_ route: String, _ body: [String: Any]) throws -> [String: Any] {
        do { return try rpc.call(route, body) }
        catch GuestRPCError.refused(let code) { throw TerminalError(code ?? "GUEST_REFUSED") }
        catch { throw TerminalError("GUEST_UNREACHABLE") }
    }

    private static func activity(_ answer: [String: Any]) -> TerminalActivity {
        let value = answer["activity"] as? [String: Any]
        return TerminalActivity(state: value?["state"] as? String ?? "unknown", revision: value?["revision"] as? Int ?? 0)
    }

    private static func insideWorkspace(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components[0].isEmpty, components[1] == "workspace" else { return false }
        return !components.dropFirst(2).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Caller holds `storeLock`. The lease stays held; the tool call is recorded as unknown, never replayed.
    private func writerUnknown(_ lease: Lease, _ id: String, _ result: CommandResult?) -> ExecuteOutcome {
        markWriterUnknown(lease.fence)
        try? store.toolFinished(id, outcome: WorkspaceStore.unknownOutcome)
        return .writerUnknown(result)
    }

    /// Caller holds `storeLock`. A terminal holding the fence keeps running but no longer owns a lease
    /// it can release: only `releaseUnknownWriter`, which ends that terminal, does.
    private func markWriterUnknown(_ fence: Int) {
        try? store.markWriterUnknown(fence: fence)
        if let terminal = terminalLease, terminal.fence == fence {
            try? store.toolFinished(terminal.call, outcome: WorkspaceStore.unknownOutcome)
            terminalLease = nil
        }
    }
}
