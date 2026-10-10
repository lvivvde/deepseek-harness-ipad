#if os(macOS)
import AppKit
#endif
import Foundation
import HarnessCandidate
import ModelGateway

/// The model key, typed by the user in this process. Read only where a model request is built; never
/// stored, logged or given to the Worker.
final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key = ""
    var value: String? { lock.lock(); defer { lock.unlock() }; return key.isEmpty ? nil : key }
    func set(_ value: String) { lock.lock(); key = value; lock.unlock() }
}

/// One row of the projects panel, decoded from the host's `projects` reply.
struct ProjectRow: Identifiable, Equatable {
    struct Capability: Equatable { let name, path: String; let available: Bool; let reason: String? }
    let id, name, mount, phase: String
    let pluginEnabled, open, writerUnknown: Bool
    let reason: String?
    let pluginState: String?
    let capabilities: [Capability]

    init?(_ entry: [String: Any]) {
        guard let id = entry["id"] as? String, let name = entry["name"] as? String, let mount = entry["mount"] as? String,
              let phase = entry["phase"] as? String, let enabled = entry["pluginEnabled"] as? Bool, let open = entry["open"] as? Bool
        else { return nil }
        self.id = id; self.name = name; self.mount = mount; self.phase = phase; pluginEnabled = enabled; self.open = open
        writerUnknown = entry["writerUnknown"] as? Bool ?? false
        reason = entry["reason"] as? String
        let declaration = entry["capabilities"] as? [String: Any]
        pluginState = (declaration?["plugin"] as? [String: Any])?["state"] as? String
        capabilities = (declaration?["items"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String, let path = $0["path"] as? String, let available = $0["available"] as? Bool else { return nil }
            return Capability(name: name, path: path, available: available, reason: $0["reason"] as? String)
        }
    }
}

/// Wires the candidate: projects under Application Support, one QEMU machine, the model gateway and
/// the official page. Linux binds to the first plugin-enabled project the user opens.
@MainActor
final class CandidateModel: ObservableObject {
    static let bundleIdentifier = "org.lvivvde.harness.candidate"

    @Published private(set) var projects: [ProjectRow] = []
    @Published private(set) var linux = "…"
    @Published private(set) var boundProject: String?
    @Published private(set) var diagnostic: String?
    @Published private(set) var failure: String?
    @Published private(set) var webStarted = false
    @Published private(set) var lastEvent: String?

    let web: CandidateWebHost?
    private let host: CandidateHost?
    private let key = KeyBox()
    private let background = DispatchQueue(label: "candidate.model", qos: .userInitiated)
    private var timer: Timer?

    init() {
        let fileManager = FileManager.default
        // A verification run may point the data root at an ignored directory; the default is the App's own.
        let root = ProcessInfo.processInfo.environment["HARNESS_CANDIDATE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Self.bundleIdentifier)
        let logs = root.appendingPathComponent("logs")
        let resources = Bundle.main.resourceURL!
        let webRoot = resources.appendingPathComponent("CandidateWeb")
        let inputs = resources.appendingPathComponent("LinuxInputs")
        var made: (CandidateHost, CandidateWebHost)?
        var failure: String?
        do {
            try fileManager.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let registry = try ProjectRegistry(root: root.path)
            let token = try String(contentsOf: inputs.appendingPathComponent("token-private"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let machine = try Self.machine(resources: resources, inputs: inputs, token: token, logs: logs)
            let scripts = try CandidateHost.gitScriptNames.map {
                (name: $0, source: try String(contentsOf: webRoot.appendingPathComponent($0), encoding: .utf8))
            }
            let box = key
            let host = CandidateHost(registry: registry, machine: machine, gitScripts: scripts,
                                     model: ModelGateway(key: { box.value }))
            made = (host, CandidateWebHost(host: host, webRoot: webRoot, logs: logs))
        } catch let error as CandidateError {
            failure = error.code
        } catch {
            failure = "CANDIDATE_SETUP_FAILED"
        }
        host = made?.0
        web = made?.1
        self.failure = failure
        web?.onEvent = { [weak self] in self?.lastEvent = $0 }
        // A device acceptance launch runs one gate 1 phase on its own project; see `Gate1Probe`.
        if let host, let phase = ProcessInfo.processInfo.environment["HARNESS_CANDIDATE_GATE1"].flatMap(Gate1Probe.Phase.init) {
            Thread.detachNewThread { Gate1Probe.run(phase, host: host) }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        #if os(macOS)
        // QEMU is a child process on macOS and would outlive the App; quitting stops it.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [host = self.host] _ in host?.shutdown()
        }
        #endif
    }

    /// Homebrew QEMU as a child process on macOS; on iPad the bundled QEMU framework inside this process,
    /// which ends with it.
    private static func machine(resources: URL, inputs: URL, token: String, logs: URL) throws -> GuestMachine {
        #if os(macOS)
        return try QemuMachine(.init(inputs: inputs.path, token: token, logs: logs.path))
        #else
        let library = Bundle.main.privateFrameworksURL!
            .appendingPathComponent("qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        return try EmbeddedMachine(.init(inputs: inputs.path, firmware: resources.appendingPathComponent("qemu").path,
                                         token: token, logs: logs.path),
                                   engine: EmbeddedMachine.library(at: library.path))
        #endif
    }

    func setKey(_ value: String) { key.set(value) }

    func create(name: String, pluginEnabled: Bool) {
        failure = nil
        call(["operation": "project-create", "name": name, "pluginEnabled": pluginEnabled]) { [weak self] _ in self?.refresh() }
    }

    /// Opening never waits for Linux. The first open loads the page; later ones are forwarded to it.
    func open(_ id: String) {
        failure = nil
        call(["operation": "project-open", "id": id]) { [weak self] reply in
            guard let self, let project = reply["project"] as? [String: Any], let web else { return }
            if webStarted {
                web.projectOpened(project)
            } else {
                webStarted = true
                web.start { [weak self] in self?.failure = $0 }
            }
            refresh()
        }
    }

    /// Only after the user confirmed: whatever the lost writer left in the workspace is kept as is.
    func releaseWriter(_ id: String) {
        failure = nil
        call(["operation": "writer-release", "id": id]) { [weak self] reply in
            if let status = reply["status"] as? String, status != "RELEASED" { self?.failure = status }
            self?.refresh()
        }
    }

    func refresh() {
        call(["operation": "status"]) { [weak self] reply in
            guard let self else { return }
            let rows = (reply["projects"] as? [[String: Any]] ?? []).compactMap(ProjectRow.init)
            if rows != projects { projects = rows }
            linux = reply["linux"] as? String ?? "…"
            boundProject = reply["boundProject"] as? String
            let record = reply["diagnostic"] as? [String: Any]
            diagnostic = record.map { "\($0["code"] as? String ?? "?") · \($0["stage"] as? String ?? "?")" }
        }
    }

    private func call(_ body: [String: Any], _ done: @escaping @MainActor ([String: Any]) -> Void) {
        guard let host else { return }
        nonisolated(unsafe) let request = body
        background.async {
            nonisolated(unsafe) let reply = host.handle(request)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let code = reply["error"] as? String { self.failure = code }
                    done(reply)
                }
            }
        }
    }
}
