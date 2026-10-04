import BackgroundTasks
import UIKit

/// Best effort only for an explicit user backup/restore; expiration cancels host I/O.
@MainActor
final class BackgroundDataWork {
    private static let prefix = "org.lvivvde.harness.ipad.data"
    private static var registered = false
    private static var active: [String: BackgroundDataWork] = [:]
    private let identifier = prefix + "." + UUID().uuidString
    private var task: BGTask?
    private var legacy: UIBackgroundTaskIdentifier = .invalid
    private var finished = false
    private let cancel: () -> Void
    let session: URLSession
    private let reporter: DataProgressReporter

    static func register() {
        guard #available(iOS 26.0, *), !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + ".*", using: .main) { task in
            Task { @MainActor in
                guard let work = active[task.identifier], !work.finished else { task.setTaskCompleted(success: true); return }
                work.task = task
                work.endLegacyLease()
                if let continued = task as? BGContinuedProcessingTask {
                    continued.progress.totalUnitCount = 100
                    continued.progress.completedUnitCount = 1
                }
                task.expirationHandler = { Task { @MainActor in work.cancel(); work.finish(success: false) } }
            }
        }
    }

    init(title: String, cancel: @escaping () -> Void) {
        self.cancel = cancel
        reporter = DataProgressReporter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration, delegate: reporter, delegateQueue: nil)
        reporter.changed = { [weak self] sent, total in
            Task { @MainActor in self?.update(bytes: sent, total: total) }
        }
        Self.active[identifier] = self
        legacy = UIApplication.shared.beginBackgroundTask(withName: "harness-data") { [weak self] in
            guard let self else { return }
            if self.task == nil { self.cancel(); self.finish(success: false) }
            else { self.endLegacyLease() }
        }
        if #available(iOS 26.0, *), Self.registered {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "完成后数据会保留；系统可能中断任务")
            request.strategy = .fail
            // No queued retry after the user's operation has already finished.
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    private func update(bytes: Int64, total: Int64) {
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            let estimate = total > 0 ? total : bytes + 1024 * 1024
            continued.progress.completedUnitCount = max(1, min(95, bytes * 95 / max(1, estimate)))
        }
    }
    private func endLegacyLease() {
        if legacy != .invalid { UIApplication.shared.endBackgroundTask(legacy); legacy = .invalid }
    }
    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask, success { continued.progress.completedUnitCount = 100 }
        task?.setTaskCompleted(success: success)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        endLegacyLease()
        session.finishTasksAndInvalidate()
        Self.active.removeValue(forKey: identifier)
    }
}

private final class DataProgressReporter: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    var changed: ((Int64, Int64) -> Void)?
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { changed?(totalBytesWritten, totalBytesExpectedToWrite) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { changed?(totalBytesSent, totalBytesExpectedToSend) }
}
