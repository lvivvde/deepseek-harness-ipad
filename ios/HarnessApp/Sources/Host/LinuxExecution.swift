import Foundation
import LinuxPlugin
import NativeWorkspace

/// One process owns operation identities, cancellation and terminal routing. Its private project
/// implementation owns each writer's grant, dispatch and settlement under the same store lock used
/// by native operations. A transport answer never decides ownership on its own.
public final class LinuxExecution: @unchecked Sendable {
    private enum Operation { case waiting, dispatching, finished }
    private let lock = NSLock()
    private var operations: [String: Operation] = [:]
    private var owners: [String: Project] = [:]
    private var cancelled = Set<String>()
    private var guestGone = false
    private var projects: [String: Project] = [:]
    private final class TerminalRegistration {
        let owner: Project
        // Serializes open/close and short calls across reuse of the same terminal ID. Long reads
        // stay outside it so closing a terminal can interrupt an output poll.
        let lifecycle = NSLock()
        init(_ owner: Project) { self.owner = owner }
    }
    private var terminals: [String: TerminalRegistration] = [:]
    private let plugin: LinuxPlugin
    private let rpc: GuestRPC

    public init(plugin: LinuxPlugin, rpc: GuestRPC) {
        self.plugin = plugin; self.rpc = rpc
    }

    func register(project: String, store: WorkspaceStore, cancelWindow: TimeInterval,
                  joinWait: TimeInterval) -> Project {
        lock.lock(); defer { lock.unlock() }
        if let existing = projects[project] { return existing }
        let owner = Project(project: project, store: store, execution: self,
                            cancelWindow: cancelWindow, joinWait: joinWait)
        projects[project] = owner
        return owner
    }

    private func begin(_ id: String, owner: Project) -> ExecuteOutcome? {
        lock.lock(); defer { lock.unlock() }
        guard operations[id] == nil else { return .refused("DUPLICATE_OPERATION") }
        owners[id] = owner
        if cancelled.contains(id) { operations[id] = .finished; return .cancelledBeforeDispatch }
        operations[id] = .waiting
        return nil
    }

    private func finish(_ id: String) {
        lock.lock(); operations[id] = .finished; lock.unlock()
    }

    /// Cancellation can precede registration. The terminal fact of a consumed ID is never expired.
    public func cancel(_ id: String) -> CancelOutcome {
        lock.lock()
        cancelled.insert(id)
        let state = operations[id], owner = owners[id]
        lock.unlock()
        switch state {
        case nil, .waiting?: plugin.wake(); return .cancelledBeforeDispatch
        case .finished?: return .finished
        case .dispatching?: break
        }
        guard let owner else { return .finished }
        let deadline = Date().addingTimeInterval(owner.cancelWindow)
        while Date() < deadline {
            lock.lock(); let now = operations[id]; lock.unlock()
            if now == .finished { return .finished }
            if let answer = try? rpc.call("/cancel", ["id": id]), answer["cancelled"] as? Bool == true { return .requested }
            Thread.sleep(forTimeInterval: 0.05)
        }
        owner.storeLock.lock(); defer { owner.storeLock.unlock() }
        if let lease = owner.store.lease, lease.operation == id || owner.terminalLease?.joined.contains(id) == true {
            owner.markWriterUnknown(lease.fence)
        }
        return .writerUnknown
    }

    /// Mark exit before publishing diagnostics or waiting for a store: grants and dispatch decisions
    /// observe this fact even while diagnostic persistence is in flight.
    public func guestExited(status: Int32?) {
        lock.lock()
        guard !guestGone else { lock.unlock(); return }
        guestGone = true
        let all = Array(projects.values)
        terminals.removeAll()
        lock.unlock()
        plugin.vmExited(status: status)
        for owner in all { owner.guestExited(status: status) }
    }

    func openTerminal(_ owner: Project, id: String, argv: [String], cwd: String, cols: Int, rows: Int,
                      env: [String: String], terminalType: String?) throws -> Int {
        let registration = TerminalRegistration(owner)
        registration.lifecycle.lock(); defer { registration.lifecycle.unlock() }
        lock.lock()
        guard !guestGone else { lock.unlock(); throw TerminalError(LinuxPlugin.vmExitedCode) }
        guard terminals[id] == nil else { lock.unlock(); throw TerminalError("DUPLICATE_TERMINAL") }
        terminals[id] = registration
        lock.unlock()
        do {
            let pid = try owner.openTerminal(id, argv: argv, cwd: cwd, cols: cols, rows: rows, env: env, terminalType: terminalType)
            lock.lock(); let gone = guestGone; lock.unlock()
            if gone { throw TerminalError("GUEST_UNREACHABLE") }
            return pid
        } catch {
            let uncertain = (error as? TerminalError)?.code == "GUEST_UNREACHABLE"
            if !uncertain || closeIfConfirmed(id, owner) { forgetTerminal(id, registration) }
            throw error
        }
    }

