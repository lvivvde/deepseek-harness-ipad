// Research-only tool bridge. Native workspace is authoritative; no VFS workspace copy is saved.
import Darwin
import Foundation
import Network
import WebKit
#if os(iOS)
import UIKit
#endif
#if canImport(LinuxPlugin)
import LinuxPlugin
#endif
#if canImport(ModelGateway)
import ModelGateway
#endif

private enum WorkerBridgeError: Error { case refused(String) }

/// The real key, read only by the gateway when it builds a request. Never logged, returned or given to the Worker.
private final class ModelKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return key }
    func set(_ value: String) { lock.lock(); key = value; lock.unlock() }
}

final class WorkerCoordinator: @unchecked Sendable {
    let probe: ResearchProbe
    let gateway: Gateway
    /// Research-only: the missing branch of #39 gate 2 forced by a launch argument of this separate app.
    let injectedMissingPrivateSymbol: Bool
    /// Real detection on this process, recorded even when the research run injects the missing branch.
    let detectedAvailability = LinuxAvailability.detect()
    private(set) var plugin: LinuxPlugin!
    private let condition = NSCondition()
    private let execution = NSLock()
    private var pluginEnabled = true
    private var operations: [String: String] = [:]
    private var cancelled = Set<String>()
    /// #39 gate 4: streams model requests to the official endpoint; the Worker parses, retries and cancels.
    let model: ModelGateway
    private let modelKey: ModelKeyBox
    private var modelRequests = 0
    static let modelRequestBudget = 40
    /// Fixed, obviously invalid key for the invalid-key and offline checks; never a user's key.
    static let invalidModelKey = "sk-plan500-gate4-invalid-key"
#if !canImport(ModelGateway)
    /// macOS host build only (one module with the gateway sources): the local fault-injection server.
    nonisolated(unsafe) static var modelFaultTarget: URL?
#endif
    private var readyProof: [String: Any]?
    /// #39 gate 3: the synthetic native project the official file, search and change tools run over.
    var gate3: Gate3Tools?

    /// Availability is detected here, at App start and before any Linux preparation.
    init(probe: ResearchProbe, injectMissingPrivateSymbol: Bool = false) throws {
        self.probe = probe
        injectedMissingPrivateSymbol = injectMissingPrivateSymbol
        gateway = try Gateway(workspace: probe.workspace.path, state: probe.state.path,
                              identity: probe.identity, transport: probe.transport)
        let key = ModelKeyBox()
        modelKey = key
#if canImport(ModelGateway)
        model = ModelGateway { key.value }
#else
        model = Self.modelFaultTarget.map { ModelGateway(target: $0, idleTimeout: 2, key: { key.value }) } ?? ModelGateway { key.value }
#endif
        let availability = injectMissingPrivateSymbol ? LinuxAvailability.detect { _ in false } : detectedAvailability
        plugin = LinuxPlugin(availability: availability) { [unowned self] in try bringUpLinux() }
    }

    /// True only in the macOS host run against the local fault server.
    var modelFaultInjection: Bool { model.target != ModelGateway.officialURL }

