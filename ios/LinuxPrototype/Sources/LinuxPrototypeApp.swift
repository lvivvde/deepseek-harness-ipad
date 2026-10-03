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
    var stateDisk: String?
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
    @Published var performance = "尚未采样"
    @Published var harnessReady = false
    private(set) var startDate: Date?
    /// Last observed cold start to official HTTP readiness; only an estimate.
    static let readyEstimateKey = "lastHarnessReadySeconds"
    var readyEstimate: Double {
        let saved = UserDefaults.standard.double(forKey: Self.readyEstimateKey)
        return saved > 0 ? saved : 290
    }
    var bootPhase: String {
        if harnessReady { return "Harness 已就绪" }
        if urlSeenSeconds != nil { return "Harness 已启动，正在等待页面响应" }
        if console.contains("HARNESS_INIT_READY") { return "Linux 已启动，正在加载 Harness（最慢的一步）" }
        if serialReady { return "Linux 正在启动并挂载数据盘" }
        return launched ? "正在启动虚拟机" : "未启动"
    }
    private var serial: NWConnection?
    private var attempts = 0
    private var probeSent = false
    private var commandPoller: Task<Void, Never>?
    private var performancePoller: Task<Void, Never>?
    private var startedAt: TimeInterval?
    private var urlSeenSeconds: Double?
    private var httpReadySeconds: Double?
    private var sampleCount = 0
    private var sampleFailures = 0
    private var sampledPeak: UInt64 = 0
    private var lifecycle: [[String: Any]] = []
    private var webOpens: [[String: Any]] = []
    /// First time each boot marker reaches the serial log; splits the cold
    /// start into kernel/initramfs, init, native probe and Harness phases.
    private static let bootMarkers = ["virtio_blk", "STATE_HOME_READY", "HARNESS_INIT_READY",
                                      "NATIVE_PROBE_EXIT", "HARNESS_RELAY_READY", "dsh web: "]
    private var markerSeconds: [String: Double] = [:]
    private let ioQueue = DispatchQueue(label: "prototype.serial")

    var guestFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrototypeGuest", isDirectory: true)
    }

    private func saveDiagnostic(_ text: String, name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? text.data(using: .utf8)?.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func samplePerformance() {
        guard let startedAt else { return }
        let values = PrototypeQemuBridge.memoryFootprint()
        var report: [String: Any] = ["secondsSinceQemuCall": ProcessInfo.processInfo.systemUptime - startedAt,
                                    "sampleCount": sampleCount, "sampleFailures": sampleFailures,
                                    "scope": "Host app process only; excludes WKWebView helper processes",
                                    "lifecycle": lifecycle, "webOpens": webOpens, "bootMarkers": markerSeconds]
        if let bytes = values["physFootprintBytes"]?.uint64Value {
            sampleCount += 1
            sampledPeak = max(sampledPeak, bytes)
            report["sampleCount"] = sampleCount
            report["hostProcessFootprintBytes"] = bytes
            report["hostProcessSampledPeakBytes"] = sampledPeak
            performance = String(format: "宿主占用 %.1f MiB；采样峰值 %.1f MiB", Double(bytes) / 1_048_576, Double(sampledPeak) / 1_048_576)
        } else {
            sampleFailures += 1
            report["sampleFailures"] = sampleFailures
        }
        if let peak = values["kernelPeakBytes"]?.uint64Value { report["hostProcessKernelPeakBytes"] = peak }
        if let urlSeenSeconds { report["harnessLaunchURLSeconds"] = urlSeenSeconds }
        if let httpReadySeconds { report["harnessHTTPReadySeconds"] = httpReadySeconds }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            saveDiagnostic(text, name: "PrototypeMetrics.json")
        }
    }

    func recordLifecycle(_ event: String) {
        guard let startedAt else { return }
        lifecycle.append(["event": event, "secondsSinceQemuCall": ProcessInfo.processInfo.systemUptime - startedAt])
        samplePerformance()
    }

    /// Web view timings and a pixel check, so the white-screen phase is
    /// measured on device instead of reported by eye. Numbers only.
    func recordWeb(_ entry: [String: Any]) {
        guard let startedAt else { return }
        var entry = entry
        entry["secondsSinceQemuCall"] = ProcessInfo.processInfo.systemUptime - startedAt
        webOpens.append(entry)
        samplePerformance()
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
            for name in ["boot.json", spec.kernel, spec.initrd, spec.disk, spec.stateDisk].compactMap({ $0 }) {
                guard !name.contains("/"), name != ".", name != ".." else { throw PrototypeError.invalidName }
                let target = guestFolder.appendingPathComponent(name)
                if name == spec.stateDisk && FileManager.default.fileExists(atPath: target.path) { continue }
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
            if let disk = spec.stateDisk {
                args += ["-drive", "file=\(try image(disk)),if=none,id=state,format=raw", "-device", "virtio-blk-pci,drive=state"]
            }
            console = "真实 QEMU 参数：\n" + args.joined(separator: " ") + "\n"
            launched = true
            status = "已调用 QEMU；等待串口。启动成功仍待日志确认"
            startedAt = ProcessInfo.processInfo.systemUptime
            startDate = Date()
            samplePerformance()
            performancePoller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self else { return }
                    self.samplePerformance()
                }
            }
            let immutableArgs = args
            DispatchQueue.global(qos: .userInitiated).async {
                var message: NSString?
                let result = PrototypeQemuBridge.runLibrary(library.path, arguments: immutableArgs, message: &message)
                let text = (message as String?) ?? "QEMU return \(result)"
                Task { @MainActor in self.status = text; self.console += "\n" + text }
            }
            attempts = 0
            connectSerial()
            if ProcessInfo.processInfo.arguments.contains("--prototype-autostart") {
                // Local diagnostic mailbox for this throwaway test only. It
                // sends real guest serial commands; it is not a product API.
                commandPoller = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard let self else { return }
                        if !self.serialReady || !(self.console.contains("HARNESS_INIT_READY") || self.console.contains("MINIGUEST_INIT_READY")) { continue }
                        let file = self.guestFolder.deletingLastPathComponent().appendingPathComponent("PrototypeCommand.txt")
                        if let data = try? Data(contentsOf: file), data.count <= 16_384,
                           let command = String(data: data, encoding: .utf8) {
                            do { try FileManager.default.removeItem(at: file) }
                            catch { continue }
                            self.send(command.trimmingCharacters(in: .newlines))
                        }
                    }
                }
            }
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
                    if let start = self.startedAt {
                        let now = ProcessInfo.processInfo.systemUptime - start
                        if self.markerSeconds["firstSerialBytes"] == nil { self.markerSeconds["firstSerialBytes"] = now }
                        for marker in Self.bootMarkers where self.markerSeconds[marker] == nil && self.console.contains(marker) {
                            self.markerSeconds[marker] = now
                        }
                    }
                    // Only remap the guest's own authenticated launch URL. Keep
                    // its token exchange and signed browser cookie unchanged.
                    if let line = self.console.components(separatedBy: "\n").dropLast().last(where: { $0.contains("dsh web: http://127.0.0.1:3001/") }),
                       let marker = line.range(of: "dsh web: "),
                       let text = line[marker.upperBound...].split(whereSeparator: { $0.isWhitespace }).first,
                       var url = URLComponents(string: String(text)),
                       url.scheme == "http", url.host == "127.0.0.1", url.port == 3001,
                       url.queryItems?.filter({ $0.name == "token" }).count == 1 {
                        url.port = 18080
                        if let destination = url.url, self.webURL != destination {
                            self.webURL = destination
                            if self.urlSeenSeconds == nil, let start = self.startedAt {
                                self.urlSeenSeconds = ProcessInfo.processInfo.systemUptime - start
                            }
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
                // A previous BusyBox response at the same loopback origin can
                // otherwise survive in URLCache across prototype upgrades.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                let (data, response) = try await session.data(from: destination)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(decoding: data, as: UTF8.self)
                if code == 200, destination.query?.contains("token=") == true, let start = startedAt,
                   body.contains("__DSH_BOOT__"), httpReadySeconds == nil {
                    httpReadySeconds = ProcessInfo.processInfo.systemUptime - start
                    UserDefaults.standard.set(httpReadySeconds, forKey: Self.readyEstimateKey)
                    samplePerformance()
                }
                if code == 200, body.contains("__DSH_BOOT__") { harnessReady = true }
                saveDiagnostic("HTTP \(code)\n" + body, name: "PrototypeHostBridge.txt")
            } catch {
                saveDiagnostic("Host bridge failed: \(error.localizedDescription)", name: "PrototypeHostBridge.txt")
            }
            // The launch URL is printed before the official page answers;
            // keep probing so the web view only opens on a real page.
            if !harnessReady, destination.query?.contains("token=") == true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if webURL == destination { probeHostBridge() }
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
    var onMetrics: ([String: Any]) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator() }
    /// The official stop button refocuses the draft on mousedown. On iPad that
    /// raises the keyboard and WebKit drops the click, so the turn never stops.
    /// Deliver a still tap on that button as a plain click instead.
    static let stopTapScript = """
    (() => {
      const stop = t => t instanceof Element && t.closest('button[aria-label="停止生成"],button[aria-label="Stop generating"]');
      let start = null;
      document.addEventListener('touchstart', e => {
        const b = stop(e.target); const p = e.changedTouches[0];
        start = b && p ? {b, x: p.clientX, y: p.clientY} : null;
      }, {capture: true, passive: true});
      document.addEventListener('touchend', e => {
        const s = start; start = null; const p = e.changedTouches[0];
        if (!s || !p || s.b.disabled || stop(e.target) !== s.b) return;
        if (Math.hypot(p.clientX - s.x, p.clientY - s.y) > 10) return;
        e.preventDefault();
        s.b.click();
      }, {capture: true, passive: false});
    })();
    """
    /// The official page is an empty #root until about 1.5 MB of scripts
    /// arrive from the emulated guest and run; report when real text paints.
    static let paintScript = """
    (() => {
      const now = () => Math.round(performance.now());
      const marks = {};
      document.addEventListener('DOMContentLoaded', () => { marks.domContentLoadedMs = now(); });
      let done = false;
      const observer = new MutationObserver(() => {
        const root = document.getElementById('root');
        if (done || !root) return;
        if (marks.rootChildMs == null && root.firstElementChild) marks.rootChildMs = now();
        if (!(root.innerText || '').trim()) return;
        done = true; observer.disconnect(); marks.rootTextMs = now();
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const nav = performance.getEntriesByType('navigation')[0];
          const res = performance.getEntriesByType('resource');
          const end = list => Math.round(list.reduce((m, r) => Math.max(m, r.responseEnd), 0));
          window.webkit.messageHandlers.harnessPaint.postMessage(Object.assign(marks, {
            paintedMs: now(), htmlResponseEndMs: nav ? Math.round(nav.responseEnd) : -1,
            resources: res.length, resourceBytes: res.reduce((s, r) => s + (r.encodedBodySize || 0), 0),
            scriptsEndMs: end(res.filter(r => /\\.js$/.test(new URL(r.name).pathname))),
            stylesEndMs: end(res.filter(r => /\\.css$/.test(new URL(r.name).pathname)))
          }));
        }));
      });
      observer.observe(document, {childList: true, subtree: true, characterData: true});
    })();
    """
    func makeUIView(context: Context) -> UIView {
        let configuration = WKWebViewConfiguration()
        let scripts = configuration.userContentController
        scripts.addUserScript(WKUserScript(source: Self.stopTapScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: Self.paintScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.add(PaintMessageProxy(context.coordinator), name: "harnessPaint")
        let container = UIView()
        container.backgroundColor = .systemBackground
        let view = WKWebView(frame: container.bounds, configuration: configuration)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.uiDelegate = context.coordinator
        container.addSubview(view)
        let cover = LoadingCover(frame: container.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(cover)
        context.coordinator.attach(webView: view, cover: cover, onMetrics: onMetrics)
        context.coordinator.lastDestination = destination
        view.load(URLRequest(url: destination))
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.lastDestination != destination {
            context.coordinator.lastDestination = destination
            context.coordinator.webView?.load(URLRequest(url: destination))
        }
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "harnessPaint")
    }

    final class Coordinator: NSObject, WKUIDelegate {
        var lastDestination: URL?
        private(set) weak var webView: WKWebView?
        private weak var cover: LoadingCover?
        private var onMetrics: ([String: Any]) -> Void = { _ in }
        private var openedAt = Date()
        private var panels: [UIView] = []

        func attach(webView: WKWebView, cover: LoadingCover, onMetrics: @escaping ([String: Any]) -> Void) {
            self.webView = webView
            self.cover = cover
            self.onMetrics = onMetrics
            openedAt = Date()
            // Never trap the user behind the cover if detection misses.
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                guard let self, self.cover != nil else { return }
                self.reveal(["event": "paintTimeout"])
            }
        }

        func painted(_ marks: [String: Any]) {
            guard cover != nil else { return }
            var entry = marks.filter { $0.value is NSNumber }
            entry["event"] = "painted"
            reveal(entry)
        }

        private func reveal(_ entry: [String: Any]) {
            var entry = entry
            entry["nativeOpenToRevealSeconds"] = Date().timeIntervalSince(openedAt)
            let cover = self.cover
            self.cover = nil
            UIView.animate(withDuration: 0.2, animations: { cover?.alpha = 0 }) { _ in cover?.removeFromSuperview() }
            guard let webView else { onMetrics(entry); return }
            webView.takeSnapshot(with: nil) { [onMetrics] image, _ in
                if let image { entry["contentPixelFraction"] = Self.contentFraction(image) }
                onMetrics(entry)
            }
        }

        /// Share of pixels that differ from the page background (top-left).
        /// Point-sampled at 256×256 without smoothing, so thin text is not
        /// averaged away: about 0 means a blank page, whatever the theme.
        static func contentFraction(_ image: UIImage) -> Double {
            guard let cg = image.cgImage else { return -1 }
            let side = 256
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                              bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return -1 }
            let base = Array(pixels[0..<3])
            var differing = 0
            for i in stride(from: 0, to: pixels.count, by: 4)
            where (0..<3).contains(where: { abs(Int(pixels[i + $0]) - Int(base[$0])) > 24 }) { differing += 1 }
            return Double(differing) / Double(side * side)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            // Keep the official browser authorization in this foreground app,
            // so switching to Safari cannot suspend the local Linux callback.
            let panel = UIView(frame: webView.bounds)
            panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            panel.backgroundColor = .systemBackground
            let child = WKWebView(frame: panel.bounds.inset(by: UIEdgeInsets(top: 44, left: 0, bottom: 0, right: 0)), configuration: configuration)
            child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            child.uiDelegate = self
            panel.addSubview(child)
            let close = UIButton(type: .system)
            close.frame = CGRect(x: 12, y: 0, width: 160, height: 44)
            close.setTitle("返回 Harness", for: .normal)
            close.addAction(UIAction { [weak self, weak panel, weak child] _ in
                child?.stopLoading()
                panel?.removeFromSuperview()
                self?.panels.removeAll { $0 === panel }
            }, for: .touchUpInside)
            panel.addSubview(close)
            webView.addSubview(panel)
            panels.append(panel)
            return child
        }
        func webViewDidClose(_ webView: WKWebView) {
            let panel = webView.superview
            panel?.removeFromSuperview()
            panels.removeAll { $0 === panel }
        }
    }
}