    public func hasTerminal(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return terminals[id] != nil
    }

    private func terminal(_ id: String, owner: Project? = nil) throws -> TerminalRegistration {
        lock.lock(); defer { lock.unlock() }
        guard let registration = terminals[id], owner == nil || registration.owner === owner else {
            throw TerminalError("TERMINAL_NOT_FOUND")
        }
        return registration
    }

    private func isCurrent(_ id: String, _ registration: TerminalRegistration) -> Bool {
        lock.lock(); defer { lock.unlock() }; return terminals[id] === registration
    }

    func withTerminal<T>(_ id: String, owner: Project? = nil, _ work: (Project) throws -> T) throws -> T {
        let registration = try terminal(id, owner: owner)
        registration.lifecycle.lock(); defer { registration.lifecycle.unlock() }
        guard isCurrent(id, registration) else { throw TerminalError("TERMINAL_NOT_FOUND") }
        return try work(registration.owner)
    }

    public func writeTerminal(_ id: String, _ data: Data) throws -> TerminalWrite {
        try withTerminal(id) { $0.writeTerminal(id, data) }
    }
    public func readTerminal(_ id: String, offset: Int, waitMs: Int) throws -> TerminalRead {
        try readTerminal(terminal(id), id: id, offset: offset, waitMs: waitMs)
    }
    func readTerminal(_ owner: Project, id: String, offset: Int, waitMs: Int) throws -> TerminalRead {
        try readTerminal(terminal(id, owner: owner), id: id, offset: offset, waitMs: waitMs)
    }
    private func readTerminal(_ registration: TerminalRegistration, id: String, offset: Int, waitMs: Int) throws -> TerminalRead {
        // Wait for opening to finish, but allow a close to interrupt the guest's long poll.
        registration.lifecycle.lock()
        let current = isCurrent(id, registration)
        registration.lifecycle.unlock()
        guard current else { throw TerminalError("TERMINAL_NOT_FOUND") }
        return try registration.owner.readTerminal(id, offset: offset, waitMs: waitMs)
    }
    public func resizeTerminal(_ id: String, cols: Int, rows: Int) throws {
        try withTerminal(id) { try $0.resizeTerminal(id, cols: cols, rows: rows) }
    }
    public func signalTerminal(_ id: String, signal: String) throws -> Int {
        try withTerminal(id) { try $0.signalTerminal(id, signal: signal) }
    }
    public func inspectTerminal(_ id: String) throws -> (foreground: TerminalForeground?, activity: TerminalActivity) {
        try withTerminal(id) { try $0.inspectTerminal(id) }
    }
    @discardableResult public func closeTerminal(_ id: String, graceMs: Int = 1000) throws -> LeaseRelease? {
        try closeTerminal(terminal(id), id: id, graceMs: graceMs)
    }

    func closeTerminal(_ owner: Project, id: String, graceMs: Int) throws -> LeaseRelease? {
        try closeTerminal(terminal(id, owner: owner), id: id, graceMs: graceMs)
    }

    private func closeTerminal(_ registration: TerminalRegistration, id: String, graceMs: Int) throws -> LeaseRelease? {
        registration.lifecycle.lock(); defer { registration.lifecycle.unlock() }
        guard isCurrent(id, registration) else { throw TerminalError("TERMINAL_NOT_FOUND") }
        let release = try registration.owner.closeTerminal(id, graceMs: graceMs)
        forgetTerminal(id, registration)
        return release
    }

    public func resetTerminals() -> (closed: Int, remaining: [String]) {
        lock.lock(); let left = terminals; lock.unlock()
        var remaining: [String] = []
        for (id, registration) in left {
            do { _ = try closeTerminal(registration, id: id, graceMs: 0) }
            catch {
                // A concurrent close already removed this registration; a new one with the same ID
                // belongs to a later open and must not be closed by this reset.
                if isCurrent(id, registration) { remaining.append(id) }
            }
        }
        return (left.count - remaining.count, remaining.sorted())
    }

    private func closeIfConfirmed(_ id: String, _ owner: Project) -> Bool {
        do { try owner.closeTerminal(id, graceMs: 0); return true } catch { return false }
    }

