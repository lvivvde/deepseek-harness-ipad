import Foundation
import LinuxPlugin

/// The plugin's launcher for one project: starts QEMU once, polls `/ready` until the guest proves it
/// is ready, the VM exits, or the deadline passes, tells the guest the durable epoch, then checks the
/// mount. Every failure is a `LinuxPlugin.LaunchFailure` with a fixed code and stops the VM; nothing
/// is retried.
public struct LinuxBringUp {
    private let rpc: GuestRPC
    private let boot: (String) throws -> Void
    private let exited: () -> Bool
    private let attach: () throws -> Void
    private let check: () throws -> Void
    private let stop: () -> Void
    private let readyTimeout: TimeInterval
    private let pollInterval: TimeInterval

    /// `exited` reports whether this process's QEMU has already exited; `attach` is the gateway's bind;
    /// `check` is the `MountCheck`; `stop` ends this process's QEMU and must be idempotent.
    public init(rpc: GuestRPC, boot: @escaping (String) throws -> Void, exited: @escaping () -> Bool,
                attach: @escaping () throws -> Void, check: @escaping () throws -> Void = {}, stop: @escaping () -> Void = {},
                readyTimeout: TimeInterval = 120, pollInterval: TimeInterval = 0.25) {
        self.rpc = rpc; self.boot = boot; self.exited = exited; self.attach = attach; self.check = check; self.stop = stop
        self.readyTimeout = readyTimeout; self.pollInterval = pollInterval
    }

    public func launch(_ project: String) throws {
        do { try bringUp(project) } catch { stop(); throw error }
    }

    private func bringUp(_ project: String) throws {
        do { try boot(project) } catch { throw LinuxPlugin.LaunchFailure("VM_START_FAILED") }
        let deadline = Date().addingTimeInterval(readyTimeout)
        var answer: [String: Any]?
        while answer == nil {
            if exited() { throw LinuxPlugin.LaunchFailure("VM_EXIT_BEFORE_READY") }
            if Date() >= deadline { throw LinuxPlugin.LaunchFailure("READY_TIMEOUT") }
            answer = try? rpc.call("/ready", nil)
            if answer == nil { Thread.sleep(forTimeInterval: pollInterval) }
        }
        try ReadyProof.verify(answer!, project: project)
        do { try attach() } catch { throw LinuxPlugin.LaunchFailure("BIND_REFUSED") }
        try check()
    }
}