/// WKUserContentController retains its handlers; keep the coordinator weak.
final class PaintMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: HarnessWebView.Coordinator?
    init(_ target: HarnessWebView.Coordinator) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let marks = message.body as? [String: Any] { target?.painted(marks) }
    }
}

/// Native cover over the web view until the official UI has painted text.
final class LoadingCover: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        let label = UILabel()
        label.text = "正在加载 Harness 界面…\n需要从虚拟机下载约 1.5 MB 页面脚本"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
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
                Text(vm.performance).font(.caption).textSelection(.enabled)
                HStack {
                    Button("导入测试 guest 目录") { importing = true }.disabled(vm.launched)
                    Button("启动一次 Linux") { vm.start() }.disabled(vm.launched)
                    Button(vm.harnessReady ? "打开 Harness" : "Harness 启动中…") { showingWeb = true }
                        .disabled(!(vm.harnessReady || vm.console.contains("MINIGUEST_INIT_READY")))
                }
                if vm.launched && !vm.harnessReady { BootProgress(vm: vm) }
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
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in vm.recordLifecycle("background") }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in vm.recordLifecycle("active") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result { vm.importGuest(folder) }
                else if case .failure(let error) = result { vm.status = error.localizedDescription }
            }
            .onChange(of: vm.harnessReady) { ready in if ready { showingWeb = true } }
            .sheet(isPresented: $showingWeb) {
                HarnessWebView(destination: vm.webURL) { vm.recordWeb($0) }.onAppear { vm.recordWeb(["event": "opened"]) }
            }
        }
    }
}

/// Cold-start progress. The remaining time is the last run's measurement,
/// not a promise: TCG start time varies with concurrent guest work.
struct BootProgress: View {
    @ObservedObject var vm: PrototypeVM
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = vm.startDate.map { context.date.timeIntervalSince($0) } ?? 0
            let estimate = vm.readyEstimate
            let remaining = estimate - elapsed
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(elapsed / estimate, 0.99))
                Text(vm.bootPhase).font(.headline)
                Text(remaining > 0
                     ? "已用 \(Self.clock(elapsed))，预计还需约 \(Self.clock(remaining))（按上次启动估算）"
                     : "已用 \(Self.clock(elapsed))，比上次慢，仍在启动；就绪后会自动打开")
                    .font(.callout).monospacedDigit()
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

@main
struct LinuxPrototypeApp: App {
    var body: some Scene { WindowGroup { PrototypeView() } }
}