    private func forgetTerminal(_ id: String, _ registration: TerminalRegistration) {
        lock.lock(); if terminals[id] === registration { terminals[id] = nil }; lock.unlock()
    }

    final class Project: @unchecked Sendable {
        public static let writerUnknownCode = "WRITER_UNKNOWN"

        public let project: String
        let store: WorkspaceStore
        private let plugin: LinuxPlugin
        private let rpc: GuestRPC
        /// Guards the store and `dispatched`. Never held during a guest RPC.
        let storeLock = NSLock()
        private unowned let execution: LinuxExecution
        /// Fences this process sent to its guest. A writer-unknown lease outside this set was left by an
        /// earlier App process, whose in-process VM is gone.
        private var dispatched = Set<Int>()
        private var unsent = Set<Int>()
        let cancelWindow: TimeInterval
        /// The lease a terminal holds while a command runs in it. Guarded by `storeLock`.
        fileprivate struct TerminalLease {
            let terminal: String
            let fence: Int
            /// The ledger entry for this run of the terminal.
            let call: String
            /// Model commands running inside the terminal's view.
            var joined = Set<String>()
            /// `/terminal/unlease` is in flight; a command waits for it instead of joining.
            var releasing = false
        }
        fileprivate var terminalLease: TerminalLease?
        /// Leased runs per terminal, for distinct ledger ids. Guarded by `storeLock`.
        private var terminalRuns: [String: Int] = [:]
        /// Serializes a terminal's lease changes (a leased write, its release, close). Lock order:
        /// `terminalLock`, then `storeLock`.
        private let terminalLock = NSLock()
        private let joinWait: TimeInterval

        /// `cancelWindow` bounds how long a cancellation retries the guest before leaving the writer unknown.
        /// `joinWait` bounds how long a command waits for a terminal's lease release that is in flight.
        init(project: String, store: WorkspaceStore, execution: LinuxExecution,
             cancelWindow: TimeInterval, joinWait: TimeInterval) {
            self.project = project; self.store = store; self.execution = execution
            self.plugin = execution.plugin; self.rpc = execution.rpc
            self.cancelWindow = cancelWindow; self.joinWait = joinWait
        }

        /// Caller holds storeLock. These fences were never sent, or the guest proved refusal before
        /// spawn. A failed release may already have committed before draft rebasing failed.
        private func releaseUnsent(_ fence: Int) throws {
            unsent.insert(fence)
            defer { if store.lease?.fence != fence { unsent.remove(fence) } }
            _ = try store.releaseLease(fence: fence, reason: .refused)
        }

        private func retryUnsent() throws {
            if let held = store.lease, unsent.contains(held.fence) { try releaseUnsent(held.fence) }
        }

