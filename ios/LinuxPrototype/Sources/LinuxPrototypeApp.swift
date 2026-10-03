// THROWAWAY feasibility prototype. No simulated Linux or Harness responses.
import SwiftUI
import WebKit
import Network
import UniformTypeIdentifiers

struct GuestSpec: Decodable {
    var mode: String
    var kernel: String?
    var initrd: String?
    var disk: String?
    var diskFormat: String?
    var append: String?
    var memoryMiB: Int?
}

@MainActor
final class PrototypeVM: ObservableObject {
    @Published var status = "未启动；这是可丢弃的执行可行性原型" {
        didSet { saveDiagnostic(status, name: "PrototypeStatus.txt") }
    }
    @Published var console = "" {
        didSet { saveDiagnostic(console, name: "PrototypeSerial.log") }
    }
    @Published var launched = false
    @Published var serialReady = false
    @Published var webURL = URL(string: "http://127.0.0.1:18080/")!
    private var serial: NWConnection?
    private var attempts = 0
    private var probeSent = false
    private let ioQueue = DispatchQueue(label: "prototype.serial")

    var guestFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrototypeGuest", isDirectory: true)
    }

    private func saveDiagnostic(_ text: String, name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? text.data(using: .utf8)?.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func importGuest(_ folder: URL) {
        guard !launched else { status = "先关闭并重新打开应用，再更换 guest"; return }
        guard folder.startAccessingSecurityScopedResource() else { status = "未获得所选目录访问权限"; return }
        defer { folder.stopAccessingSecurityScopedResource() }
        do {
            let specData = try Data(contentsOf: folder.appendingPathComponent("boot.json"))
            let spec = try JSONDecoder().decode(GuestSpec.self, from: specData)
            // Only named image files are copied, never the user's project tree.
            try FileManager.default.createDirectory(at: guestFolder, withIntermediateDirectories: true)
            for name in ["boot.json", spec.kernel, spec.initrd, spec.disk].compactMap({ $0 }) {
                guard !name.contains("/"), name != ".", name != ".." else { throw PrototypeError.invalidName }
                let target = guestFolder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: target)
            }
            status = "guest 文件已复制到应用内；未运行"
        } catch { status = "导入失败：\(error.localizedDescription)" }
    }

    func start() {
        guard !launched else { return }
        guard let frameworks = Bundle.main.privateFrameworksURL else { status = "缺少 Frameworks 目录"; return }
        let library = frameworks.appendingPathComponent("qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        guard FileManager.default.fileExists(atPath: library.path) else {
            status = "未嵌入无 JIT QEMU；当前只通过外壳编译，不能运行 Linux"
            return
        }
        do {
            let spec = try JSONDecoder().decode(GuestSpec.self, from: Data(contentsOf: guestFolder.appendingPathComponent("boot.json")))
            let memory = spec.memoryMiB ?? 512
            guard (128...2048).contains(memory) else { throw PrototypeError.invalidMemory }
            var args = ["qemu-aarch64-softmmu", "-L", Bundle.main.bundleURL.appendingPathComponent("qemu").path,
                        "-machine", "virt", "-cpu", "cortex-a72", "-smp", "1", "-m", String(memory),
                        "-accel", "tcg", "-nodefaults", "-display", "none", "-monitor", "none",
                        "-chardev", "socket,id=serial0,host=127.0.0.1,port=18081,server=on,wait=off",
                        "-serial", "chardev:serial0", "-qmp", "tcp:127.0.0.1:18082,server=on,wait=off",
                        "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:18080-:3000",
                        "-device", "virtio-net-pci,netdev=net0"]
            func image(_ name: String) throws -> String {
                guard !name.contains("/"), name != ".", name != ".." else { throw PrototypeError.invalidName }
                let path = guestFolder.appendingPathComponent(name).path
                guard FileManager.default.fileExists(atPath: path) else { throw PrototypeError.missingImage(name) }
                return path
            }
            if spec.mode == "kernel", let kernel = spec.kernel {
                args += ["-kernel", try image(kernel), "-append", spec.append ?? "console=ttyAMA0"]
                if let initrd = spec.initrd { args += ["-initrd", try image(initrd)] }
            } else if spec.mode == "uefi" {
                let firmware = Bundle.main.bundleURL.appendingPathComponent("qemu/edk2-aarch64-code.fd")
                guard FileManager.default.fileExists(atPath: firmware.path) else { throw PrototypeError.missingImage("edk2-aarch64-code.fd") }
                args += ["-bios", firmware.path]
            } else { throw PrototypeError.invalidMode }
            if let disk = spec.disk {
                let format = spec.diskFormat ?? "qcow2"
                guard ["raw", "qcow2"].contains(format) else { throw PrototypeError.invalidMode }
                args += ["-drive", "file=\(try image(disk)),if=none,id=root,format=\(format)", "-device", "virtio-blk-pci,drive=root"]
            }
            console = "真实 QEMU 参数：\n" + args.joined(separator: " ") + "\n"
            launched = true
            status = "已调用 QEMU；等待串口。启动成功仍待日志确认"
            let immutableArgs = args
            DispatchQueue.global(qos: .userInitiated).async {
                var message: NSString?
                let result = PrototypeQemuBridge.runLibrary(library.path, arguments: immutableArgs, message: &message)
                let text = (message as String?) ?? "QEMU return \(result)"
                Task { @MainActor in self.status = text; self.console += "\n" + text }
            }
            attempts = 0
            connectSerial()
        } catch { status = "尚未启动：\(error.localizedDescription)" }
    }

    private func connectSerial() {
        attempts += 1
        let connection = NWConnection(host: "127.0.0.1", port: 18081, using: .tcp)
        serial = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.serial === connection else { return }
                switch state {
                case .ready:
                    self.serialReady = true
                    self.status = "已连接 guest 救援串口；Linux 与 Harness 的通过状态以实际输出为准"
                    self.receive()
                case .failed, .waiting:
                    connection.cancel()
                    self.serialReady = false
                    if self.attempts < 30 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connectSerial() }
                    } else { self.status = "串口未就绪；请检查 Xcode 中的 QEMU 错误日志" }
                default: break
                }
            }
        }
        connection.start(queue: ioQueue)
    }

    private func receive() {
        serial?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.console += String(decoding: data, as: UTF8.self)
                    if self.console.count > 100_000 { self.console = String(self.console.suffix(100_000)) }
                    // Only remap the guest's own authenticated launch URL. Keep
                    // its token exchange and signed browser cookie unchanged.
                    if let line = self.console.components(separatedBy: "\n").dropLast().last(where: { $0.hasPrefix("dsh web: http://127.0.0.1:3001/") }),
                       let text = line.dropFirst("dsh web: ".count).split(whereSeparator: { $0.isWhitespace }).first,
                       var url = URLComponents(string: String(text)),
                       url.scheme == "http", url.host == "127.0.0.1", url.port == 3001,
                       url.queryItems?.filter({ $0.name == "token" }).count == 1 {
                        url.port = 18080
                        if let destination = url.url, self.webURL != destination {
                            self.webURL = destination
                            self.probeHostBridge()
                        }
                    }
                    if !self.probeSent && self.console.contains("MINIGUEST_INIT_READY") &&
                        ProcessInfo.processInfo.arguments.contains("--prototype-autostart") {
                        self.probeSent = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.send("/bin/busybox uname -a; /bin/busybox sh -c '/bin/busybox sleep 1 & p=$!; echo CHILD:$p; wait \"$p\"; echo CHILD_EXIT:$?'; /bin/busybox sh -c '/bin/busybox printf \"pipe-ok\\n\" | /bin/busybox tr a-z A-Z'; /bin/busybox wget -qO- http://127.0.0.1:3000/; /bin/busybox printf 'file-ok\\n' > /tmp/prototype-file; /bin/busybox cat /tmp/prototype-file; echo GUEST_PROBE_END")
                            self.probeHostBridge()
                        }
                    }
                }
                if !complete && error == nil { self.receive() }
                else { self.serialReady = false; self.status = "串口已断开；查看日志确认 guest 是否退出" }
            }
        }
    }

    func send(_ command: String) {
        serial?.send(content: (command + "\n").data(using: .utf8), completion: .contentProcessed({ _ in }))
    }

    private func probeHostBridge() {
        Task {
            let destination = webURL
            do {
                let (data, response) = try await URLSession.shared.data(from: destination)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                saveDiagnostic("HTTP \(code)\n" + String(decoding: data, as: UTF8.self), name: "PrototypeHostBridge.txt")
            } catch {
                saveDiagnostic("Host bridge failed: \(error.localizedDescription)", name: "PrototypeHostBridge.txt")
            }
        }
    }
}

