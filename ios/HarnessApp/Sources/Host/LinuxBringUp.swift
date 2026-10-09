import Foundation
import LinuxPlugin

/// The plugin's launcher for one project: starts QEMU once, polls `/ready` until the guest proves it
/// is ready, the VM exits, or the deadline passes, then tells the guest the durable epoch. Every
/// failure is a `LinuxPlugin.LaunchFailure` with a fixed code; nothing is retried.
public struct LinuxBringUp {
    private let rpc: GuestRPC
    private let boot: (String) throws -> Void
    private let exited: () -> Bool
    private let attach: () throws -> Void
    private let readyTimeout: TimeInterval
    private let pollInterval: TimeInterval

    /// `exited` reports whether this process's QEMU has already exited; `attach` is the gateway's bind.
    public init(rpc: GuestRPC, boot: @escaping (String) throws -> Void, exited: @escaping () -> Bool,
                attach: @escaping () throws -> Void, readyTimeout: TimeInterval = 120, pollInterval: TimeInterval = 0.25) {
        self.rpc = rpc; self.boot = boot; self.exited = exited; self.attach = attach
        self.readyTimeout = readyTimeout; self.pollInterval = pollInterval
    }

    public func launch(_ project: String) throws {
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
    }
}
