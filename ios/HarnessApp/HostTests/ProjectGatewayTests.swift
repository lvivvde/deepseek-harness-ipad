import Foundation
import XCTest
import HarnessHost
import LinuxPlugin
import NativeWorkspace

/// The formal gateway: one durable writer contract between native edits and Linux commands
/// (ADR 0003), driven against a fake guest that answers like the lease agent.
final class ProjectGatewayTests: XCTestCase {
    /// Answers RPCs like the guest agent. `/execute` runs the test's writer, then waits for `finish`.
    final class FakeGuest: GuestRPC, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(String, [String: Any]?)] = []
        let finish = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        var handlers: [String: ([String: Any]?) throws -> [String: Any]] = [:]
        var writer: () -> Void = {}
        var answer: [String: Any] = ["code": 0, "stdout": "ok\n", "stderr": "", "cancelled": false, "timeout": false,
                                     "writerQuiescent": true]

        var routes: [String] { lock.lock(); defer { lock.unlock() }; return log.map(\.0) }
        func bodies(_ route: String) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }; return log.filter { $0.0 == route }.compactMap(\.1)
        }

        func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
            lock.lock(); log.append((route, body)); let handler = handlers[route]; lock.unlock()
            if let handler { return try handler(body) }
            switch route {
            case "/bind": return ["epoch": body?["epoch"] ?? 0, "lastFence": 0, "generation": 0]
            case "/notify": return ["generation": (body?["entries"] as? [[String: Any]])?.last?["generation"] ?? 0]
            case "/execute":
                writer(); started.signal(); finish.wait()
                return answer
            default: throw GuestRPCError.refused("ROUTE_REFUSED")
            }
        }
    }

    var root = "", workspace = "", state = ""
    let present = LinuxAvailability.detect { _ in true }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "project-gateway-tests-" + UUID().uuidString
        workspace = root + "/workspace"; state = root + "/state"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        try "v0".write(toFile: workspace + "/notes.md", atomically: false, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    /// A plugin bound to project "A" and a gateway for it, before Linux is ready.
    func preparingGateway(_ guest: FakeGuest, launcher: @escaping (String) throws -> Void,
                          cancelWindow: TimeInterval = 2) throws -> (ProjectGateway, LinuxPlugin) {
        let store = try WorkspaceStore(workspace: workspace, state: state)
        let plugin = LinuxPlugin(availability: present, launcher: launcher)
        let gateway = ProjectGateway(project: "A", store: store, plugin: plugin, rpc: guest, cancelWindow: cancelWindow)
        _ = plugin.open(project: "A", pluginEnabled: true)
        return (gateway, plugin)
    }

    /// A ready plugin bound to project "A" and a gateway attached to the fake guest.
    func readyGateway(_ guest: FakeGuest, cancelWindow: TimeInterval = 2) throws -> (ProjectGateway, LinuxPlugin) {
        let (gateway, plugin) = try preparingGateway(guest, launcher: { _ in }, cancelWindow: cancelWindow)
        let deadline = Date().addingTimeInterval(5)
        while plugin.phase(of: "A") != .ready, Date() < deadline { usleep(1_000) }
        try gateway.attach()
        return (gateway, plugin)
    }

    func file(_ name: String) -> String? { try? String(contentsOfFile: workspace + "/" + name, encoding: .utf8) }

    func inBackground<T>(_ work: @escaping () -> T) -> () -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = NSMutableArray()
        DispatchQueue.global().async { box.add(work()); done.signal() }
        return { done.wait(timeout: .now() + 5) == .success ? box.firstObject as? T : nil }
    }

    func testCommandRunsUnderTheLeaseAndNativeWritesMeanwhileBecomeDrafts() throws {
        let guest = FakeGuest()
        guest.writer = { [workspace] in try? "built".write(toFile: workspace + "/out.txt", atomically: false, encoding: .utf8) }
        let (gateway, _) = try readyGateway(guest)
        guard case .read(_, let base) = try gateway.nativeRead(RelativePath("notes.md")) else { return XCTFail("read") }
        let result = inBackground { gateway.execute("op-1", task: .shell("make"), argv: ["/bin/sh", "-c", "make"], timeoutMs: 5000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)

        guard case .draftHeld = try gateway.nativeWrite(RelativePath("notes.md"), Data("native".utf8), base: base) else {
            return XCTFail("a native write during the lease is held as a draft")
        }
        XCTAssertEqual(file("notes.md"), "v0")
        guest.finish.signal()

        guard case .completed(let command, let release)? = result() else { return XCTFail("completed") }
        XCTAssertEqual(command.exitCode, 0)
        XCTAssertEqual(command.stdout, "ok\n")
        XCTAssertEqual(release.changed, [RelativePath("out.txt")])
        XCTAssertEqual(release.drafts.map(\.status), [.applied])
        XCTAssertEqual(file("notes.md"), "native")
        XCTAssertNil(gateway.lease)

        let request = try XCTUnwrap(guest.bodies("/execute").first)
        XCTAssertEqual(request["projectId"] as? String, "A")
        XCTAssertEqual(request["argv"] as? [String], ["/bin/sh", "-c", "make"])
        let lease = try XCTUnwrap(request["lease"] as? [String: Int])
        XCTAssertEqual(lease["epoch"], guest.bodies("/bind").first?["epoch"] as? Int, "the guest checks the bound epoch")
        XCTAssertEqual(lease["fence"], 1)
    }

    func testGuestRefusalBeforeSpawnReleasesTheLeaseWithNothingChanged() throws {
        let guest = FakeGuest()
        guest.handlers["/execute"] = { _ in throw GuestRPCError.refused("ARGV_REFUSED") }
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.execute("op-1", task: .shell("x"), argv: ["/usr/bin/x"], timeoutMs: 1000), .refused("ARGV_REFUSED"))
        XCTAssertNil(gateway.lease)
        guard case .read(_, let base) = try gateway.nativeRead(RelativePath("notes.md")),
              case .written = try gateway.nativeWrite(RelativePath("notes.md"), Data("v1".utf8), base: base) else {
            return XCTFail("native writes land directly once the lease is gone")
        }
    }

    func testDisconnectKeepsTheWriterUnknownDurablyAndNeverReplays() throws {
        let guest = FakeGuest()
        guest.handlers["/execute"] = { _ in throw GuestRPCError.unreachable("SEVERED") }
        let (gateway, _) = try readyGateway(guest)
        guard case .read(_, let base) = try gateway.nativeRead(RelativePath("notes.md")) else { return XCTFail("read") }
        XCTAssertEqual(gateway.execute("op-1", task: .git("commit"), argv: ["/usr/bin/git", "commit"], timeoutMs: 1000),
                       .writerUnknown(nil))
        XCTAssertEqual(gateway.lease?.state, .writerUnknown)
        guard case .draftHeld = try gateway.nativeWrite(RelativePath("notes.md"), Data("native".utf8), base: base) else {
            return XCTFail("native writes stay drafts while the writer is unknown")
        }
        XCTAssertEqual(gateway.execute("op-2", task: .shell("ls"), argv: ["/bin/ls"], timeoutMs: 1000), .refused("WRITER_UNKNOWN"))
        XCTAssertEqual(guest.bodies("/execute").count, 1, "the lost command is not sent again")

        let reopened = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertEqual(reopened.lease?.state, .writerUnknown)
        XCTAssertEqual(reopened.recovery.unknownToolCalls, ["op-1"])
        XCTAssertEqual(file("notes.md"), "v0")
    }

    func testUnconfirmedDrainKeepsTheWriterUnknown() throws {
        let guest = FakeGuest()
        guest.answer["writerQuiescent"] = false
        guest.finish.signal()
        let (gateway, _) = try readyGateway(guest)
        guard case .writerUnknown(let result?) = gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 1000) else {
            return XCTFail("writer unknown with the guest's report")
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(gateway.lease?.state, .writerUnknown)
    }

    // MARK: cancel

    func testCancelWhileWaitingForReadyHasNoSideEffects() throws {
        let guest = FakeGuest(), ready = DispatchSemaphore(value: 0)
        let (gateway, plugin) = try preparingGateway(guest, launcher: { _ in ready.wait() })
        let result = inBackground { gateway.execute("op-1", task: .hook("PreToolUse"), argv: ["/bin/sh"], timeoutMs: 1000) }
        usleep(100_000)
        XCTAssertEqual(gateway.cancel("op-1"), .cancelledBeforeDispatch)
        XCTAssertEqual(result(), .cancelledBeforeDispatch)
        ready.signal()
        while plugin.phase(of: "A") != .ready { usleep(1_000) }
        XCTAssertNil(gateway.lease)
        XCTAssertFalse(guest.routes.contains("/execute"))
        XCTAssertEqual(gateway.execute("op-1", task: .shell("ls"), argv: ["/bin/ls"], timeoutMs: 1000), .refused("DUPLICATE_OPERATION"),
                       "a cancelled operation id is never run later")
        let reopened = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertTrue(reopened.recovery.unknownToolCalls.isEmpty)
    }

    func testCancelDuringDispatchAsksTheGuestAndReleasesOnceTheWriterStops() throws {
        let guest = FakeGuest()
        guest.handlers["/cancel"] = { [guest] body in
            XCTAssertEqual(body?["id"] as? String, "op-1")
            guest.answer["cancelled"] = true; guest.answer["code"] = NSNull(); guest.answer["signal"] = "SIGKILL"
            guest.finish.signal()
            return ["cancelled": true]
        }
        let (gateway, _) = try readyGateway(guest)
        let result = inBackground { gateway.execute("op-1", task: .shell("sleep 60"), argv: ["/bin/sleep", "60"], timeoutMs: 60000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(gateway.cancel("op-1"), .requested)
        guard case .completed(let command, _)? = result() else { return XCTFail("the drained writer releases the lease") }
        XCTAssertTrue(command.cancelled)
        XCTAssertNil(gateway.lease)
        XCTAssertEqual(guest.bodies("/execute").count, 1)
    }

    func testCancelThatNeverReachesTheGuestLeavesTheWriterUnknown() throws {
        let guest = FakeGuest()
        guest.handlers["/cancel"] = { _ in throw GuestRPCError.unreachable("SEVERED") }
        let (gateway, _) = try readyGateway(guest, cancelWindow: 0.3)
        let result = inBackground { gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 60000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(gateway.cancel("op-1"), .writerUnknown)
        XCTAssertEqual(gateway.lease?.state, .writerUnknown)
        XCTAssertGreaterThan(guest.bodies("/cancel").count, 1, "cancel, never execute, is retried")
        XCTAssertEqual(guest.bodies("/execute").count, 1)
        guest.finish.signal()
        _ = result()
    }

    // MARK: VM exit and unknown writers

    func testVMExitSavesDiagnosticsAndReleasesTheLeaseAsGuestTerminated() throws {
        let guest = FakeGuest()
        guest.handlers["/execute"] = { [guest] _ in
            guest.started.signal(); guest.finish.wait(); throw GuestRPCError.unreachable("VM_GONE")
        }
        var saved: [LinuxPlugin.Diagnostic] = []
        let store = try WorkspaceStore(workspace: workspace, state: state)
        let plugin = LinuxPlugin(availability: present, launcher: { _ in }, diagnostics: { saved.append($0) })
        let gateway = ProjectGateway(project: "A", store: store, plugin: plugin, rpc: guest)
        _ = plugin.open(project: "A", pluginEnabled: true)
        while plugin.phase(of: "A") != .ready { usleep(1_000) }
        try gateway.attach()
        guard case .read(_, let base) = try gateway.nativeRead(RelativePath("notes.md")) else { return XCTFail("read") }
        let result = inBackground { gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 60000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)

        gateway.guestExited(status: 9)
        XCTAssertEqual(saved.map(\.code), ["LINUX_VM_EXITED"])
        XCTAssertEqual(plugin.phase(of: "A"), .failed("LINUX_VM_EXITED"))
        XCTAssertNil(gateway.lease, "a confirmed exit ends the writer")
        guest.finish.signal()
        XCTAssertEqual(result(), .writerUnknown(nil), "the command's own result is still unknown")
        XCTAssertNil(gateway.lease)
        guard case .written = try gateway.nativeWrite(RelativePath("notes.md"), Data("v1".utf8), base: base) else {
            return XCTFail("native work continues after Linux is gone")
        }
        XCTAssertEqual(try WorkspaceStore(workspace: workspace, state: state).epoch, 2, "the next guest gets a new epoch")
    }

    func testAfterRestartTheUnknownWriterIsReleasedOnlyByExplicitConfirmation() throws {
        do {
            let guest = FakeGuest()
            guest.handlers["/execute"] = { [workspace] _ in
                try? "partial".write(toFile: workspace + "/out.txt", atomically: false, encoding: .utf8)
                throw GuestRPCError.unreachable("APP_KILLED")
            }
            let (gateway, _) = try readyGateway(guest)
            guard case .read(_, let base) = try gateway.nativeRead(RelativePath("notes.md")) else { return XCTFail("read") }
            XCTAssertEqual(gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 1000), .writerUnknown(nil))
            guard case .draftHeld = try gateway.nativeWrite(RelativePath("notes.md"), Data("native".utf8), base: base) else {
                return XCTFail("draft")
            }
        }
        // A new process: the old guest died with the old App process.
        let guest = FakeGuest(); guest.finish.signal()
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.lease?.state, .writerUnknown, "not released on restart")
        XCTAssertEqual(gateway.execute("op-2", task: .shell("ls"), argv: ["/bin/ls"], timeoutMs: 1000), .refused("WRITER_UNKNOWN"))
        XCTAssertEqual(file("notes.md"), "v0")

        guard case .released(let release) = gateway.releaseUnknownWriter() else { return XCTFail("released on confirmation") }
        XCTAssertEqual(release.changed, [RelativePath("out.txt")], "what the lost writer left is committed, not rolled back")
        XCTAssertEqual(release.drafts.map(\.status), [.applied])
        XCTAssertEqual(file("notes.md"), "native")
        XCTAssertNil(gateway.lease)
        guard case .completed = gateway.execute("op-3", task: .shell("ls"), argv: ["/bin/ls"], timeoutMs: 1000) else {
            return XCTFail("Linux works again under the epoch the guest is bound to")
        }
        let lease = try XCTUnwrap(guest.bodies("/execute").last?["lease"] as? [String: Int])
        XCTAssertEqual(lease["epoch"], guest.bodies("/bind").first?["epoch"] as? Int)
    }

    func testALiveUnknownWriterIsReleasedOnlyAfterTheGuestConfirmsItStopped() throws {
        let guest = FakeGuest()
        guest.handlers["/cancel"] = { _ in throw GuestRPCError.unreachable("SEVERED") }
        var running = true
        guest.handlers["/revoke"] = { body in
            XCTAssertEqual(body?["fence"] as? Int, 1)
            return running ? ["revoked": false, "running": true] : ["revoked": true, "lastFence": 1]
        }
        let (gateway, _) = try readyGateway(guest, cancelWindow: 0.2)
        let result = inBackground { gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 60000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(gateway.cancel("op-1"), .writerUnknown)

        XCTAssertEqual(gateway.releaseUnknownWriter(), .stillRunning)
        XCTAssertEqual(gateway.lease?.state, .writerUnknown)
        guest.handlers["/revoke"] = { _ in throw GuestRPCError.unreachable("SEVERED") }
        XCTAssertEqual(gateway.releaseUnknownWriter(), .unreachable)
        guest.handlers["/revoke"] = { _ in ["revoked": true, "lastFence": 1] }
        running = false
        guard case .released = gateway.releaseUnknownWriter() else { return XCTFail("released after the guest confirmed") }
        XCTAssertNil(gateway.lease)
        guest.finish.signal()
        _ = result()
    }

    func testNothingToReleaseWithoutAnUnknownWriter() throws {
        let (gateway, _) = try readyGateway(FakeGuest())
        XCTAssertEqual(gateway.releaseUnknownWriter(), .noUnknownWriter)
    }
}
