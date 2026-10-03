import Combine
import Foundation

enum RuntimeEvent {
    case booting
    case loadingHarness
    case ready(URL)
    case exited
    case connectionUnavailable
}

enum RuntimePhase: Equatable {
    case idle
    case preparing
    case booting
    case loadingHarness
    case ready
    case reconnecting
    case failed(String, requiresRelaunch: Bool)
}

@MainActor
protocol RuntimeDriving: AnyObject {
    var hasLaunched: Bool { get }
    func start(onEvent: @escaping @MainActor (RuntimeEvent) -> Void) async throws
    func reconnect() async throws -> URL
    func flush() async
}

/// The App owns this module. Pages and auxiliary windows never own VM lifetime.
@MainActor
final class RuntimeController: ObservableObject {
    @Published private(set) var phase: RuntimePhase = .idle
    @Published private(set) var destination: URL?
    @Published private(set) var pageRevision = 0
    private let driver: RuntimeDriving
    private var startup: Task<Void, Never>?
    private var checkingConnection = false
    private var reloadRequested = false
    private var runtimeExited = false
    @Published private(set) var diagnostics: [String] = []

    init(driver: RuntimeDriving) { self.driver = driver }

    func ensureRunning() async {
        if let startup { await startup.value; return }
        guard !driver.hasLaunched, !runtimeExited else { return }
        phase = .preparing
        record("preparing")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await driver.start { [weak self] event in self?.receive(event) }
            } catch {
                let message = (error as? RuntimeConfigurationError)?.errorDescription ?? "无法启动运行环境"
                phase = .failed(message, requiresRelaunch: driver.hasLaunched)
                record("startupFailed")
            }
        }
        startup = task
        await task.value
        startup = nil
    }

    func recoverPage() async {
        await checkConnection(reload: true)
    }

    func resume() async {
        guard destination != nil else { return }
        await checkConnection(reload: phase != .ready)
    }

    func flush() async { await driver.flush() }

    func pageFailed() {
        guard !runtimeExited else { return }
        phase = .failed("页面暂时无法加载，请重试连接", requiresRelaunch: false)
        record("pageLoadFailed")
    }

    func retry() async {
        guard !runtimeExited else { return }
        if driver.hasLaunched { await recoverPage() }
        else { await ensureRunning() }
    }

    private func checkConnection(reload: Bool) async {
        guard driver.hasLaunched, !runtimeExited else { return }
        reloadRequested = reloadRequested || reload
        guard !checkingConnection else { return }
        checkingConnection = true
        phase = .reconnecting
        defer {
            checkingConnection = false
            reloadRequested = false
        }
        do {
            let url = try await driver.reconnect()
            guard !runtimeExited else { return }
            destination = url
            if reloadRequested { pageRevision += 1 }
            phase = .ready
        } catch {
            guard !runtimeExited else { return }
            phase = .failed("暂时无法连接 Harness，请重试连接", requiresRelaunch: false)
            record("reconnectFailed")
        }
    }

    private func receive(_ event: RuntimeEvent) {
        guard !runtimeExited else { return }
        switch event {
        case .booting: phase = .booting; record("booting")
        case .loadingHarness: phase = .loadingHarness; record("loadingHarness")
        case .ready(let url): destination = url; phase = .ready; record("ready")
        case .exited:
            runtimeExited = true
            phase = .failed("运行环境已退出，请关闭并重新打开应用", requiresRelaunch: true)
            record("runtimeExited")
        case .connectionUnavailable:
            phase = .failed("Harness 尚未就绪，请重试连接", requiresRelaunch: false)
            record("connectionUnavailable")
        }
    }

    private func record(_ event: String) {
        diagnostics.append(event)
        if diagnostics.count > 40 { diagnostics.removeFirst() }
    }
}
