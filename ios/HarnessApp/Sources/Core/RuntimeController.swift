import Combine
import Foundation

enum RuntimeEvent {
    case booting
    case loadingHarness
    case ready(URL)
    case exited
    case harnessStopped
    case dataOperationFailed
    case connectionUnavailable
    case bootFailed(RuntimeBootFailure)

    var diagnosticStage: String {
        switch self {
        case .booting: return "booting"
        case .loadingHarness: return "loadingHarness"
        case .ready: return "ready"
        case .dataOperationFailed: return "userDataOperationFailed"
        case .harnessStopped: return "harnessStopped"
        case .exited: return "runtimeExited"
        case .connectionUnavailable: return "connectionUnavailable"
        case .bootFailed(let failure): return "bootFailed:" + failure.rawValue
        }
    }
}

enum RuntimeBootFailure: String {
    case systemMount = "SYSTEM_MOUNT"
    case userFsck = "USER_FSCK"
    case userMount = "USER_MOUNT"
    case userLayout = "USER_LAYOUT"
    case userReadonly = "USER_READONLY"
    case userSpace = "USER_SPACE"
    case network = "NETWORK"
    case userRestore = "USER_RESTORE"
    case userLocks = "USER_LOCKS"
    case harnessExit = "HARNESS_EXIT"

    static func fromSerialLine(_ line: String) -> RuntimeBootFailure? {
        let prefix = "HARNESS_BOOT_ERROR:"
        guard line.hasPrefix(prefix) else { return nil }
        return RuntimeBootFailure(rawValue: String(line.dropFirst(prefix.count)))
    }

    var message: String {
        switch self {
        case .systemMount: return "系统盘无法挂载，请重新安装完整运行时版本"
        case .userFsck: return "用户盘检查未通过，原盘已保留，运行环境停在救援模式"
        case .userMount: return "用户盘无法挂载，原盘已保留，运行环境停在救援模式"
        case .userLayout: return "用户盘布局不兼容或无法读取，原盘未改写，请使用匹配版本或救援"
        case .userReadonly: return "用户盘不可写或空间不足，原盘已保留"
        case .userSpace: return "用户盘空间不足或写入失败，原盘已保留，运行环境停在救援模式"
        case .network: return "运行环境网络初始化失败，请关闭并重新打开应用"
        case .userRestore: return "用户数据恢复未能回滚，原始目录和事务记录已保留，请导出救援盘"
        case .userLocks: return "Harness 状态锁无法恢复，用户盘已保留"
        case .harnessExit: return "Harness 已退出，请关闭并重新打开应用"
        }
    }
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
    func exportRescueDisk(into directory: URL) async throws -> URL
}

extension RuntimeDriving {
    func exportRescueDisk(into directory: URL) async throws -> URL { throw RecoveryFailure.control }
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
    private var terminalFailure = false
    @Published private(set) var diagnostics: [String] = []

    init(driver: RuntimeDriving) { self.driver = driver }

    func ensureRunning() async {
        if let startup { await startup.value; return }
        guard !driver.hasLaunched, !terminalFailure else { return }
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

    func exportRescueDisk(into directory: URL) async throws -> URL {
        guard phase != .preparing, phase != .idle else { throw RecoveryFailure.busy }
        return try await driver.exportRescueDisk(into: directory)
    }

    func pageFailed() {
        guard !terminalFailure else { return }
        phase = .failed("页面暂时无法加载，请重试连接", requiresRelaunch: false)
        record("pageLoadFailed")
    }

    func retry() async {
        guard !terminalFailure else { return }
        if driver.hasLaunched { await recoverPage() }
        else { await ensureRunning() }
    }

    private func checkConnection(reload: Bool) async {
        guard driver.hasLaunched, !terminalFailure else { return }
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
            guard !terminalFailure else { return }
            destination = url
            if reloadRequested { pageRevision += 1 }
            phase = .ready
        } catch {
            guard !terminalFailure else { return }
            let message = (error as? RecoveryFailure)?.errorDescription ?? "暂时无法连接 Harness，请重试连接"
            phase = .failed(message, requiresRelaunch: (error as? RecoveryFailure) == .control)
            record("reconnectFailed")
        }
    }

    private func receive(_ event: RuntimeEvent) {
        guard !terminalFailure else { return }
        record(event.diagnosticStage)
        switch event {
        case .booting: phase = .booting
        case .loadingHarness: phase = .loadingHarness
        case .ready(let url): destination = url; phase = .ready
        case .dataOperationFailed: break
        case .harnessStopped:
            phase = .failed("Harness 已停止，可重试连接；备份或恢复进行中时请等待完成", requiresRelaunch: false)
        case .exited:
            terminalFailure = true
            phase = .failed("运行环境已退出，请关闭并重新打开应用", requiresRelaunch: true)
        case .connectionUnavailable:
            phase = .failed("Harness 尚未就绪，请重试连接", requiresRelaunch: false)
        case .bootFailed(let failure):
            terminalFailure = true
            phase = .failed(failure.message, requiresRelaunch: true)
        }
    }

    private func record(_ event: String) {
        diagnostics.append(event)
        if diagnostics.count > 40 { diagnostics.removeFirst() }
    }
}
