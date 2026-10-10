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

    func testTheCommandRunsInTheGivenGuestDirectoryInsideTheWorkspace() throws {
        let guest = FakeGuest()
        let (gateway, _) = try readyGateway(guest)
        guest.finish.signal(); guest.finish.signal()
        _ = gateway.execute("op-1", task: .shell("ls"), argv: ["/bin/sh", "-c", "ls"], timeoutMs: 1000)
        _ = gateway.execute("op-2", task: .shell("ls"), argv: ["/bin/sh", "-c", "ls"], timeoutMs: 1000, cwd: "/workspace/src/子目录")
        XCTAssertEqual(guest.bodies("/execute").map { $0["cwd"] as? String }, ["/workspace", "/workspace/src/子目录"])
        for outside in ["/tmp", "/workspace2", "/workspace/../etc", "workspace/src"] {
            XCTAssertEqual(gateway.execute("op-" + outside, task: .shell("ls"), argv: ["/bin/sh"], timeoutMs: 1000, cwd: outside),
                           .refused("CWD_REFUSED"), outside)
        }
        XCTAssertEqual(guest.bodies("/execute").count, 2)
        XCTAssertNil(gateway.lease)
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

    func testVMExitAfterRestartLeavesTheEarlierProcessesUnknownWriterForTheUser() throws {
        do {
            let guest = FakeGuest()
            guest.handlers["/execute"] = { _ in throw GuestRPCError.unreachable("APP_KILLED") }
            let (gateway, _) = try readyGateway(guest)
            XCTAssertEqual(gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 1000), .writerUnknown(nil))
        }
        let (gateway, _) = try readyGateway(FakeGuest())
        gateway.guestExited(status: 1)
        XCTAssertEqual(gateway.lease?.state, .writerUnknown, "this VM never ran the earlier writer")
        guard case .released = gateway.releaseUnknownWriter() else { return XCTFail("still released on confirmation") }
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

    // MARK: terminal

    /// A guest terminal: writes are accepted, reads report `releasable` as the test sets it.
    func terminalGuest(_ guest: FakeGuest, releasable: @escaping () -> Bool = { true }) {
        guest.handlers["/terminal/open"] = { _ in ["id": "t1", "pid": 42, "shellActivity": true] }
        guest.handlers["/terminal/write"] = { body in ["written": 1, "leased": body?["lease"] != nil] }
        guest.handlers["/terminal/read"] = { body in
            let ready = releasable()
            return ["data": Data("$ ".utf8).base64EncodedString(), "offset": body?["offset"] ?? 0, "next": 2, "dropped": 0,
                    "exited": NSNull(), "activity": ["state": ready ? "idle" : "busy", "revision": 1], "leased": true, "releasable": ready]
        }
        guest.handlers["/terminal/unlease"] = { _ in ["writerQuiescent": true] }
    }

    func testOnlyALineRunAtThePromptTakesTheLeaseAndTheIdlePromptCommitsItsWrites() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(try gateway.openTerminal("t1", argv: ["/bin/bash", "-i"], cwd: "/workspace", cols: 80, rows: 24), 42)
        XCTAssertEqual(guest.bodies("/terminal/open").first?["shellActivity"] as? Bool, true)
        XCTAssertThrowsError(try gateway.openTerminal("t2", argv: ["/bin/sh", "-i"], cwd: "/workspace", cols: 80, rows: 24),
                             "a shell that cannot report its idle prompt would keep the lease") {
            XCTAssertEqual($0 as? TerminalError, TerminalError("ARGV_REFUSED"))
        }

        XCTAssertEqual(gateway.writeTerminal("t1", Data("printf x > out.txt".utf8)), .written(leased: false))
        XCTAssertNil(gateway.lease, "typing at the prompt holds no lease")
        XCTAssertNil(guest.bodies("/terminal/write").last?["lease"])
        guard case .read(_, let base) = try gateway.nativeRead(RelativePath("notes.md")) else { return XCTFail("read") }

        XCTAssertEqual(gateway.writeTerminal("t1", Data("\r".utf8)), .written(leased: true))
        XCTAssertEqual(gateway.lease?.operation, "terminal:t1:1")
        let sent = try XCTUnwrap(guest.bodies("/terminal/write").last?["lease"] as? [String: Int])
        XCTAssertEqual(sent["fence"], 1)
        XCTAssertEqual(sent["epoch"], guest.bodies("/bind").first?["epoch"] as? Int)
        try "x".write(toFile: workspace + "/out.txt", atomically: false, encoding: .utf8)
        guard case .draftHeld = try gateway.nativeWrite(RelativePath("notes.md"), Data("native".utf8), base: base) else {
            return XCTFail("native writes wait as drafts while the terminal command runs")
        }
        XCTAssertEqual(gateway.writeTerminal("t1", Data("more".utf8)), .written(leased: true))
        XCTAssertEqual((guest.bodies("/terminal/write").last?["lease"] as? [String: Int])?["fence"], 1, "input to a leased terminal keeps its fence")

        let read = try gateway.readTerminal("t1", offset: 0, waitMs: 1000)
        XCTAssertEqual(read.data, Data("$ ".utf8))
        XCTAssertFalse(read.leased)
        XCTAssertEqual(read.release?.changed, [RelativePath("out.txt")])
        XCTAssertEqual(read.release?.drafts.map(\.status), [.applied])
        XCTAssertEqual(guest.bodies("/terminal/unlease").first?["fence"] as? Int, 1)
        XCTAssertNil(gateway.lease)
        XCTAssertEqual(file("notes.md"), "native")

        XCTAssertEqual(gateway.writeTerminal("t1", Data("ls\r".utf8)), .written(leased: true))
        XCTAssertEqual(gateway.lease?.operation, "terminal:t1:2", "each leased run has its own ledger entry")
        let reopened = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertEqual(reopened.recovery.unknownToolCalls, ["terminal:t1:2"], "a run still holding the lease when the App stops is unknown")
    }

    func testARunLineIsRefusedAtOnceWhileAnotherWriterHoldsTheLease() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        let (gateway, _) = try readyGateway(guest)
        _ = try gateway.openTerminal("t1", argv: ["/bin/bash", "-i"], cwd: "/workspace", cols: 80, rows: 24)
        let result = inBackground { gateway.execute("op-1", task: .shell("make"), argv: ["/bin/sh", "-c", "make"], timeoutMs: 5000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("make\r".utf8)), .refused("LEASE_BUSY"))
        XCTAssertEqual(gateway.writeTerminal("t1", Data("\u{3}".utf8)), .written(leased: false), "other keys still reach the prompt")
        XCTAssertEqual(guest.bodies("/terminal/write").count, 1)
        guest.finish.signal()
        guard case .completed? = result() else { return XCTFail("the model command keeps its own lease") }
        XCTAssertEqual(gateway.writeTerminal("t1", Data("make\r".utf8)), .written(leased: true))
    }

    func testAModelCommandJoinsTheTerminalsLeaseAndTheTerminalReleasesAfterIt() throws {
        let guest = FakeGuest()
        var idle = false
        terminalGuest(guest, releasable: { idle })
        guest.answer["joined"] = true
        let (gateway, _) = try readyGateway(guest)
        _ = try gateway.openTerminal("t1", argv: ["/bin/bash", "-i"], cwd: "/workspace", cols: 80, rows: 24)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("npm run dev\r".utf8)), .written(leased: true))

        let result = inBackground { gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh", "-c", "x"], timeoutMs: 5000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)
        let request = try XCTUnwrap(guest.bodies("/execute").first)
        XCTAssertEqual(request["join"] as? String, "t1")
        XCTAssertEqual((request["lease"] as? [String: Int])?["fence"], 1)
        idle = true
        XCTAssertNil(try gateway.readTerminal("t1", offset: 0, waitMs: 0).release)
        XCTAssertTrue(guest.bodies("/terminal/unlease").isEmpty, "never released while a joined command runs")
        XCTAssertEqual(gateway.lease?.fence, 1)

        guest.finish.signal()
        guard case .joined(let command)? = result() else { return XCTFail("joined") }
        XCTAssertEqual(command.exitCode, 0)
        XCTAssertEqual(gateway.lease?.fence, 1, "the lease stays with the terminal")
        XCTAssertNotNil(try gateway.readTerminal("t1", offset: 2, waitMs: 0).release)
        XCTAssertNil(gateway.lease)
        let reopened = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertTrue(reopened.recovery.unknownToolCalls.isEmpty, "the run and the joined command both finished in the ledger")
    }

    func testAJoinedCommandWhoseCancelIsLostLeavesTheTerminalsWriterUnknown() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        guest.handlers["/cancel"] = { _ in throw GuestRPCError.unreachable("SEVERED") }
        let (gateway, _) = try readyGateway(guest, cancelWindow: 0.2)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("npm run dev\r".utf8)), .written(leased: true))
        let result = inBackground { gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 5000) }
        XCTAssertEqual(guest.started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(gateway.cancel("op-1"), .writerUnknown)
        XCTAssertEqual(gateway.lease?.state, .writerUnknown)
        _ = try gateway.readTerminal("t1", offset: 0, waitMs: 0)
        XCTAssertTrue(guest.bodies("/terminal/unlease").isEmpty, "an unknown writer is never released at the prompt")
        guest.finish.signal()
        _ = result()
    }

    func testABusyOrWriterOpenPromptKeepsTheLease() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        guest.handlers["/terminal/unlease"] = { _ in ["writerQuiescent": false, "reason": "WRITERS_OPEN"] }
        let (gateway, _) = try readyGateway(guest)
        _ = try gateway.openTerminal("t1", argv: ["/bin/bash", "-i"], cwd: "/workspace", cols: 80, rows: 24)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("exec 3>held\r".utf8)), .written(leased: true))
        let read = try gateway.readTerminal("t1", offset: 0, waitMs: 0)
        XCTAssertNil(read.release)
        XCTAssertTrue(read.leased)
        XCTAssertEqual(gateway.lease?.state, .active)
        guest.handlers["/terminal/unlease"] = { _ in throw GuestRPCError.unreachable("SEVERED") }
        XCTAssertNil(try gateway.readTerminal("t1", offset: 0, waitMs: 0).release)
        XCTAssertEqual(gateway.lease?.state, .active, "an unanswered release is asked again on the next read")
        guest.handlers["/terminal/unlease"] = { _ in ["writerQuiescent": true] }
        XCTAssertNotNil(try gateway.readTerminal("t1", offset: 0, waitMs: 0).release)
    }

    func testAGuestRefusalOfALeasedLineReleasesItUnchanged() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        guest.handlers["/terminal/write"] = { _ in throw GuestRPCError.refused("TERMINAL_EXITED") }
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("ls\r".utf8)), .refused("TERMINAL_EXITED"))
        XCTAssertNil(gateway.lease)
        let reopened = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertTrue(reopened.recovery.unknownToolCalls.isEmpty)
    }

    func testALostAnswerToALeasedLineLeavesTheWriterUnknownUntilTheTerminalIsRevoked() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        guest.handlers["/terminal/write"] = { _ in throw GuestRPCError.unreachable("SEVERED") }
        guest.handlers["/revoke"] = { _ in ["revoked": true, "lastFence": 1] }
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("ls\r".utf8)), .writerUnknown)
        XCTAssertEqual(gateway.lease?.state, .writerUnknown)
        XCTAssertEqual(gateway.execute("op-1", task: .shell("ls"), argv: ["/bin/ls"], timeoutMs: 1000), .refused("WRITER_UNKNOWN"),
                       "nothing joins a lease whose writer is unknown")
        XCTAssertEqual(gateway.writeTerminal("t1", Data("ls\r".utf8)), .refused("WRITER_UNKNOWN"))
        _ = try gateway.readTerminal("t1", offset: 0, waitMs: 0)
        XCTAssertTrue(guest.bodies("/terminal/unlease").isEmpty)
        guard case .released = gateway.releaseUnknownWriter() else { return XCTFail("the guest revokes it by ending the terminal") }
        XCTAssertEqual(guest.bodies("/revoke").first?["fence"] as? Int, 1)
        XCTAssertNil(gateway.lease)
    }

    func testClosingALeasedTerminalReleasesItsLease() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        guest.handlers["/terminal/close"] = { _ in ["closed": true, "releasedFence": 1] }
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("sleep 30\r".utf8)), .written(leased: true))
        try "x".write(toFile: workspace + "/out.txt", atomically: false, encoding: .utf8)
        XCTAssertEqual(try gateway.closeTerminal("t1")?.changed, [RelativePath("out.txt")])
        XCTAssertNil(gateway.lease)

        guest.handlers["/terminal/close"] = { _ in ["closed": false, "releasedFence": NSNull()] }
        XCTAssertEqual(gateway.writeTerminal("t2", Data("sleep 30\r".utf8)), .written(leased: true))
        XCTAssertThrowsError(try gateway.closeTerminal("t2")) { XCTAssertEqual($0 as? TerminalError, TerminalError("TERMINAL_BUSY")) }
        XCTAssertEqual(gateway.lease?.operation, "terminal:t2:1")
    }

    func testAClosedTerminalWhoseLeaseIsUnconfirmedLeavesTheWriterUnknown() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        // The first close's answer was lost; the repeat finds no terminal and reports the fence it was sent.
        guest.handlers["/terminal/close"] = { body in ["closed": true, "releasedFence": body?["fence"] ?? NSNull()] }
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("sleep 30\r".utf8)), .written(leased: true))
        XCTAssertNotNil(try gateway.closeTerminal("t1"))
        XCTAssertEqual(guest.bodies("/terminal/close").last?["fence"] as? Int, 1)
        XCTAssertNil(gateway.lease)

        guest.handlers["/terminal/close"] = { _ in ["closed": true, "releasedFence": NSNull()] }
        XCTAssertEqual(gateway.writeTerminal("t2", Data("sleep 30\r".utf8)), .written(leased: true))
        XCTAssertNil(try gateway.closeTerminal("t2"))
        XCTAssertEqual(gateway.lease?.state, .writerUnknown, "a lease nothing confirmed ended never stays active")
    }

    func testACommandWaitsForAReleaseInFlightThenTakesItsOwnLease() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        let unleasing = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        guest.handlers["/terminal/unlease"] = { _ in unleasing.signal(); proceed.wait(); return ["writerQuiescent": true] }
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("ls\r".utf8)), .written(leased: true))
        let read = inBackground { try? gateway.readTerminal("t1", offset: 0, waitMs: 0) }
        XCTAssertEqual(unleasing.wait(timeout: .now() + 5), .success)
        guest.finish.signal()
        let result = inBackground { gateway.execute("op-1", task: .shell("x"), argv: ["/bin/sh"], timeoutMs: 5000) }
        usleep(200_000)
        XCTAssertTrue(guest.bodies("/execute").isEmpty, "the command does not join a terminal that is being released")
        proceed.signal()
        XCTAssertNotNil(read()??.release)
        guard case .completed? = result() else { return XCTFail("completed under its own lease") }
        let request = try XCTUnwrap(guest.bodies("/execute").first)
        XCTAssertNil(request["join"])
        XCTAssertEqual((request["lease"] as? [String: Int])?["fence"], 2)
    }

    func testVMExitEndsTheTerminalsLease() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        let (gateway, _) = try readyGateway(guest)
        XCTAssertEqual(gateway.writeTerminal("t1", Data("ls\r".utf8)), .written(leased: true))
        gateway.guestExited(status: 9)
        XCTAssertNil(gateway.lease)
        XCTAssertEqual(try WorkspaceStore(workspace: workspace, state: state).recovery.unknownToolCalls, ["terminal:t1:1"])
    }

    func testATerminalOpensOnlyInsideTheWorkspaceOfAnEnabledProject() throws {
        let guest = FakeGuest()
        terminalGuest(guest)
        let (gateway, plugin) = try readyGateway(guest)
        XCTAssertThrowsError(try gateway.openTerminal("t1", argv: ["/bin/bash", "-i"], cwd: "/tmp", cols: 80, rows: 24)) {
            XCTAssertEqual($0 as? TerminalError, TerminalError("CWD_REFUSED"))
        }
        _ = plugin.open(project: "A", pluginEnabled: false)
        XCTAssertThrowsError(try gateway.openTerminal("t1", argv: ["/bin/bash", "-i"], cwd: "/workspace", cols: 80, rows: 24)) {
            XCTAssertEqual($0 as? TerminalError, TerminalError(LinuxPlugin.notEnabledCode))
        }
        XCTAssertTrue(guest.bodies("/terminal/open").isEmpty)
    }
}