    func status() -> [String: Any] {
        let phase = plugin.phase
        condition.lock(); defer { condition.unlock() }
        let state = gateway.snapshot().0
        let declaration = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(plugin.declaration(pluginEnabled: pluginEnabled)))) ?? NSNull()
        return ["phase": Self.name(phase), "operations": operations, "identity": probe.identity,
                "ready": readyProof != nil, "lease": state.lease?.op as Any? ?? NSNull(),
                "drafts": state.drafts.map { ["id": $0.id, "status": $0.status, "path": $0.path.json] },
                "pluginEnabled": pluginEnabled, "capabilities": declaration, "vmStarts": vmStartCount,
                "linuxAvailability": Self.name(plugin.availability),
                "linuxAvailabilityDetected": Self.name(detectedAvailability),
                "injectedMissingPrivateSymbol": injectedMissingPrivateSymbol]
    }

    static func name(_ phase: LinuxPlugin.Phase) -> String {
        switch phase {
        case .cold: return "COLD"
        case .preparing: return "PREPARING"
        case .ready: return "READY"
        case .failed: return "FAILED"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    static func name(_ availability: LinuxAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .unavailable(let reason): return reason.rawValue
        }
    }

    var vmStartCount: Int { probe.vmLock.lock(); defer { probe.vmLock.unlock() }; return probe.vmStarts }

    func prepare() { plugin.prepare() }

    /// The plugin's only launcher: start QEMU once, wait for the verified 9P ready proof, bind the gateway.
    private func bringUpLinux() throws {
        do {
            try probe.startVM()
            let deadline = Date().addingTimeInterval(600)
            var proof: [String: Any]?
            while Date() < deadline {
                probe.vmLock.lock(); let exited = probe.vmExited; probe.vmLock.unlock()
                if exited { throw WorkerBridgeError.refused("VM_EXIT_BEFORE_READY") }
                if let value = try? probe.transport.rpc("/ready", nil) { proof = value; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let proof, proof["projectId"] as? String == probe.identity,
                  proof["protocol"] as? Int == 1, proof["mount"] as? String == "9p",
                  proof["workspaceReadOnly"] as? Bool == true, proof["cgroupKill"] as? Bool == true else {
                throw WorkerBridgeError.refused("READY_PROOF_REFUSED")
            }
            // Binding never grants a writer. A new guest must know the durable epoch
            // before it can revoke an old fence; an existing active writer still refuses revoke.
            _ = try gateway.attach()
            if gateway.snapshot().0.lease != nil {
                guard try gateway.reconcile(vmExited: false)["status"] as? String == "RELEASED" else {
                    throw WorkerBridgeError.refused("WRITER_NOT_RECONCILED")
                }
            }
            condition.lock(); readyProof = proof; condition.unlock()
        } catch {
            try? String(describing: error).write(to: probe.root.appendingPathComponent("worker-error-private.log"), atomically: true, encoding: .utf8)
            throw error
        }
    }

    func execute(id: String, command: String, timeout: Int, hook: Bool = false) throws -> [String: Any] {
        guard !id.isEmpty, id.count <= 128, command.utf8.count <= 32000,
              timeout > 0, timeout <= 30000 else { throw WorkerBridgeError.refused("COMMAND_REFUSED") }
        condition.lock()
        guard operations[id] == nil else { condition.unlock(); throw WorkerBridgeError.refused("DUPLICATE_OPERATION") }
        operations[id] = "WAITING_READY"; let enabled = pluginEnabled; condition.unlock()
        // Lock order: plugin, then coordinator. Never call the plugin while holding `condition`.
        let admission = plugin.admit(hook ? .hook(command) : .shell(command), pluginEnabled: enabled) { [self] in
            condition.lock(); defer { condition.unlock() }; return cancelled.contains(id)
        }
        switch admission {
        case .linux: break
        case .cancelledBeforeDispatch:
            condition.lock(); operations[id] = "CANCELLED_BEFORE_DISPATCH"; condition.unlock()
            return ["status": "CANCELLED_BEFORE_DISPATCH"]
        case .refused(let reason):
            condition.lock(); operations[id] = "UNAVAILABLE"; condition.broadcast(); condition.unlock()
            return ["status": "UNAVAILABLE", "reason": reason]
        case .native:
            condition.lock(); operations[id] = "FAILED"; condition.unlock()
            throw WorkerBridgeError.refused("PATH_REFUSED")
        }
        execution.lock(); defer { execution.unlock() }
        condition.lock()
        if cancelled.contains(id) {
            operations[id] = "CANCELLED_BEFORE_DISPATCH"; condition.unlock()
            return ["status": "CANCELLED_BEFORE_DISPATCH"]
        }
        operations[id] = "DISPATCHING"; condition.unlock()
        let answer: [String: Any]
        do { answer = try gateway.runLeased(id, argv: ["/bin/sh", "-c", command], timeout: timeout) }
        catch {
            condition.lock(); operations[id] = "FAILED"; condition.broadcast(); condition.unlock(); throw error
        }
        condition.lock(); operations[id] = answer["status"] as? String ?? "FAILED"; condition.broadcast(); condition.unlock()
        return answer
    }

    func cancel(id: String) throws -> [String: Any] {
        condition.lock()
        guard let current = operations[id] else {
            cancelled.insert(id); condition.broadcast(); condition.unlock()
            return ["status": "CANCEL_REQUESTED"]
        }
        cancelled.insert(id); condition.broadcast(); condition.unlock()
        plugin.wake()
        if current == "WAITING_READY" { return ["status": "CANCEL_REQUESTED"] }
        // Cancellation can race acquire or the guest accepting /execute. Keep retrying only
        // this idempotent cancellation, never /execute, until completion or confirmed drain.
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            condition.lock(); let phase = operations[id]; condition.unlock()
            if phase != "DISPATCHING" { return ["status": phase ?? "NOT_FOUND"] }
            if gateway.snapshot().0.lease?.op == id,
               let answer = try? probe.transport.rpc("/cancel", ["id": id]), answer["cancelled"] as? Bool == true {
                return ["status": "CANCEL_REQUESTED"]
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return ["status": "WRITER_UNKNOWN"] // Caller must keep the lease; no release here.
    }

    func setModelKey(_ key: String) {
        modelKey.set(key)
        condition.lock(); modelRequests = 0; condition.unlock()
    }

    private static func failure(_ error: Error) -> [String: Any] {
        ["failure": (error as? ModelFailure)?.rawValue ?? ModelFailure.transport.rawValue]
    }

    /// Opens one streamed request. Failures come back as fixed codes so the Worker's own error path classifies them.
    private func modelOpen(_ body: [String: Any]) -> [String: Any] {
        guard let id = body["streamId"] as? String, (1...64).contains(id.utf8.count), let url = body["url"] as? String,
              let text = body["body"] as? String, text.utf8.count <= 2 << 20,
              var payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return ["failure": "MODEL_REQUEST_REFUSED"]
        }
        let headers = (body["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        condition.lock(); modelRequests += 1; let count = modelRequests; condition.unlock()
        guard count <= Self.modelRequestBudget else { return ["failure": "MODEL_BUDGET_EXHAUSTED"] }
        // Research spending cap; the request is otherwise the official adapter's own.
        payload["max_tokens"] = min(payload["max_tokens"] as? Int ?? 2048, 2048)
        do {
            let head = try model.open(id: id, url: url, headers: headers, body: try JSONSerialization.data(withJSONObject: payload))
            return ["status": head.status, "headers": head.headers]
        } catch { return Self.failure(error) }
    }

    private func modelRead(_ body: [String: Any]) -> [String: Any] {
        guard let id = body["streamId"] as? String else { return ["failure": ModelFailure.unknownStream.rawValue] }
        do {
            switch try model.read(id) {
            case .chunk(let data): return ["chunk": data.base64EncodedString()]
            case .end: return ["done": true]
            }
        } catch { return Self.failure(error) }
    }

    /// Redacted gateway evidence: per-request timings, counts and final codes only.
    func modelRecords() -> [String: Any] {
        let records = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(model.records))) ?? []
        condition.lock(); defer { condition.unlock() }
        return ["records": records, "requests": modelRequests, "faultInjection": modelFaultInjection]
    }

    func handle(_ body: [String: Any]) throws -> [String: Any] {
        guard let operation = body["operation"] as? String else { throw WorkerBridgeError.refused("OPERATION_REFUSED") }
        switch operation {
        case "model-open": return modelOpen(body)
        case "model-read": return modelRead(body)
        case "model-cancel":
            if let id = body["streamId"] as? String { model.cancel(id) }
            return ["cancelled": true]
        case "model-records": return modelRecords()
        case "gate3":
            guard let gate3 else { throw WorkerBridgeError.refused("GATE3_REFUSED") }
            return try gate3.handle(body)
        case "status": return status()
        case "prepare": prepare(); return status()
        case "read":
            guard let path = body["path"] as? String else { throw WorkerBridgeError.refused("PATH_REFUSED") }
            return try gateway.nativeRead(RelativePath(path))
        case "draft":
            guard let id = body["draft"] as? String else { throw WorkerBridgeError.refused("ID_REFUSED") }
            return try gateway.readDraft(id)
        case "write":
            guard let path = body["path"] as? String, let text = body["text"] as? String,
                  text.utf8.count <= 1 << 20 else { throw WorkerBridgeError.refused("WRITE_REFUSED") }
            return try gateway.nativeWrite(RelativePath(path), Data(text.utf8), base: body["base"] as? String)
        case "execute":
            guard let id = body["operationId"] as? String, let command = body["command"] as? String else { throw WorkerBridgeError.refused("COMMAND_REFUSED") }
            return try execute(id: id, command: command, timeout: body["timeoutMs"] as? Int ?? 15000,
                               hook: body["trigger"] as? String == "hook")
        case "project-open":
            // Research stand-in for opening a project with or without the Linux plugin enabled.
            guard let enabled = body["pluginEnabled"] as? Bool else { throw WorkerBridgeError.refused("PROJECT_REFUSED") }
            condition.lock(); pluginEnabled = enabled; condition.unlock()
            plugin.open(pluginEnabled: enabled)
            return status()
        case "cancel":
            guard let id = body["operationId"] as? String else { throw WorkerBridgeError.refused("ID_REFUSED") }
            return try cancel(id: id)
        case "checkpoint":
            guard let snapshot = body["snapshot"] as? [String: Any], snapshot["formatVersion"] as? Int == 1,
                  let files = snapshot["files"] as? [[String: Any]], let dirs = snapshot["directories"] as? [[String: Any]] else {
                throw WorkerBridgeError.refused("SNAPSHOT_REFUSED")
            }
            for entry in files + dirs {
                guard let path = entry["path"] as? String,
                      path == "/dsh/home" || path.hasPrefix("/dsh/home/"),
                      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                    throw WorkerBridgeError.refused("HOME_ONLY_CHECKPOINT")
                }
            }
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            try Workspace(root: probe.state.path).write(RelativePath("worker-home.json"), data, mode: 0o600)
            return ["durable": true]
        case "restore":
            let file = probe.state.appendingPathComponent("worker-home.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return ["snapshot": NSNull()] }
            return ["snapshot": try JSONSerialization.jsonObject(with: Data(contentsOf: file))]
        default: throw WorkerBridgeError.refused("OPERATION_REFUSED")
        }
    }
}

/// Static, loopback-only HTTP origin: WebKit module Workers need a trustworthy HTTP origin.
final class WorkerAssetServer {
    let root: URL
    let queue = DispatchQueue(label: "plan500.worker-assets")
    var listener: NWListener?
    init(root: URL) { self.root = root }
    func start(_ ready: @escaping (Result<URL, Error>) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params); self.listener = listener
        var delivered = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !delivered, let port = listener.port { delivered = true; ready(.success(URL(string: "http://127.0.0.1:\(port)/integration.html")!)) }
            case .failed(let error): if !delivered { delivered = true; ready(.failure(error)) }
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var request = accumulated; if let data { request.append(data) }
            guard request.count <= 16384, error == nil else { connection.cancel(); return }
            guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { receive(connection, request) }; return
            }
            let line = String(decoding: request[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            let assets = ["integration.html", "worker.js", "client.js", "apply-injections.js", "vfs-image.tar.gz"]
            guard line.count == 3, line[0] == "GET", let asset = assets.first(where: { line[1] == "/" + $0 }),
                  let bytes = try? Data(contentsOf: root.appendingPathComponent(asset)) else { connection.cancel(); return }
            let mime = asset.hasSuffix(".js") ? "text/javascript" : asset.hasSuffix(".html") ? "text/html; charset=utf-8" : "application/octet-stream"
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
            response.append(bytes)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    deinit { listener?.cancel() }
}

@MainActor
final class WorkerWebHost: NSObject, WKScriptMessageHandler {
    let coordinator: WorkerCoordinator
    let assets: WorkerAssetServer
    let resume: Bool
    /// macOS host only: run the gate 3 suite instead of the base checks.
    let gate3: Bool
    let completion: (Bool) -> Void
    var view: WKWebView!
    /// Gate 4 records whether the App left the foreground during a model run; it does not decide the result.
    private var backgroundTransitions = 0
    private var observer: NSObjectProtocol?
    init(coordinator: WorkerCoordinator, webRoot: URL, resume: Bool, gate3: Bool = false, completion: @escaping (Bool) -> Void) {
        self.coordinator = coordinator; assets = WorkerAssetServer(root: webRoot); self.resume = resume; self.gate3 = gate3; self.completion = completion
        coordinator.gate3 = Gate3Tools(root: coordinator.probe.root.appendingPathComponent("gate3"), web: webRoot)
        super.init()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
#if os(macOS)
        // The macOS host window is never shown. Without this, WebKit treats the page as hidden and stalls
        // long Worker timers such as the official retry backoff. KVC reaches the `_set…` WebKit setters.
        for key in ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageDOMTimerThrottlingAutoIncreases",
                    "pageVisibilityBasedProcessSuppressionEnabled"] { config.preferences.setValue(false, forKey: key) }
#endif
        config.userContentController.add(self, name: "native")
        config.userContentController.add(self, name: "log")
        config.userContentController.addUserScript(WKUserScript(source: "window.plan500Resume = \(resume); window.plan500Gate2Missing = \(coordinator.injectedMissingPrivateSymbol); window.plan500Gate4 = \(coordinator.modelFaultInjection); window.plan500Gate3 = \(gate3);",
                                                                 injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view = WKWebView(frame: .zero, configuration: config)
#if os(iOS)
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.backgroundTransitions += 1 }
        }
#endif
    }
    func start() throws {
        try assets.start { [weak self] answer in
            DispatchQueue.main.async {
                guard let self else { return }
                switch answer {
                case .success(let url): self.view.load(URLRequest(url: url))
                case .failure: self.completion(false)
                }
            }
        }
    }
    func runModel(key: String) {
        coordinator.setModelKey(key)
        view.evaluateJavaScript("void window.plan500RunModel()") { [weak self] _, error in
            if error != nil { self?.coordinator.setModelKey(""); self?.completion(false) }
        }
    }
    static let gate4Modes = ["stream", "invalid-key", "offline"]
    /// Gate 4 device checks. Only "stream" uses the user's key; the others use the fixed invalid key.
    func runGate4(mode: String, key: String) {
        guard Self.gate4Modes.contains(mode) else { completion(false); return }
        coordinator.setModelKey(mode == "stream" ? key : WorkerCoordinator.invalidModelKey)
        backgroundTransitions = 0
        view.evaluateJavaScript("void window.plan500RunGate4Device('\(mode)')") { [weak self] _, error in
            if error != nil { self?.coordinator.setModelKey(""); self?.completion(false) }
        }
    }
    /// Gate 3 device check: the official tools over the native project, then one real model turn with the user's key.
    func runGate3(key: String) {
        coordinator.setModelKey(key)
        backgroundTransitions = 0
        view.evaluateJavaScript("void window.plan500RunGate3Device()") { [weak self] _, error in
            if error != nil { self?.coordinator.setModelKey(""); self?.completion(false) }
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        if message.name == "log" {
            if let step = body["progress"] as? String { print("PROGRESS " + step.prefix(200)); return }
            // Bounded diagnostics stay in the ignored/private research container, never UI or console.
            if let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 65536 {
                try? data.write(to: coordinator.probe.root.appendingPathComponent("worker-diagnostics-private.log"), options: .atomic)
            }
            return
        }
        guard message.name == "native", let id = body["id"] as? Int, let operation = body["operation"] as? String else { return }
        if operation == "model-done" || operation == "done" {
            do {
                guard var result = body["result"] as? [String: Any] else { throw WorkerBridgeError.refused("RESULT_REFUSED") }
                result["physicalDevice"] = coordinator.probe.physicalDevice; result["model"] = coordinator.probe.model
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--run-id"), args.indices.contains(index + 1) { result["runId"] = args[index + 1] }
                result["resume"] = resume; result["fullGatesPassed"] = false
                result["linuxAvailabilityDetected"] = WorkerCoordinator.name(coordinator.detectedAvailability)
                result["injectedMissingPrivateSymbol"] = coordinator.injectedMissingPrivateSymbol
                result["vmStarts"] = coordinator.vmStartCount
                result["backgroundTransitions"] = backgroundTransitions
                let gate4 = (body["gate4"] as? String).flatMap { Self.gate4Modes.contains($0) ? $0 : nil }
                let gate3Device = operation == "model-done" && body["gate3"] as? Bool == true
                let receipt = gate3Device ? "gate3-device-safe.json" : gate4.map { "gate4-\($0)-safe.json" } ?? (operation == "model-done" ? "model-safe.json"
                    : gate3 ? "gate3-safe.json" : coordinator.modelFaultInjection ? "gate4-safe.json" : coordinator.injectedMissingPrivateSymbol ? "gate2-missing-safe.json"
                    : resume ? "worker-resume-safe.json" : "worker-safe.json")
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: coordinator.probe.root.appendingPathComponent(receipt), options: .atomic)
                view.evaluateJavaScript("window.prototypeNativeReply(\(id), {accepted: true})", completionHandler: nil)
                if operation == "model-done" { coordinator.setModelKey("") }
                completion(result["passed"] as? Bool == true)
            } catch { completion(false) }
            return
        }
        let coordinator = coordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [String: Any]
            do { result = try coordinator.handle(body) }
            catch {
                try? String(describing: error).write(to: coordinator.probe.root.appendingPathComponent("bridge-error-private.log"), atomically: true, encoding: .utf8)
                result = ["error": "BRIDGE_REQUEST_FAILED"]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.view.evaluateJavaScript("window.prototypeNativeReply(\(id), \(json))", completionHandler: nil) }
        }
    }
}

#if os(iOS)
import SwiftUI

struct WorkerResearchView: View {
    @StateObject private var model = WorkerResearchModel()
    var body: some View {
        VStack(alignment: .leading) {
            Text("方案500 · Worker 与共享工作区").font(.title)
            Text(model.status)
            if model.finished {
                SecureField("DeepSeek API Key（只用于本次检查，不保存）", text: $model.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("运行真实模型修改与 Linux 测试") {
                    model.runModel(key: model.apiKey); model.apiKey = ""
                }.disabled(model.apiKey.isEmpty || model.modelRunning)
                Button("关口 4：真实流式与中途取消") {
                    model.runGate4(mode: "stream", key: model.apiKey); model.apiKey = ""
                }.disabled(model.apiKey.isEmpty || model.modelRunning)
                Button("关口 4：无效密钥（固定无效值）") { model.runGate4(mode: "invalid-key") }.disabled(model.modelRunning)
                Button("关口 4：离线（先开启飞行模式）") { model.runGate4(mode: "offline") }.disabled(model.modelRunning)
                Button("关口 3：官方文件、搜索与变更工具") {
                    model.runGate3(key: model.apiKey); model.apiKey = ""
                }.disabled(model.apiKey.isEmpty || model.modelRunning)
            }
            if let host = model.host { WorkerResearchWebView(view: host.view) }
        }.padding().task { model.start() }
    }
}

private struct WorkerResearchWebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class WorkerResearchModel: ObservableObject {
    @Published var status = "准备独立研究会话"
    @Published var host: WorkerWebHost?
    @Published var apiKey = ""
    @Published var finished = false
    @Published var modelRunning = false
    func runModel(key: String) {
        modelRunning = true; status = "真实模型检查进行中"; host?.runModel(key: key)
    }
    func runGate4(mode: String, key: String = "") {
        modelRunning = true; status = "关口 4 检查进行中：" + mode; host?.runGate4(mode: mode, key: key)
    }
    func runGate3(key: String) {
        modelRunning = true; status = "关口 3 检查进行中"; host?.runGate3(key: key)
    }
    func start() {
        guard host == nil else { return }
        do {
            let args = ProcessInfo.processInfo.arguments
            let defaults = UserDefaults.standard
            let selection: String
            if let index = args.firstIndex(of: "--model"), args.indices.contains(index + 1),
               ["none", "mapped-xattr"].contains(args[index + 1]) { selection = args[index + 1] }
            else { selection = defaults.string(forKey: "plan500.worker.model") ?? "none" }
            guard ["none", "mapped-xattr"].contains(selection) else { throw WorkerBridgeError.refused("MODEL_REFUSED") }
            let projectId: String?
            if let index = args.firstIndex(of: "--project-id"), args.indices.contains(index + 1) {
                guard let id = UUID(uuidString: args[index + 1]) else { throw WorkerBridgeError.refused("PROJECT_ID_REFUSED") }
                projectId = id.uuidString
            } else if args.contains("--model") { projectId = nil }
            else { projectId = defaults.string(forKey: "plan500.worker.project") }
            if let projectId, UUID(uuidString: projectId) == nil { throw WorkerBridgeError.refused("PROJECT_ID_REFUSED") }
            defaults.set(selection, forKey: "plan500.worker.model")
            defaults.set(projectId, forKey: "plan500.worker.project")
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let probe = try ResearchProbe(model: selection,
                projectRoot: documents.appendingPathComponent("Plan500Research/worker-" + selection + (projectId.map { "-" + $0 } ?? ""))) { _ in }
            // Research-only switch of this separate bundle; the formal App has no way to force the missing branch.
            let coordinator = try WorkerCoordinator(probe: probe, injectMissingPrivateSymbol: args.contains("--inject-missing-private-symbol"))
            let resume = !coordinator.injectedMissingPrivateSymbol && (args.contains("--resume") || FileManager.default.fileExists(atPath: probe.state.appendingPathComponent("worker-home.json").path))
            let host = WorkerWebHost(coordinator: coordinator, webRoot: Bundle.main.bundleURL.appendingPathComponent("WorkerWeb"),
                                     resume: resume) { [weak self] passed in
                // A model check result never hides the buttons that the passed base checks unlocked.
                if self?.modelRunning != true { self?.finished = passed }
                self?.modelRunning = false
                self?.status = passed ? "检查完成；详细范围见研究收据" : "检查未通过；详情见私有收据"
            }
            self.host = host
            try host.start()
            status = "官方 Worker 检查进行中"
        } catch { status = "研究启动失败；未登记通过" }
    }
}
#endif
