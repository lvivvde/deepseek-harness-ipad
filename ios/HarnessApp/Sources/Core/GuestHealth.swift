import Foundation

enum RecoveryStage: String {
    case vmRunning, guestResponded, clockSynchronized, harnessRestarting, harnessRunning, forwardRepairing, pageReady
}

struct GuestHealth: Decodable {
    let clock: Bool
    let epoch: Double
    let running: Bool
    let writable: Bool
    let restartable: Bool
    let leased: Bool?

    func clockMatches(_ date: Date) -> Bool { clock && abs(epoch / 1000 - date.timeIntervalSince1970) <= 2 }
}

enum RecoveryFailure: String, Error, LocalizedError {
    case control, guestControl, vmStopped, exited, clock, harness, readonly, busy, connection
    var errorDescription: String? {
        switch self {
        case .control: return "运行环境控制通道暂不可用，请重试连接；持续失败时关闭并重新打开应用，用户盘已保留"
        case .guestControl: return "运行环境串口健康检查未完成，请重试连接；持续失败时关闭并重新打开应用，用户盘已保留"
        case .vmStopped: return "运行环境尚未运行，请重试连接；持续失败时关闭并重新打开应用，用户盘已保留"
        case .exited: return "运行环境已退出，请关闭并重新打开应用，用户盘已保留"
        case .clock: return "运行环境时钟尚未同步，请重试连接"
        case .harness: return "Harness 尚未恢复，请重试连接或导出数据备份"
        case .readonly: return "用户盘不可写，未重启 Harness；请先导出救援数据"
        case .busy: return "正在备份或恢复用户数据，请等操作完成后再连接"
        case .connection: return "页面连接暂不可用，端口转发修复未完成；请重试连接"
        }
    }
}
