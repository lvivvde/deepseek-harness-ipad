import Foundation

/// Real embedded QEMU. Build inputs are supplied independently of the App UI.
@MainActor
final class EmbeddedRuntime: RuntimeDriving {
    private var bootStartedAt: Date?
    private var receiptDirectory: URL?
    private(set) var hasLaunched = false
    private var exited = false
    private var onEvent: (@MainActor (RuntimeEvent) -> Void)?
    private var serialChannel: RuntimeLineChannel?
    private var serialReady = false
    private var launchURL: URL?
    private var startupProbe: Task<Void, Never>?
    private var syncMarker: String?
    private var acknowledgedSync: String?
    private let pageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: LocalRedirectPolicy(), delegateQueue: nil)
    }()

    func start(onEvent: @escaping @MainActor (RuntimeEvent) -> Void) async throws {
        guard !hasLaunched else { return }
        bootStartedAt = Date()
        #if targetEnvironment(simulator)
        throw RuntimeConfigurationError.missingRuntime
        #else
        guard let frameworks = Bundle.main.privateFrameworksURL else { throw RuntimeConfigurationError.missingRuntime }
        let library = frameworks.appendingPathComponent("qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        guard FileManager.default.fileExists(atPath: library.path) else { throw RuntimeConfigurationError.missingRuntime }
        let resources = Bundle.main.bundleURL.appendingPathComponent("Runtime")
        let userData = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessRuntime", isDirectory: true)
        let configuration = try await Task.detached(priority: .userInitiated) {
            try RuntimeConfiguration.prepare(resources: resources, userData: userData)
        }.value
        guard let serialPair = HarnessQemuBridge.createSocketPair() else { throw ConnectionFailure.unavailable }
        guard let controlPair = HarnessQemuBridge.createSocketPair() else {
            for descriptor in serialPair { try? FileHandle(fileDescriptor: descriptor.int32Value).close() }
            throw ConnectionFailure.unavailable
        }
        serialChannel = RuntimeLineChannel(descriptor: serialPair[0].int32Value)
        serialChannel?.onLine = { [weak self] in self?.handleLine($0) }
        serialChannel?.onClose = { [weak self] in self?.serialReady = false }
        serialReady = true
        QemuControl.shared.attach(descriptor: controlPair[0].int32Value)
        let arguments = configuration.qemuArguments(firmwareDirectory: Bundle.main.bundleURL.appendingPathComponent("qemu"),
                                                    serialFD: serialPair[1].intValue, controlFD: controlPair[1].intValue)
        self.onEvent = onEvent
        receiptDirectory = userData
        hasLaunched = true
        publish(.booting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HarnessQemuBridge.runLibrary(library.path, arguments: arguments)
            Task { @MainActor in self?.didExit(code: result) }
        }
        startupProbe = Task { [weak self] in
            let deadline = Date().addingTimeInterval(900)
            while !Task.isCancelled, Date() < deadline {
                guard let self, !exited else { return }
                if let url = launchURL, await pageIsReady(url), !exited {
                    publish(.ready(url))
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard let self, !exited, !Task.isCancelled else { return }
            self.publish(.connectionUnavailable)
        }
        #endif
    }

    func reconnect() async throws -> URL {
        guard hasLaunched, !exited else { throw ConnectionFailure.unavailable }
        guard serialReady else { throw ConnectionFailure.unavailable }
        for _ in 0..<3 {
            if let url = launchURL, await pageIsReady(url), !exited { return url }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ConnectionFailure.unavailable
    }

    /// A bounded sync attempt; this does not promise indefinite background execution.
    func flush() async {
        guard serialReady, !exited else { return }
        let marker = "APP_SYNC_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        syncMarker = marker
        send("/bin/busybox sync; /bin/busybox printf '\\n\(marker)\\n'")
        let deadline = Date().addingTimeInterval(5)
        while acknowledgedSync != marker, Date() < deadline, !Task.isCancelled, !exited {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        syncMarker = nil
    }

    private func didExit(code: Int32) {
        exited = true
        startupProbe?.cancel()
        serialChannel?.close()
        QemuControl.shared.close()
        serialReady = false
        // Only a fixed event reaches diagnostics, never loader errors or auth URLs.
        publish(.exited)
    }

    private func pageIsReady(_ url: URL) async -> Bool {
        guard HarnessEndpoint.isLocalPage(url) else { return false }
        do {
            let (body, response) = try await pageSession.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url, HarnessEndpoint.isLocalPage(finalURL) else { return false }
            return HarnessEndpoint.isReady(status: response.statusCode, body: body)
        } catch { return false }
    }

    private func handleLine(_ line: String) {
        if let failure = RuntimeBootFailure.fromSerialLine(line) {
            startupProbe?.cancel()
            publish(.bootFailed(failure))
            return
        }
        if line == syncMarker { acknowledgedSync = line }
        if launchURL == nil, line.contains("HARNESS_INIT_READY") { publish(.loadingHarness) }
        if let url = HarnessEndpoint.fromSerialLine(line) { launchURL = url }
    }

    private func send(_ command: String) {
        try? serialChannel?.send(command)
    }

    /// Fixed stages only. This receipt contains no URLs, console text or credentials.
    private func publish(_ event: RuntimeEvent) {
        let stage = event.diagnosticStage
        let elapsed = Int(Date().timeIntervalSince(bootStartedAt ?? Date()) * 1000)
        if let directory = receiptDirectory,
           let data = try? JSONSerialization.data(withJSONObject: ["stage": stage, "elapsedMilliseconds": elapsed]) {
            try? data.write(to: directory.appendingPathComponent("RuntimeStatus.json"), options: .atomic)
        }
        print("HARNESS_APP_STAGE:\(stage) elapsed_ms=\(elapsed)")
        onEvent?(event)
    }

    private enum ConnectionFailure: Error { case unavailable }
}

/// The readiness probe cannot follow an auth-bearing request to an external host.
final class LocalRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(HarnessEndpoint.isLocalPage) == true ? request : nil)
    }
}
