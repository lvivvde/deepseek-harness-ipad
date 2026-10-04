import Foundation
import UIKit

/// Real embedded QEMU. Build inputs are supplied independently of the App UI.
@MainActor
final class EmbeddedRuntime: RuntimeDriving {
    private var bootStartedAt: Date?
    private var receiptDirectory: URL?
    private(set) var hasLaunched = false
    private var userDisk: URL?
    private var exited = false
    private var onEvent: (@MainActor (RuntimeEvent) -> Void)?
    private var serialChannel: RuntimeLineChannel?
    private var serialReady = false
    private var launchURL: URL?
    private var activeGuestRequests = Set<String>()
    private var timedGuestRequests = Set<String>()
    private var guestReplies: [String: GuestHealth] = [:]
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
        userDisk = configuration.userDisk
        hasLaunched = true
        publish(.booting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HarnessQemuBridge.runLibrary(library.path, arguments: arguments)
            Task { @MainActor in self?.didExit(code: result) }
        }
        Task { _ = try? await QemuControl.shared.command("query-status") }
        startupProbe = Task { [weak self] in
            let deadline = Date().addingTimeInterval(300)
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
        guard !exited else { throw RecoveryFailure.exited }
        guard hasLaunched else { throw RecoveryFailure.control }
        let deadline = Date().addingTimeInterval(10)
        let state: [String: Any]
        do { state = try await QemuControl.shared.command("query-status", timeout: 1.5) }
        catch { throw exited ? RecoveryFailure.exited : RecoveryFailure.control }
        guard (state["return"] as? [String: Any])?["running"] as? Bool == true else { throw RecoveryFailure.vmStopped }
        publish(.recovery(.vmRunning))
        guard serialReady else { throw RecoveryFailure.guestControl }
        var health = try await inspectGuest(deadline: deadline)
        publish(.recovery(.guestResponded))
        guard health.clockMatches(Date()) else { throw RecoveryFailure.clock }
        publish(.recovery(.clockSynchronized))
        guard health.leased != true else { throw RecoveryFailure.busy }
        guard health.writable else { throw RecoveryFailure.readonly }
        if !health.running {
            guard health.restartable else { throw RecoveryFailure.harness }
            publish(.recovery(.harnessRestarting))
            health = try await inspectGuest(deadline: deadline, restart: true)
            guard health.running else { throw RecoveryFailure.harness }
        }
        publish(.recovery(.harnessRunning))
        if let url = launchURL, await pageIsReady(url, timeout: 1.5), !exited {
            publish(.recovery(.pageReady))
            return url
        }
        guard deadline.timeIntervalSinceNow > 3 else { throw RecoveryFailure.connection }
        // Repair only the page forward, retaining the running VM and serial/control descriptors.
        publish(.recovery(.forwardRepairing))
        _ = try? await QemuControl.shared.monitor("hostfwd_remove net0 tcp:127.0.0.1:\(RuntimePorts.page)", timeout: 1)
        let added: String
        do { added = try await QemuControl.shared.monitor("hostfwd_add net0 tcp:127.0.0.1:\(RuntimePorts.page)-10.0.2.15:2999", timeout: 1) }
        catch { throw exited ? RecoveryFailure.exited : RecoveryFailure.control }
        guard added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecoveryFailure.connection }
        while Date() < deadline, !Task.isCancelled, !exited {
            if let url = launchURL, await pageIsReady(url, timeout: min(1.5, deadline.timeIntervalSinceNow)), !exited {
                publish(.recovery(.pageReady))
                return url
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw exited ? RecoveryFailure.exited : RecoveryFailure.connection
    }

    private func inspectGuest(deadline: Date, restart: Bool = false) async throws -> GuestHealth {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        activeGuestRequests.insert(nonce)
        defer { guestReplies.removeValue(forKey: nonce); activeGuestRequests.remove(nonce); timedGuestRequests.remove(nonce) }
        guard let serialChannel else { throw RecoveryFailure.guestControl }
        do { try serialChannel.send("NODE_OPTIONS= NODE_COMPILE_CACHE= node /opt/harness/control.cjs \(nonce) --handshake \(restart ? "restart" : "health")") }
        catch { throw RecoveryFailure.guestControl }
        let limit = deadline
        while Date() < limit, !Task.isCancelled, !exited {
            if let reply = guestReplies[nonce] { return reply }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw exited ? RecoveryFailure.exited : RecoveryFailure.guestControl
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

    func userDiskStatus() async throws -> UserDiskStatus {
        guard let disk = userDisk else { throw UserDiskError.unavailable }
        return try await Task.detached(priority: .utility) { try UserDiskStatus.read(disk: disk) }.value
    }

    func growUserDisk(toGiB size: Int) async throws -> UserDiskStatus {
        guard hasLaunched, !exited else { throw UserDiskError.busy }
        let bytes = try await userDiskStatus().growthBytes(toGiB: size)
        let transfer = ProjectTransfer()
        let acquiredAt = ProcessInfo.processInfo.systemUptime
        let lease = try await transfer.beginDiskGrowth(bytes: bytes)
        do {
            // QEMU owns the running image; never truncate it from a second file handle.
            _ = try await QemuControl.shared.command("block_resize", arguments: ["device": "user", "size": bytes], timeout: 10, beforeSend: {
                guard ProcessInfo.processInfo.systemUptime - acquiredAt < 30,
                      UIApplication.shared.applicationState == .active else { throw UserDiskError.busy }
            })
            let actual = try await transfer.finishDiskGrowth(lease: lease)
            guard actual >= bytes else { throw UserDiskError.incomplete }
            return try await userDiskStatus()
        } catch {
            try? await transfer.cancelDiskGrowth(lease: lease)
            throw (error as? UserDiskError) ?? UserDiskError.incomplete
        }
    }

    func exportRescueDisk(into directory: URL) async throws -> URL {
        if hasLaunched && !exited {
            await flush()
            _ = try? await QemuControl.shared.command("quit", timeout: 1)
            let deadline = Date().addingTimeInterval(5)
            while !exited, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        guard exited || !hasLaunched else { throw RecoveryFailure.control }
        let source = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessRuntime/user.raw")
        let destination = directory.appendingPathComponent("HarnessRescue.raw")
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
        return destination
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

    private func pageIsReady(_ url: URL, timeout: Double = 8) async -> Bool {
        guard HarnessEndpoint.isLocalPage(url) else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = max(0.1, timeout)
            let (body, response) = try await pageSession.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url, HarnessEndpoint.isLocalPage(finalURL) else { return false }
            return HarnessEndpoint.isReady(status: response.statusCode, body: body)
        } catch { return false }
    }

    private func handleLine(_ line: String) {
        if let range = line.range(of: "HARNESS_CONTROL_READY:") {
            let nonce = String(line[range.upperBound...])
            if activeGuestRequests.contains(nonce), !timedGuestRequests.contains(nonce) {
                timedGuestRequests.insert(nonce)
                send("HARNESS_TIME:\(nonce):\(Int64(Date().timeIntervalSince1970 * 1000))")
            }
        }
        if let range = line.range(of: "HARNESS_CONTROL:"), guestReplies.count < 8 {
            let fields = line[range.upperBound...].split(separator: ":", maxSplits: 1)
            if fields.count == 2, activeGuestRequests.contains(String(fields[0])),
               let health = try? JSONDecoder().decode(GuestHealth.self, from: Data(fields[1].utf8)) {
                guestReplies[String(fields[0])] = health
            }
        }
        if line.hasPrefix("HARNESS_TRANSFER_FAILURE:") || line.hasPrefix("HARNESS_BACKUP_FAILURE:") { publish(.dataOperationFailed) }
        if line == "HARNESS_PROCESS_STOPPED" { publish(.harnessStopped) }

        if let failure = RuntimeBootFailure.fromSerialLine(line) {
            startupProbe?.cancel()
            publish(.bootFailed(failure))
            return
        }
        if line == syncMarker { acknowledgedSync = line }
        if launchURL == nil, line.contains("HARNESS_INIT_READY") { publish(.loadingHarness) }
        if let url = HarnessEndpoint.fromSerialLine(line) {
            let isRestart = launchURL != nil
            launchURL = url
            if isRestart {
                Task { [weak self] in
                    guard let self else { return }
                    let deadline = Date().addingTimeInterval(120)
                    while Date() < deadline, !Task.isCancelled, !exited {
                        if await pageIsReady(url), launchURL == url { publish(.ready(url)); return }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }
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