        /// Runs a Linux task once. The execution path is fixed before it starts; a task that may have had
        /// side effects is never rerun here or on another executor. An operation id runs at most once per
        /// gateway, even after it was cancelled. `cwd` is a guest path inside `/workspace`.
        public func execute(_ id: String, task: LinuxPlugin.Task, argv: [String], timeoutMs: Int,
                            secrets: [String: String] = [:], cwd: String = "/workspace") -> ExecuteOutcome {
            guard Self.insideWorkspace(cwd) else { return .refused("CWD_REFUSED") }
            if let refused = execution.begin(id, owner: self) { return refused }
            defer { execution.finish(id) }
            do {
                storeLock.lock(); defer { storeLock.unlock() }
                try retryUnsent()
            } catch { return .refused("STORE_FAILED") }
            let admission = plugin.admit(task, project: project) { [self] in
                execution.lock.lock(); defer { execution.lock.unlock() }; return execution.cancelled.contains(id)
            }
            switch admission {
            case .linux:
                execution.lock.lock(); defer { execution.lock.unlock() }
                if execution.cancelled.contains(id) { return .cancelledBeforeDispatch }
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
                    execution.lock.lock(); let gone = execution.guestGone; execution.lock.unlock()
                    if gone { return .refused(LinuxPlugin.vmExitedCode) }
                    try retryUnsent()
                    switch try store.acquireLease(id) {
                    case .granted(let granted): acquired = granted; unsent.insert(granted.fence)
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
                // The ledger entry is durable before the command can have any effect.
                try store.toolStarted(id)
                execution.lock.lock()
                let stop = execution.cancelled.contains(id), gone = execution.guestGone
                if !stop && !gone { execution.operations[id] = .dispatching }
                execution.lock.unlock()
                if stop || gone {
                    if join == nil { try releaseUnsent(lease.fence) } else { terminalLease?.joined.remove(id) }
                    try store.toolFinished(id, outcome: stop ? "CANCELLED" : "REFUSED")
                    unsent.remove(lease.fence)
                    return stop ? .cancelledBeforeDispatch : .refused(LinuxPlugin.vmExitedCode)
                }
                unsent.remove(lease.fence)
                dispatched.insert(lease.fence)
            } catch {
                storeLock.lock()
                if join != nil { terminalLease?.joined.remove(id) }
                else if let acquired { try? releaseUnsent(acquired.fence) }
                storeLock.unlock()
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
                do {
                    if join == nil { try releaseUnsent(lease.fence) } else { terminalLease?.joined.remove(id) }
                    try store.toolFinished(id, outcome: "REFUSED")
                } catch { return .refused("STORE_FAILED") }
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

        /// QEMU of this project's guest exited. Diagnostics are saved and Linux fails for the rest of the
        /// process; the exit confirms a writer this process dispatched stopped, so its lease is released as
        /// `GUEST_TERMINATED`. A lease left by an earlier process still waits for `releaseUnknownWriter`.
        public func guestExited(status: Int32?) {
            storeLock.lock(); defer { storeLock.unlock() }
            if let terminal = terminalLease { try? store.toolFinished(terminal.call, outcome: WorkspaceStore.unknownOutcome) }
            terminalLease = nil
            if let lease = store.lease {
                if unsent.contains(lease.fence) { try? releaseUnsent(lease.fence) }
                else if dispatched.contains(lease.fence) { _ = try? store.releaseLease(fence: lease.fence, reason: .guestTerminated) }
            }
        }

        /// Releases a writer-unknown lease once its writer is known to have stopped: the live guest revokes
        /// the fence, or the lease was left by an earlier App process. Never automatic: the caller asks the
        /// user first, because whatever the lost writer left in the workspace is committed as is.
        public func releaseUnknownWriter() -> UnknownWriterRelease {
            storeLock.lock()
            guard let lease = store.lease, lease.state == .writerUnknown else { storeLock.unlock(); return .noUnknownWriter }
            execution.lock.lock(); let gone = execution.guestGone; execution.lock.unlock()
            let live = dispatched.contains(lease.fence) && !gone
            storeLock.unlock()
            if live {
                let answer: [String: Any]
                do { answer = try rpc.call("/revoke", ["epoch": lease.epoch, "fence": lease.fence]) } catch { return .unreachable }
                guard answer["revoked"] as? Bool == true else { return .stillRunning }
            }
            storeLock.lock(); defer { storeLock.unlock() }
            do {
                let reason: LeaseRelease.Reason = gone && dispatched.contains(lease.fence) ? .guestTerminated : .reconciled
                guard let release = try store.releaseLease(fence: lease.fence, reason: reason) else { return .noUnknownWriter }
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
            execution.lock.lock(); let gone = execution.guestGone; execution.lock.unlock()
            if gone { return .refused(LinuxPlugin.vmExitedCode) }
            var body: [String: Any] = ["id": id, "data": data.base64EncodedString()]
            var granted: TerminalLease?
            storeLock.lock()
            do { try retryUnsent() } catch { storeLock.unlock(); return .refused("STORE_FAILED") }
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
                        unsent.insert(lease.fence)
                        granted = TerminalLease(terminal: id, fence: lease.fence, call: call)
                        terminalLease = granted
                        body["lease"] = ["epoch": lease.epoch, "fence": lease.fence]
                        // The ledger entry is durable before the line can have any effect.
                        try store.toolStarted(call)
                        execution.lock.lock(); let gone = execution.guestGone; execution.lock.unlock()
                        if gone {
                            terminalLease = nil
                            try releaseUnsent(lease.fence)
                            try store.toolFinished(call, outcome: "REFUSED")
                            storeLock.unlock(); return .refused(LinuxPlugin.vmExitedCode)
                        }
                        unsent.remove(lease.fence)
                        dispatched.insert(lease.fence)
                    }
                } catch {
                    if let granted { terminalLease = nil; try? releaseUnsent(granted.fence) }
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
                    do {
                        try releaseUnsent(granted.fence)
                        try store.toolFinished(granted.call, outcome: "REFUSED")
                    } catch { return .refused("STORE_FAILED") }
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
        func markWriterUnknown(_ fence: Int) {
            try? store.markWriterUnknown(fence: fence)
            if let terminal = terminalLease, terminal.fence == fence {
                try? store.toolFinished(terminal.call, outcome: WorkspaceStore.unknownOutcome)
                terminalLease = nil
            }
        }
    }
}