enum PrototypeError: LocalizedError {
    case invalidName, invalidMemory, invalidMode, missingImage(String)
    var errorDescription: String? {
        switch self {
        case .invalidName: return "boot.json 文件名必须为目录内的单个文件名"
        case .invalidMemory: return "首个原型内存范围为 128–2048 MiB"
        case .invalidMode: return "boot.json 需要 kernel 或 uefi 模式"
        case .missingImage(let name): return "缺少镜像文件：\(name)"
        }
    }
}

struct HarnessWebView: UIViewRepresentable {
    let destination: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: destination))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct PrototypeView: View {
    @StateObject private var vm = PrototypeVM()
    @State private var importing = false
    @State private var command = ""
    @State private var showingWeb = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("验证真实 Linux 与本机网页桥；此应用尚未通过 Harness 验收。")
                Text(vm.status).font(.callout).textSelection(.enabled)
                HStack {
                    Button("导入测试 guest 目录") { importing = true }.disabled(vm.launched)
                    Button("启动一次 Linux") { vm.start() }.disabled(vm.launched)
                    Button("打开 guest 网页") { showingWeb = true }.disabled(!vm.serialReady)
                }
                ScrollView { Text(vm.console).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    TextField("guest 串口命令", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("发送") { vm.send(command); command = "" }.disabled(!vm.serialReady)
                }
                Text("前台、单 VM、单次启动；串口不是完整 PTY 终端。退出后重新打开应用再启动。网页仅连接设备 loopback 的 guest 端口桥。").font(.caption)
            }
            .padding().navigationTitle("Linux 技术原型")
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--prototype-autostart") { vm.start() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result { vm.importGuest(folder) }
                else if case .failure(let error) = result { vm.status = error.localizedDescription }
            }
            .sheet(isPresented: $showingWeb) { HarnessWebView(destination: vm.webURL) }
        }
    }
}

@main
struct LinuxPrototypeApp: App {
    var body: some Scene { WindowGroup { PrototypeView() } }
}
