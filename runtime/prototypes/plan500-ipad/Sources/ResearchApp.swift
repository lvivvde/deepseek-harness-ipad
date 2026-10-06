// PROTOTYPE: separate bundle/container, immutable system disk, synthetic workspace only.
import Darwin
import Foundation
// The same checks can run against a Mac QEMU process before the device build is installed.
#if os(iOS)
import SwiftUI

@main
struct Plan500ResearchApp: App {
    @StateObject private var model = ResearchModel()
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--durability-probe") {
                DurabilityProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("--worker-probe") ||
                (!ProcessInfo.processInfo.arguments.contains("--plan500-probe") &&
                 FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("WorkerWeb/integration.html").path)) {
                WorkerResearchView()
            } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("方案500 · iPad 研究").font(.title)
                Text("独立合成工作区；每个 App 进程只启动一次 VM。")
                Picker("9P 模式", selection: $model.securityModel) {
                    Text("none").tag("none"); Text("mapped-xattr").tag("mapped-xattr")
                }.pickerStyle(.segmented).disabled(model.started)
                Button("运行隔离检查") { model.start() }.disabled(model.started)
                Text(model.status).font(.headline)
                ScrollView { Text(model.progress).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                Text("换模式时需结束此研究 App 进程再打开。收据保存在研究 App 的 Documents 中。")
                    .font(.footnote)
            }.padding().task {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--plan500-probe") {
                    if let index = arguments.firstIndex(of: "--model"), arguments.indices.contains(index + 1),
                       ["none", "mapped-xattr"].contains(arguments[index + 1]) { model.securityModel = arguments[index + 1] }
                    model.start()
                }
            }
            }
        }
    }
}

@MainActor
final class ResearchModel: ObservableObject {
    @Published var securityModel = "none"
    @Published var started = false
    @Published var status = "等待运行"
    @Published var progress = ""

    func start() {
        guard !started else { return }
        started = true; status = "准备合成工作区"
        let selection = securityModel
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let runner = try ResearchProbe(model: selection) { message in
                    Task { @MainActor in self.progress += message + "\n" }
                }
                try runner.run()
                await MainActor.run { self.status = "检查完成；请读取收据确认结果" }
            } catch {
                // No arbitrary errors, paths, guest output or credentials in UI/console.
                await MainActor.run { self.status = "检查未完成；详情保存在研究 App 私有收据中" }
            }
        }
    }
}
#endif

private enum ProbeFailure: Error { case failed(String) }

private final class Outcome {
    private let lock = NSLock()
    private var value: Result<[String: Any], Error>?
    let done = DispatchSemaphore(value: 0)
    func set(_ value: Result<[String: Any], Error>) { lock.lock(); self.value = value; lock.unlock(); done.signal() }
    func get() throws -> [String: Any] {
        guard done.wait(timeout: .now() + 45) == .success else { throw ProbeFailure.failed("COMMAND_WAIT_TIMEOUT") }
        lock.lock(); defer { lock.unlock() }; return try value!.get()
    }
}

final class ResearchProbe {
    let model: String
    let root: URL
    let workspace: URL
    let state: URL
    let inputs: URL
    let identity: String
    let transport: GatedTransport
    let reportProgress: (String) -> Void
    let vmLock = NSLock()
    var vmExited = false
    /// Every QEMU start attempt in this process, counted before anything is launched.
    var vmStarts = 0
    var vmCode: Int32?
    var checks: [[String: Any]] = []
    var observations: [[String: Any]] = []
    var readyMilliseconds = 0
    var gateway: Gateway?
    #if os(macOS)
    var hostProcess: Process?
    #endif

