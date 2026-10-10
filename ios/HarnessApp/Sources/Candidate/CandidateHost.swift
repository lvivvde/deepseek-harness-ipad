import Foundation
import HarnessHost
import LinuxPlugin
import ModelGateway
import NativeTools
import NativeWorkspace

/// The candidate App's single authority behind the official Worker: projects, their native tools, the
/// Linux plugin bound to one project, the model stream and the Worker home checkpoint. `handle` takes
/// one bridge request and answers with a JSON object: `{"error": code}` for a refusal, `{"failure":
/// {code, detail}}` for a tool error the Worker maps, otherwise the operation's own fields.
public final class CandidateHost: @unchecked Sendable {
    public static let gitScriptNames = ["native-git-objects.js", "native-git-match.js", "native-git-xdiff.js", "native-git.js"]
    public static let homeCheckpoint = "worker-home.json"
    public static let diagnosticRecord = "linux-diagnostic.json"
    static let maxCommandTimeoutMs = 600_000
    static let workerCredentials = "/dsh/home/.credentials.yaml"

    public let registry: ProjectRegistry
    private let machine: GuestMachine
    private let gitScripts: [(name: String, source: String)]
    private let model: ModelGateway?
    private let readyTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private(set) var plugin: LinuxPlugin!

    private struct Open { let project: CandidateProject; let gateway: ProjectGateway; let tools: ProjectTools }
    /// Guards `open`, `operations`, `pendingCancels`, `terminals`, `stopping` and `diagnostic`. Never held while a
    /// gateway, the plugin or the guest is called.
    private let lock = NSLock()
    private var open: [String: Open] = [:]
    /// Operation id → project id, for cancellation.
    private var operations: [String: String] = [:]
    /// Cancellations that arrived before their command.
    private var pendingCancels = Set<String>()
    /// Terminal id → project id; the guest knows the terminal by the same id.
    private var terminals: [String: String] = [:]
    /// The launcher stopped the VM itself; its exit must not replace the preparation failure's cause.
    private var stopping = false
    private var diagnostic: LinuxPlugin.Diagnostic?

    public init(registry: ProjectRegistry, machine: GuestMachine, availability: LinuxAvailability = .detect(),
                gitScripts: [(name: String, source: String)], model: ModelGateway? = nil,
                readyTimeout: TimeInterval = 600, pollInterval: TimeInterval = 0.25) {
        self.registry = registry; self.machine = machine; self.gitScripts = gitScripts; self.model = model
        self.readyTimeout = readyTimeout; self.pollInterval = pollInterval
        let record = registry.root + "/" + Self.diagnosticRecord
        diagnostic = FileManager.default.contents(atPath: record).flatMap { try? JSONDecoder().decode(LinuxPlugin.Diagnostic.self, from: $0) }
        plugin = LinuxPlugin(availability: availability, launcher: { [weak self] in
            guard let self else { throw LinuxPlugin.LaunchFailure("HOST_CLOSED") }
            try launch($0)
        }, diagnostics: { [weak self] in self?.save($0) })
        machine.onExit = { [weak self] in self?.vmExited($0) }
    }

    public func handle(_ body: [String: Any]) -> [String: Any] {
        do {
            switch body["operation"] as? String {
            case "projects": return ["projects": projects()]
            case "project-create":
                guard let name = body["name"] as? String, let enabled = body["pluginEnabled"] as? Bool else { throw CandidateError("PROJECT_REFUSED") }
                return ["project": entry(try registry.create(name: name, pluginEnabled: enabled))]
            case "project-open":
                guard let id = body["id"] as? String, let project = registry.project(id) else { throw CandidateError("PROJECT_UNKNOWN") }
                return ["project": entry(try openProject(project))]
            case "status": return status()
            case "fs": return try tool { try tools(at: argument(body, "path"), missing: "FS_NOT_FOUND").file(body["method"] as? String ?? "", arguments(body)) }
            case "path": return try tool { try tools(at: argument(body, "path"), missing: "ENOENT").path(body["method"] as? String ?? "", arguments(body)) }
            case "spawn": return try tool { try tools(at: argument(body, "cwd"), missing: "ENOENT").spawn(arguments(body)) }
            case "image": return try tool { try ProjectTools.image(body["method"] as? String ?? "", arguments(body)) }
            case "execute": return try execute(body)
            case "cancel":
                guard let id = body["operationId"] as? String else { throw CandidateError("ID_REFUSED") }
                return ["status": cancel(id)]
            case "terminal-open": return try terminalOpen(body)
            case "terminal-write": return try terminalWrite(body)
            case "terminal-read": return try terminalRead(body)
            case "terminal-resize":
                let (id, gateway) = try terminal(body)
                try terminalCall { try gateway.resizeTerminal(id, cols: body["cols"] as? Int ?? 0, rows: body["rows"] as? Int ?? 0) }
                return [:]
            case "terminal-signal":
                let (id, gateway) = try terminal(body)
                return ["processGroupId": try terminalCall { try gateway.signalTerminal(id, signal: body["signal"] as? String ?? "") }]
            case "terminal-inspect":
                let (id, gateway) = try terminal(body)
                let inspected = try terminalCall { try gateway.inspectTerminal(id) }
                return ["foreground": inspected.foreground.map { ["processGroupId": $0.processGroupId, "inputWaiting": $0.inputWaiting] } as Any? ?? NSNull(),
                        "activity": Self.activity(inspected.activity)]
            case "terminal-close": return try terminalClose(body)
            case "terminals-reset": return terminalsReset()
            case "writer-release":
                guard let id = body["id"] as? String, let gateway = opened(id)?.gateway else { throw CandidateError("PROJECT_UNKNOWN") }
                return ["status": Self.name(gateway.releaseUnknownWriter())]
            case "model-open": return modelOpen(body)
            case "model-read": return modelRead(body)
            case "model-cancel":
                if let id = body["streamId"] as? String { model?.cancel(id) }
                return ["cancelled": true]
            case "checkpoint": return try checkpoint(body["snapshot"])
            case "restore":
                guard let data = FileManager.default.contents(atPath: registry.root + "/" + Self.homeCheckpoint) else { return ["snapshot": NSNull()] }
                return ["snapshot": try JSONSerialization.jsonObject(with: data)]
            default: throw CandidateError("OPERATION_REFUSED")
            }
        } catch let error as CandidateError {
            return ["error": error.code]
        } catch {
            return ["error": "HOST_FAILED"]
        }
    }

    // MARK: Projects

    private func opened(_ id: String) -> Open? { lock.lock(); defer { lock.unlock() }; return open[id] }

    /// Opening never waits for Linux: a plugin project starts its preparation in the background.
    private func openProject(_ project: CandidateProject) throws -> CandidateProject {
        if opened(project.id) == nil {
            let store = try WorkspaceStore(workspace: registry.workspace(project), state: registry.state(project))
            let gateway = ProjectGateway(project: project.id, store: store, plugin: plugin, rpc: machine.rpc)
            let tools = try ProjectTools(gateway: gateway, workspace: registry.workspace(project), mount: project.mount,
                                         scratch: registry.scratch, gitScripts: gitScripts)
            lock.lock()
            if open[project.id] == nil { open[project.id] = Open(project: project, gateway: gateway, tools: tools) }
            lock.unlock()
        }
        plugin.open(project: project.id, pluginEnabled: project.pluginEnabled)
        return project
    }

    private func projects() -> [[String: Any]] { registry.projects.map(entry) }

    /// `writerUnknown`: a Linux writer this project cannot confirm stopped holds the lease, so native
    /// writes become drafts until the user releases it (`writer-release`).
    private func entry(_ project: CandidateProject) -> [String: Any] {
        let gateway = opened(project.id)?.gateway
        let isOpen = gateway != nil
        var value: [String: Any] = ["id": project.id, "name": project.name, "pluginEnabled": project.pluginEnabled,
                                    "mount": project.mount, "open": isOpen, "writerUnknown": gateway?.lease?.state == .writerUnknown]
        let phase = plugin.phase(of: project.id)
        value["phase"] = Self.name(phase)
        switch phase {
        case .failed(let reason), .unavailable(let reason): value["reason"] = reason
        default: break
        }
        if isOpen { value["capabilities"] = Self.candidateDeclaration(plugin.declaration(project: project.id)) }
        return value
    }