    init(model: String, scratch: URL? = nil, inputs: URL? = nil, projectRoot: URL? = nil, progress: @escaping (String) -> Void) throws {
        self.model = model; reportProgress = progress
        let documents = scratch ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.inputs = inputs ?? Bundle.main.bundleURL.appendingPathComponent("ProbeInputs")
        root = projectRoot ?? documents.appendingPathComponent("Plan500Research/" + UUID().uuidString)
        workspace = root.appendingPathComponent("workspace"); state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.path)
        let identityFile = workspace.appendingPathComponent(".plan500-identity")
        if FileManager.default.fileExists(atPath: identityFile.path) {
            identity = try String(contentsOf: identityFile, encoding: .utf8)
            guard UUID(uuidString: identity) != nil else { throw ProbeFailure.failed("PROJECT_IDENTITY_INVALID") }
        } else {
            identity = UUID().uuidString
            try Data(identity.utf8).write(to: identityFile)
            try Data("初始笔记".utf8).write(to: workspace.appendingPathComponent("笔记.txt"))
        }
        let token = try String(contentsOf: self.inputs.appendingPathComponent("token-private"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        transport = GatedTransport(port: 29450, token: token, timeout: 35)
    }

    func text(_ path: String) -> String? { try? String(contentsOf: workspace.appendingPathComponent(path), encoding: .utf8) }
    func number(_ object: [String: Any], _ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
    func result(_ object: [String: Any]) -> [String: Any] { object["result"] as? [String: Any] ?? [:] }
    func check(_ name: String, _ passed: Bool) throws {
        checks.append(["name": name, "passed": passed]); reportProgress((passed ? "PASS " : "FAIL ") + name)
        try save(completed: false)
        if !passed { throw ProbeFailure.failed(name) }
    }
    func observe(_ name: String, _ compatible: Bool, _ detail: [String: Any] = [:]) {
        observations.append(["name": name, "compatible": compatible, "detail": detail])
        reportProgress("OBS " + name + " = " + String(compatible))
    }
    func save(completed: Bool, failure: String? = nil) throws {
        vmLock.lock(); let exited = vmExited, code = vmCode; vmLock.unlock()
        let report: [String: Any] = ["completed": completed, "platform": physicalDevice ? "iPadOS device QEMU 9P" : "host or simulator", "model": model,
            "physicalDevice": physicalDevice, "checks": checks, "observations": observations,
            "readyMs": readyMilliseconds, "vmExited": exited, "vmCode": code as Any? ?? NSNull(),
            "failure": failure as Any? ?? NSNull(), "gatewayGeneration": gateway?.snapshot().0.generation ?? 0,
            "workerIntegrated": false, "modelNetworkVerified": false, "fullGatesPassed": false,
            "sourceInputs": (try? JSONSerialization.jsonObject(with: Data(contentsOf: inputs.appendingPathComponent("inputs.json")))) ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result-safe.json"), options: .atomic)
    }

    var physicalDevice: Bool {
        #if targetEnvironment(simulator) || os(macOS)
        return false
        #else
        return true
        #endif
    }

    func startVM() throws {
        vmLock.lock(); vmStarts += 1; vmLock.unlock()
        #if os(iOS)
        guard physicalDevice else { throw ProbeFailure.failed("SIMULATOR_HAS_NO_DEVICE_QEMU") }
        let bundle = Bundle.main.bundleURL
        let library = bundle.appendingPathComponent("Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        guard FileManager.default.fileExists(atPath: library.path),
              let pair = Plan500QemuBridge.createSocketPair() else { throw ProbeFailure.failed("EXECUTOR_MISSING") }
        let logURL = root.appendingPathComponent("serial-private.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL), serial = FileHandle(fileDescriptor: pair[0].int32Value, closeOnDealloc: true)
        DispatchQueue.global().async {
            defer { try? log.close(); try? serial.close() }
            while let data = try? serial.read(upToCount: 8192), !data.isEmpty { try? log.write(contentsOf: data) }
        }
        let serialArgument = "socket,id=serial0,fd=\(pair[1])"
        #else
        let bundle = root
        let serialArgument = "file,id=serial0,path=\(root.appendingPathComponent("serial-private.log").path)"
        #endif
        func optionPath(_ path: String) -> String { path.replacingOccurrences(of: ",", with: ",,") }
        let args = ["qemu-aarch64-softmmu", "-L", bundle.appendingPathComponent("qemu").path,
            "-machine", "virt", "-cpu", "cortex-a72", "-smp", "1", "-m", "1024", "-accel", "tcg",
            "-nodefaults", "-display", "none", "-monitor", "none",
            "-chardev", serialArgument, "-serial", "chardev:serial0",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:29450-:4500",
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-kernel", inputs.appendingPathComponent("Image").path, "-initrd", inputs.appendingPathComponent("initramfs.gz").path,
            "-append", "console=ttyAMA0 rdinit=/init",
            "-drive", "file=\(optionPath(inputs.appendingPathComponent("system.raw").path)),if=none,id=system,format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=system", "-fsdev", "local,id=ws,path=\(optionPath(workspace.path)),security_model=\(model),writeout=immediate",
            "-device", "virtio-9p-pci,fsdev=ws,mount_tag=workspace"]
        #if os(iOS)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let code = Plan500QemuBridge.runLibrary(library.path, arguments: args)
            vmLock.lock(); vmExited = true; vmCode = code; vmLock.unlock()
        }
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/qemu-system-aarch64")
        process.arguments = Array(args.dropFirst())
        let logURL = root.appendingPathComponent("qemu-private.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log; process.standardError = log
        process.terminationHandler = { [self] process in
            vmLock.lock(); vmExited = true; vmCode = process.terminationStatus; vmLock.unlock()
        }
        try process.run(); hostProcess = process
        #endif
        observe("private pthread_fchdir_np symbol available", dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_fchdir_np") != nil)
    }

    #if os(macOS)
    func stopHostVM() {
        guard let process = hostProcess, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
    #endif

    func reader(_ source: String, owner: Bool = false) throws -> [String: Any] {
        try transport.rpc("/execute", ["id": UUID().uuidString, "projectId": identity, "argv": ["/bin/sh", "-c", source],
            "cwd": "/workspace", "timeoutMs": 15000, "asOwner": owner])
    }
    func leased(_ source: String, id: String = UUID().uuidString, timeout: Int = 15000) throws -> [String: Any] {
        try gateway!.runLeased(id, argv: ["/bin/sh", "-c", source], timeout: timeout)
    }
    private func background(_ source: String, id: String) -> Outcome {
        let out = Outcome()
        DispatchQueue.global().async { [self] in out.set(Result { try leased(source, id: id) }) }
        return out
    }
    func until(_ condition: () -> Bool, seconds: Double = 15) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { throw ProbeFailure.failed("CONDITION_TIMEOUT") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func run() throws {
        do { try runChecks(); try save(completed: true) }
        catch {
            let fixed = (error as? ProbeFailure).map { failure in
                switch failure { case .failed(let name): return name }
            } ?? "PROBE_ERROR_SEE_PRIVATE_LOG"
            try? String(describing: error).write(to: root.appendingPathComponent("error-private.log"), atomically: true, encoding: .utf8)
            try? save(completed: false, failure: fixed)
            throw error
        }
    }

    func runChecks() throws {
        let started = Date(); reportProgress("BOOTING"); try startVM()
        var ready: [String: Any]?
        try until({
            vmLock.lock(); let exited = vmExited; vmLock.unlock()
            if exited { return true }
            ready = try? transport.rpc("/ready", nil); return ready != nil
        }, seconds: 600)
        readyMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        guard let ready else { throw ProbeFailure.failed("VM_EXIT_BEFORE_READY") }
        try check("real 9P ready identity and readonly mount", ready["projectId"] as? String == identity && ready["mount"] as? String == "9p" && ready["workspaceReadOnly"] as? Bool == true)
        try check("cgroup kill and separated uid contract", ready["cgroupKill"] as? Bool == true && number(ready, "commandUid") == Int(getuid()) && number(ready, "readerUid") == 65534 && number(ready, "userNamespaces") == 0)
        gateway = try Gateway(workspace: workspace.path, state: state.path, identity: identity, transport: transport)
        let g = gateway!; _ = try g.attach()
        try check("Chinese host file readable from guest", try reader("cat 笔记.txt")["stdout"] as? String == "初始笔记")
        let refused = try reader("printf bypass > 笔记.txt", owner: true)
        try check("owner uid unleased write is refused", (number(refused, "code") ?? 0) != 0 && text("笔记.txt") == "初始笔记")
        let path = RelativePath("笔记.txt"), base = g.version(RelativePath("笔记.txt"))
        let write = try g.nativeWrite(path, Data("原生修改".utf8), base: base)
        let stale = try g.nativeWrite(path, Data("过期修改".utf8), base: base)
        try check("native CAS stale edit preserves newer file", write["status"] as? String == "WRITTEN" && stale["status"] as? String == "CONFLICT" && text("笔记.txt") == "原生修改")
        try check("native update visible in guest", try reader("cat 笔记.txt")["stdout"] as? String == "原生修改")
        let changed = try leased("printf Linux修改 > 产物.txt")
        try check("leased guest write visible in host", changed["status"] as? String == "RELEASED" && number(result(changed), "code") == 0 && text("产物.txt") == "Linux修改")
        let generation = try reader("cat /run/plan500/generation")
        let generationObject = (generation["stdout"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try check("guest generation catches up to gateway", generationObject.flatMap { number($0, "generation") } == g.snapshot().0.generation)
        let rename = try leased("printf one > held; exec 3<held; printf two > held.tmp && mv held.tmp held; cat <&3; cat held")
        try check("rename preserves old open descriptor", result(rename)["stdout"] as? String == "onetwo")

        let draftBase = g.version(path), operation = UUID().uuidString
        let pending = background("printf ready > draft-ready; sleep 2; printf guest > 笔记.txt", id: operation)
        try until({ text("draft-ready") == "ready" })
        let draft = try g.nativeWrite(path, Data("native-draft".utf8), base: draftBase)
        let released = try pending.get()
        let draftResults = released["drafts"] as? [[String: Any]] ?? []
        try check("native edit during lease is held then conflicts", draft["status"] as? String == "DRAFT_HELD" && draftResults.first?["status"] as? String == "CONFLICT" && text("笔记.txt") == "guest")
        let timed = try leased("printf partial > timed; sleep 5; printf late >> timed", timeout: 2000)
        try check("timeout stops writer before release", timed["status"] as? String == "RELEASED" && result(timed)["timeout"] as? Bool == true && text("timed") == "partial")
        let cancelId = UUID().uuidString, cancellable = background("printf ready > cancel-ready; sleep 8; touch cancel-late", id: cancelId)
        try until({ text("cancel-ready") == "ready" }); _ = try transport.rpc("/cancel", ["id": cancelId])
        let cancelled = try cancellable.get()
        try check("cancel can run concurrently and stops writer", cancelled["status"] as? String == "RELEASED" && result(cancelled)["cancelled"] as? Bool == true && text("cancel-late") == nil)
        let counterLock = NSLock(); var success = 0
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if let reply = try? transport.rpc("/ready", nil), reply["projectId"] as? String == identity {
                counterLock.lock(); success += 1; counterLock.unlock()
            }
        }
        try check("12 concurrent gated ready requests", success == 12)

        let lostId = UUID().uuidString, lost = background("printf ready > disconnect-ready; sleep 3; printf done > disconnect-effect", id: lostId)
        try until({ text("disconnect-ready") == "ready" })
        _ = try transport.rpc("/test/sever", ["ms": 1500])
        let unknown = try lost.get(), draftAfterLoss = try g.nativeWrite(RelativePath("after-loss"), Data("draft".utf8), base: nil)
        try check("lost reply keeps writer unknown and holds native draft", unknown["status"] as? String == "WRITER_UNKNOWN" && g.snapshot().0.lease != nil && draftAfterLoss["status"] as? String == "DRAFT_HELD")
        var reconciled: [String: Any] = [:]
        try until({
            vmLock.lock(); let exited = vmExited; vmLock.unlock()
            reconciled = (try? g.reconcile(vmExited: exited)) ?? [:]
            return reconciled["status"] as? String == "RELEASED"
        }, seconds: 25)
        try check("reconnect releases after writer finished", reconciled["reason"] as? String == "RECONCILED" && text("disconnect-effect") == "done" && text("after-loss") == "draft")

        // Observations do not count as protocol passes. These deliberately expose compatibility gaps.
        let caseNames = try leased("printf a > CaseName; printf b > casename")
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.path).filter { $0.lowercased() == "casename" }
        observe("case-sensitive names", number(result(caseNames), "code") == 0 && names.count == 2, ["count": names.count])
        let modes = try leased("printf x > executable; chmod 755 executable; ln -s executable linked")
        let attributes = try FileManager.default.attributesOfItem(atPath: workspace.appendingPathComponent("executable").path)
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: workspace.appendingPathComponent("linked").path)
        observe("ordinary host chmod and symlink", number(result(modes), "code") == 0 && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755 && link == "executable")
        let fifo = try leased("mkfifo fifo; r=$?; rm -f fifo; exit $r")
        observe("guest FIFO in workspace", number(result(fifo), "code") == 0, ["code": number(result(fifo), "code") ?? -1])
        let socket = try leased("/opt/node/bin/node -e \"const s=require('net').createServer().on('error',e=>{console.error(e.code);process.exit(3)}).listen('sock',()=>s.close())\"; r=$?; rm -f sock; exit $r")
        observe("guest Unix socket in workspace", number(result(socket), "code") == 0, ["code": number(result(socket), "code") ?? -1])
    }
}