    /// Where the candidate falls short of the formal scope, declared instead of hidden. A narrower path
    /// qualifies an item that is available; hooks run on Linux, but the official web profile loads no hook plugin.
    static let narrower = ["git.write": "SHELL_ONLY", "subprocess": "BASH_C_ONLY", "hook.command": "NO_OFFICIAL_CALLER"]

    static func candidateDeclaration(_ declaration: CapabilityDeclaration) -> [String: Any] {
        var value = json(declaration) as? [String: Any] ?? [:]
        var items = value["items"] as? [[String: Any]] ?? []
        for index in items.indices {
            if let narrower = narrower[items[index]["name"] as? String ?? ""], items[index]["available"] as? Bool == true {
                items[index]["reason"] = narrower
            }
        }
        // The terminal runs where shell commands run; it holds the write lease only while a command runs in it.
        if var terminal = items.first(where: { $0["name"] as? String == "shell" }) {
            terminal["name"] = "terminal"
            if terminal["available"] as? Bool == true { terminal["reason"] = "WRITE_LEASE_WHILE_BUSY" }
            items.append(terminal)
        }
        value["items"] = items
        return value
    }

    private func status() -> [String: Any] {
        lock.lock(); let record = diagnostic; lock.unlock()
        let availability: String
        switch plugin.availability {
        case .available: availability = "AVAILABLE"
        case .unavailable(let reason): availability = reason.rawValue
        }
        return ["linux": availability, "boundProject": plugin.boundProject as Any? ?? NSNull(),
                "projects": projects(), "diagnostic": record.map(Self.json) ?? NSNull()]
    }

    static func name(_ phase: LinuxPlugin.Phase) -> String {
        switch phase {
        case .disabled: return "DISABLED"
        case .preparing: return "PREPARING"
        case .ready: return "READY"
        case .failed: return "FAILED"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    // MARK: Native tools

    /// The open project whose mount holds `path`. The shared scratch and the directories above the
    /// mounts are served by any open project's path space.
    private func tools(at path: String, missing: String) throws -> ProjectTools {
        lock.lock(); defer { lock.unlock() }
        if let match = open.values.first(where: { path == $0.project.mount || path.hasPrefix($0.project.mount + "/") }) { return match.tools }
        guard !path.hasPrefix("/dsh/workspace/"), let any = open.values.min(by: { $0.project.name < $1.project.name }) else {
            throw ToolError(missing, "no open project")
        }
        return any.tools
    }

    private func arguments(_ body: [String: Any]) -> [String: Any] { body["args"] as? [String: Any] ?? [:] }
    private func argument(_ body: [String: Any], _ key: String) -> String { arguments(body)[key] as? String ?? "" }

    private func tool(_ work: () throws -> Any) throws -> [String: Any] {
        do { return ["value": try work()] } catch let error as ToolError {
            return ["failure": ["code": error.code, "detail": error.detail]]
        }
    }

    // MARK: Linux

    /// Runs one command on Linux in the project whose mount holds `cwd`. The command is never retried,
    /// here or natively.
    private func execute(_ body: [String: Any]) throws -> [String: Any] {
        guard let id = body["operationId"] as? String, (1...128).contains(id.utf8.count),
              let command = body["command"] as? String, command.utf8.count <= 256 * 1024,
              let cwd = body["cwd"] as? String,
              let timeout = body["timeoutMs"] as? Int, (1...Self.maxCommandTimeoutMs).contains(timeout) else {
            throw CandidateError("COMMAND_REFUSED")
        }
        let task: LinuxPlugin.Task
        switch body["trigger"] as? String ?? "shell" {
        case "shell": task = .shell(command)
        case "hook": task = .hook(command)
        case "git": task = .git(command)
        default: throw CandidateError("COMMAND_REFUSED")
        }
        lock.lock()
        if pendingCancels.remove(id) != nil { lock.unlock(); return ["status": "CANCELLED_BEFORE_DISPATCH"] }
        guard let (target, guestCwd) = locate(cwd) else { lock.unlock(); return ["status": "REFUSED", "reason": "CWD_REFUSED"] }
        guard operations[id] == nil else { lock.unlock(); return ["status": "REFUSED", "reason": "DUPLICATE_OPERATION"] }
        operations[id] = target.project.id
        lock.unlock()
        switch target.gateway.execute(id, task: task, argv: ["/bin/sh", "-c", command], timeoutMs: timeout, cwd: guestCwd) {
        case .completed(let result, _), .joined(let result): return Self.result(result).merging(["status": "COMPLETED"]) { $1 }
        case .refused(let code): return ["status": "REFUSED", "reason": code]
        case .cancelledBeforeDispatch: return ["status": "CANCELLED_BEFORE_DISPATCH"]
        case .writerUnknown(let result): return (result.map(Self.result) ?? [:]).merging(["status": "WRITER_UNKNOWN"]) { $1 }
        }
    }

    // MARK: Terminal

    /// Opens a pty shell in the project whose mount holds `cwd`. Its view of the workspace is read-only
    /// until a line is run in it.
    private func terminalOpen(_ body: [String: Any]) throws -> [String: Any] {
        guard let id = body["terminalId"] as? String, (1...128).contains(id.utf8.count),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let cwd = body["cwd"] as? String, let argv = body["argv"] as? [String], !argv.isEmpty,
              let cols = body["cols"] as? Int, let rows = body["rows"] as? Int else { throw CandidateError("TERMINAL_REFUSED") }
        lock.lock()
        guard let (target, guestCwd) = locate(cwd) else { lock.unlock(); throw CandidateError("CWD_REFUSED") }
        guard terminals[id] == nil else { lock.unlock(); throw CandidateError("DUPLICATE_TERMINAL") }
        terminals[id] = target.project.id
        lock.unlock()
        do {
            return ["pid": try target.gateway.openTerminal(id, argv: argv, cwd: guestCwd, cols: cols, rows: rows,
                                                           env: body["env"] as? [String: String] ?? [:],
                                                           terminalType: body["terminalType"] as? String)]
        } catch let error as TerminalError {
            // A start the guest may have half made stays tracked until a close confirms it is gone.
            if error.code != "GUEST_UNREACHABLE" || Self.closed(id, target.gateway) {
                lock.lock(); terminals[id] = nil; lock.unlock()
            }
            throw CandidateError(error.code)
        }
    }

    private func terminalWrite(_ body: [String: Any]) throws -> [String: Any] {
        let (id, gateway) = try terminal(body)
        guard let text = body["data"] as? String, let data = Data(base64Encoded: text), data.count <= 48 * 1024 else {
            throw CandidateError("WRITE_REFUSED")
        }
        switch gateway.writeTerminal(id, data) {
        case .written(let leased): return ["status": "WRITTEN", "leased": leased]
        case .refused(let code): return ["status": "REFUSED", "reason": code]
        case .writerUnknown: return ["status": "WRITER_UNKNOWN"]
        }
    }

    /// Long-polls output; `released` says the terminal's lease ended with this read.
    private func terminalRead(_ body: [String: Any]) throws -> [String: Any] {
        let (id, gateway) = try terminal(body)
        let wait = min(max(body["waitMs"] as? Int ?? 0, 0), 20_000)
        let read = try terminalCall { try gateway.readTerminal(id, offset: body["offset"] as? Int ?? 0, waitMs: wait) }
        return ["data": read.data.base64EncodedString(), "next": read.next, "dropped": read.dropped,
                "exited": read.exited.map { ["code": $0.code as Any? ?? NSNull(), "signal": $0.signal as Any? ?? NSNull()] } as Any? ?? NSNull(),
                "activity": Self.activity(read.activity), "leased": read.leased, "released": read.release != nil]
    }

    /// The terminal stays tracked when the guest cannot confirm its lease ended.
    private func terminalClose(_ body: [String: Any]) throws -> [String: Any] {
        let (id, gateway) = try terminal(body)
        let release = try terminalCall { try gateway.closeTerminal(id, graceMs: min(max(body["graceMs"] as? Int ?? 1000, 0), 5000)) }
        lock.lock(); terminals[id] = nil; lock.unlock()
        return ["closed": true, "released": release != nil]
    }

    /// A new Worker closes the terminals an earlier one left open; `remaining` could not be closed yet.
    private func terminalsReset() -> [String: Any] {
        lock.lock(); let left = terminals.compactMap { id, project in open[project].map { (id, $0.gateway) } }; lock.unlock()
        var remaining: [String] = []
        for (id, gateway) in left {
            if Self.closed(id, gateway) { lock.lock(); terminals[id] = nil; lock.unlock() } else { remaining.append(id) }
        }
        return ["closed": left.count - remaining.count, "remaining": remaining.sorted()]
    }

    private static func closed(_ id: String, _ gateway: ProjectGateway) -> Bool {
        do { try gateway.closeTerminal(id, graceMs: 0); return true } catch { return false }
    }

    private func terminal(_ body: [String: Any]) throws -> (String, ProjectGateway) {
        lock.lock(); defer { lock.unlock() }
        guard let id = body["terminalId"] as? String, let project = terminals[id], let gateway = open[project]?.gateway else {
            throw CandidateError("TERMINAL_NOT_FOUND")
        }
        return (id, gateway)
    }

    private func terminalCall<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch let error as TerminalError { throw CandidateError(error.code) }
    }

    private static func activity(_ activity: TerminalActivity) -> [String: Any] {
        ["state": activity.state, "revision": activity.revision]
    }

    /// Caller holds `lock`. Maps a Worker path inside an open project to the guest's `/workspace`.
    private func locate(_ cwd: String) -> (Open, String)? {
        for candidate in open.values {
            let mount = candidate.project.mount
            if cwd == mount { return (candidate, "/workspace") }
            if cwd.hasPrefix(mount + "/") { return (candidate, "/workspace" + cwd.dropFirst(mount.count)) }
        }
        return nil
    }

    private static func result(_ result: CommandResult) -> [String: Any] {
        ["exitCode": result.exitCode as Any? ?? NSNull(), "signal": result.signal as Any? ?? NSNull(),
         "stdout": result.stdout, "stderr": result.stderr, "timedOut": result.timedOut, "cancelled": result.cancelled]
    }

    private func cancel(_ id: String) -> String {
        lock.lock()
        guard let project = operations[id], let gateway = open[project]?.gateway else {
            pendingCancels.insert(id); lock.unlock(); return "CANCELLED_BEFORE_DISPATCH"
        }
        lock.unlock()
        switch gateway.cancel(id) {
        case .cancelledBeforeDispatch: return "CANCELLED_BEFORE_DISPATCH"
        case .requested: return "CANCEL_REQUESTED"
        case .writerUnknown: return "WRITER_UNKNOWN"
        case .finished: return "FINISHED"
        }
    }

    static func name(_ release: UnknownWriterRelease) -> String {
        switch release {
        case .released: return "RELEASED"
        case .stillRunning: return "STILL_RUNNING"
        case .unreachable: return "UNREACHABLE"
        case .noUnknownWriter: return "NO_UNKNOWN_WRITER"
        case .storeFailed: return "STORE_FAILED"
        }
    }

    /// The plugin's launcher: marks the native workspace with the project identity, then boots, proves ready,
    /// binds and checks the mount. Any failure stops the VM.
    private func launch(_ id: String) throws {
        guard let target = opened(id) else { throw LinuxPlugin.LaunchFailure("PROJECT_NOT_OPEN") }
        let workspace = registry.workspace(target.project)
        do { try Self.writeIdentity(id, workspace) } catch { throw LinuxPlugin.LaunchFailure("IDENTITY_WRITE_FAILED") }
        let rpc = machine.rpc
        try LinuxBringUp(rpc: rpc, boot: { [machine] _ in try machine.boot(workspace: workspace) },
                         exited: { [machine] in machine.exited }, attach: target.gateway.attach,
                         check: MountCheck(rpc: rpc, workspace: workspace, project: id).verify,
                         stop: { [self] in
                             lock.lock(); stopping = true; lock.unlock()
                             machine.stop()
                         },
                         readyTimeout: readyTimeout, pollInterval: pollInterval).launch(id)
    }

    /// The App is quitting: the VM must not outlive it, and its exit is not a Linux failure.
    public func shutdown() {
        lock.lock(); stopping = true; lock.unlock()
        machine.stop()
    }

    /// The guest agent's identity: `/workspace/.plan500-identity`, readable by its unprivileged reader.
    static func writeIdentity(_ id: String, _ workspace: String) throws {
        let path = workspace + "/" + String(decoding: WorkspaceFiles.guestIdentity, as: UTF8.self)
        try ProjectRegistry.durableWrite(Data(id.utf8), to: path, mode: 0o644)
    }

    private func vmExited(_ status: Int32?) {
        let bound = plugin.boundProject
        lock.lock()
        let ignore = stopping
        let gateway = bound.flatMap { open[$0]?.gateway }
        lock.unlock()
        guard !ignore else { return }
        lock.lock(); terminals.removeAll(); lock.unlock()
        if let gateway { gateway.guestExited(status: status) } else { plugin.vmExited(status: status) }
    }

    /// Saved before the failure is published, so the record survives the App being closed at once.
    private func save(_ record: LinuxPlugin.Diagnostic) {
        if let data = try? JSONEncoder().encode(record) {
            try? ProjectRegistry.durableWrite(data, to: registry.root + "/" + Self.diagnosticRecord)
        }
        lock.lock(); diagnostic = record; lock.unlock()
    }

    // MARK: Model

    private static func failure(_ error: Error) -> [String: Any] {
        ["failure": (error as? ModelFailure)?.rawValue ?? ModelFailure.transport.rawValue]
    }

    /// Opens one streamed request. Failures come back as fixed codes so the Worker's own error path classifies them.
    private func modelOpen(_ body: [String: Any]) -> [String: Any] {
        guard let model, let id = body["streamId"] as? String, (1...64).contains(id.utf8.count), let url = body["url"] as? String,
              let text = body["body"] as? String, text.utf8.count <= 8 << 20 else {
            return ["failure": "MODEL_REQUEST_REFUSED"]
        }
        let headers = (body["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        do {
            let head = try model.open(id: id, url: url, headers: headers, body: Data(text.utf8))
            return ["status": head.status, "headers": head.headers]
        } catch { return Self.failure(error) }
    }

    private func modelRead(_ body: [String: Any]) -> [String: Any] {
        guard let model, let id = body["streamId"] as? String else { return ["failure": ModelFailure.unknownStream.rawValue] }
        do {
            switch try model.read(id) {
            case .chunk(let data): return ["chunk": data.base64EncodedString()]
            case .end: return ["done": true]
            }
        } catch { return Self.failure(error) }
    }

    // MARK: Worker home

    /// The Worker's home survives a restart; project files never enter it.
    private func checkpoint(_ value: Any?) throws -> [String: Any] {
        guard let snapshot = value as? [String: Any], snapshot["formatVersion"] as? Int == 1,
              let files = snapshot["files"] as? [[String: Any]], let directories = snapshot["directories"] as? [[String: Any]] else {
            throw CandidateError("SNAPSHOT_REFUSED")
        }
        for item in files + directories {
            guard let path = item["path"] as? String, path == "/dsh/home" || path.hasPrefix("/dsh/home/"),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw CandidateError("HOME_ONLY_CHECKPOINT")
            }
            // The model key stays native; the Worker's own credentials file holds only a placeholder.
            if path.hasPrefix(Self.workerCredentials) { throw CandidateError("CREDENTIALS_NOT_CHECKPOINTED") }
        }
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        do { try ProjectRegistry.durableWrite(data, to: registry.root + "/" + Self.homeCheckpoint) } catch { throw CandidateError("CHECKPOINT_FAILED") }
        return ["durable": true]
    }

    static func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? NSNull()
    }
}
