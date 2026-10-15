import Foundation
import XCTest
import HarnessCandidate
import HarnessHost

/// The measurement probe on a fake guest that runs each command in the shared directory with the Mac's
/// shell and answers `/ready` only after a delay, so Linux is still preparing when the probe acts. Its
/// terminal runs each line with the same shell and is idle once the line ends; stopping it ends every
/// command, as a VM exit does.
final class MeasureProbeTests: XCTestCase {
    final class ShellMachine: GuestMachine, GuestRPC, @unchecked Sendable {
        let lock = NSLock()
        let readyAfter: TimeInterval
        var share: String?
        var bootedAt: Date?
        var ended = false
        var onExit: ((Int32?) -> Void)?
        var running: [String: Process] = [:]
        var cancelled = Set<String>()
        /// Per terminal: the fence it holds, and whether a line still runs in it.
        var terminals: [String: (fence: Int?, busy: Bool)] = [:]
        /// Per terminal: what its lines printed, read back by offset.
        var printed: [String: Data] = [:]
        var rpc: GuestRPC { self }
        var exited: Bool { lock.lock(); defer { lock.unlock() }; return ended }

        init(readyAfter: TimeInterval) { self.readyAfter = readyAfter }

        func boot(workspace: String) throws { lock.lock(); share = workspace; bootedAt = Date(); lock.unlock() }

        func stop() {
            lock.lock(); let first = !ended; ended = true; let left = running.values; terminals = [:]; lock.unlock()
            left.forEach { $0.terminate() }
            if first { onExit?(9) }
        }

        private func shell(_ line: String, in cwd: String, output: Pipe?) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", line]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardOutput = output ?? FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }

        func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
            lock.lock()
            guard let share, let bootedAt, !ended else { lock.unlock(); throw GuestRPCError.unreachable("down") }
            lock.unlock()
            let identity = (try? String(contentsOfFile: share + "/.plan500-identity", encoding: .utf8)) ?? ""
            switch route {
            case "/ready":
                guard Date().timeIntervalSince(bootedAt) >= readyAfter else { throw GuestRPCError.unreachable("booting") }
                return ["protocol": 1, "projectId": identity, "mount": "9p", "workspaceReadOnly": true, "cgroupKill": true]
            case "/execute":
                let request = body ?? [:]
                guard request["projectId"] as? String == identity else { throw GuestRPCError.refused("PROJECT_REFUSED") }
                let id = request["id"] as? String ?? ""
                let cwd = (request["cwd"] as? String ?? "/workspace").replacingOccurrences(of: "/workspace", with: share)
                let output = Pipe()
                // Absolute guest paths (the host's mount check) read the share.
                let process = try shell(((request["argv"] as? [String])?.last ?? "").replacingOccurrences(of: "/workspace", with: share),
                                        in: cwd, output: output)
                lock.lock(); running[id] = process; lock.unlock()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                lock.lock(); running[id] = nil; let gone = ended, stopped = cancelled.contains(id); lock.unlock()
                if gone { throw GuestRPCError.unreachable("down") }
                var answer: [String: Any] = ["code": Int(process.terminationStatus), "stdout": String(decoding: data, as: UTF8.self),
                                             "stderr": "", "writerQuiescent": true, "cancelled": stopped]
                if request["join"] != nil { answer["joined"] = true }
                return answer
            case "/cancel":
                let id = body?["id"] as? String ?? ""
                lock.lock(); cancelled.insert(id); let process = running[id]; lock.unlock()
                process?.terminate()
                return ["cancelled": process != nil]
            case "/terminal/open":
                lock.lock(); terminals[body?["id"] as? String ?? ""] = (nil, false); lock.unlock()
                return ["pid": 1]
            case "/terminal/write":
                let id = body?["id"] as? String ?? ""
                let line = String(decoding: Data(base64Encoded: body?["data"] as? String ?? "") ?? Data(), as: UTF8.self)
                let fence = (body?["lease"] as? [String: Any])?["fence"] as? Int
                lock.lock()
                guard terminals[id] != nil else { lock.unlock(); throw GuestRPCError.refused("TERMINAL_NOT_FOUND") }
                if let fence { terminals[id]?.fence = fence }
                terminals[id]?.busy = true
                lock.unlock()
                let pipe = Pipe()
                let process = try shell(line, in: share, output: pipe)
                Thread.detachNewThread { [self] in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    lock.lock(); printed[id, default: Data()].append(data); terminals[id]?.busy = false; lock.unlock()
                }
                return ["leased": fence != nil]
            case "/terminal/read":
                let id = body?["id"] as? String ?? ""
                let deadline = Date().addingTimeInterval(Double(body?["waitMs"] as? Int ?? 0) / 1000)
                while true {
                    lock.lock(); let terminal = terminals[id]; let all = printed[id] ?? Data(); lock.unlock()
                    guard let terminal else { throw GuestRPCError.refused("TERMINAL_NOT_FOUND") }
                    let releasable = terminal.fence != nil && !terminal.busy
                    let offset = min(body?["offset"] as? Int ?? 0, all.count)
                    if releasable || offset < all.count || Date() >= deadline {
                        return ["data": all.suffix(from: offset).base64EncodedString(), "next": all.count,
                                "leased": terminal.fence != nil, "releasable": releasable,
                                "activity": ["state": terminal.busy ? "busy" : "idle", "revision": 0]]
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            case "/terminal/unlease":
                let id = body?["id"] as? String ?? ""
                lock.lock(); defer { lock.unlock() }
                guard terminals[id]?.busy == false else { return ["writerQuiescent": false] }
                terminals[id]?.fence = nil
                return ["writerQuiescent": true]
            case "/terminal/close":
                let id = body?["id"] as? String ?? ""
                lock.lock(); let fence = terminals.removeValue(forKey: id)?.fence; lock.unlock()
                return ["closed": true, "releasedFence": fence as Any? ?? NSNull()]
            default:
                return ["bound": true, "revoked": true]
            }
        }
    }

    var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "measure-probe-" + UUID().uuidString
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func host(readyAfter: TimeInterval, machine: ShellMachine? = nil) throws -> CandidateHost {
        try CandidateHost(registry: ProjectRegistry(root: root), machine: machine ?? ShellMachine(readyAfter: readyAfter), availability: .available,
                          gitScripts: CandidateHostTests.gitScripts(), pollInterval: 0.01)
    }

    func timing() -> MeasureProbe.Timing {
        var timing = MeasureProbe.Timing()
        timing.ready = 30; timing.poll = 0.01; timing.background = 0.3; timing.tick = 0.1; timing.line = 20
        return timing
    }

    func saved(_ phase: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: root + "/probe/measure-\(phase).json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testColdMeasuresReadyCommandsWatchAndStorage() throws {
        let record = MeasureProbe.run(.cold, host: try host(readyAfter: 0.2), bundle: root + "/projects", timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertGreaterThanOrEqual(record["linuxReadyMs"] as? Int ?? 0, 200)
        XCTAssertEqual((record["warmCommandMs"] as? [Int])?.count, 5)
        XCTAssertNotNil((record["memory"] as? [String: Any])?["peakMB"])
        XCTAssertNotNil(((record["storage"] as? [String: Any])?["rootMB"] as? [String: Int])?["projects"])
        XCTAssertEqual(try saved("cold")["passed"] as? Bool, true)
        // A second launch reuses the project and still gets fresh operation ids.
        XCTAssertEqual(MeasureProbe.run(.cold, host: try host(readyAfter: 0), timing: timing())["firstCommand"] as? String, "COMPLETED")
    }

    func testSchedulingHoldsCommandsUntilReadyRefusesOverlapAndCancelsBeforeDispatch() throws {
        let record = MeasureProbe.run(.scheduling, host: try host(readyAfter: 1.5), timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertEqual(record["cancelled"] as? String, "CANCELLED_BEFORE_DISPATCH")
        XCTAssertEqual(record["cancelledRan"] as? Bool, false)
        XCTAssertEqual(record["bootCount"] as? Int, 1)
        // Every command waited out the 1.5 s preparation before it ran or was refused.
        XCTAssertTrue((record["commands"] as? [[String: Any]] ?? []).allSatisfy { ($0["endMs"] as? Int ?? 0) >= 1400 })
        XCTAssertEqual((record["concurrent.completed"] as? Int ?? 0) + (record["concurrent.leaseBusy"] as? Int ?? 0), 3)
    }

    func testLifecycleBindsOneProjectAndAnExitFailsLinuxForTheProcess() throws {
        let record = MeasureProbe.run(.lifecycle, host: try host(readyAfter: 0), timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertEqual(record["native.boots"] as? Int, 0)
        XCTAssertEqual(record["exit.phase"] as? String, "FAILED")
    }

    func testBackgroundTicksUntilTheDurationEnds() throws {
        let record = MeasureProbe.run(.background, host: try host(readyAfter: 0), timing: timing())
        XCTAssertGreaterThanOrEqual((record["ticks"] as? [[String: Any]])?.count ?? 0, 2, "\(record)")
        XCTAssertEqual(record["failedTicks"] as? Int, 0)
    }

    func testBackgroundIdleSendsNothingDuringTheQuietWindow() throws {
        var timing = timing(); timing.background = 0.6; timing.quiet = 0.1...0.4
        let record = MeasureProbe.run(.backgroundIdle, host: try host(readyAfter: 0), timing: timing)
        let at = (record["ticks"] as? [[String: Any]] ?? []).compactMap { $0["atMs"] as? Int }
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertFalse(at.contains { (110...390).contains($0) }, "\(at)")
        XCTAssertTrue(at.contains { $0 >= 400 }, "\(at)")
        XCTAssertEqual(try saved("background-idle")["done"] as? Bool, true)
    }

    func testImportedWaitsForTheProjectThenSeesEveryEntryAndWrites() throws {
        let host = try host(readyAfter: 0.2)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            guard let project = try? host.registry.create(name: "demo", pluginEnabled: true) else { return }
            let workspace = host.registry.workspace(project)
            try? FileManager.default.createDirectory(atPath: workspace + "/src", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: workspace + "/src/a.txt", contents: Data("a".utf8))
            try? FileManager.default.createSymbolicLink(atPath: workspace + "/link", withDestinationPath: "missing")
        }
        let record = MeasureProbe.run(.imported, host: host, project: "demo", timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertEqual(record["pluginEnabled"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(record["guestEntries"] as? Int ?? 0, 3)
        XCTAssertEqual(MeasureProbe.run(.imported, host: try self.host(readyAfter: 0), project: "absent", timing: {
            var short = timing(); short.ready = 0.2; return short }())["failure"] as? String, "PROJECT_UNKNOWN")
    }

    func testExecutionSettlesCancelsTerminalLeasesAndAVMExit() throws {
        let record = MeasureProbe.run(.execution, host: try host(readyAfter: 0), timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertEqual(record["early.again"] as? String, "REFUSED:DUPLICATE_OPERATION")
        XCTAssertEqual(record["running.cancel"] as? String, "CANCEL_REQUESTED")
        XCTAssertEqual(record["join.command"] as? String, "COMPLETED")
        XCTAssertEqual(record["close.lateWrite"] as? String, "TERMINAL_NOT_FOUND")
        XCTAssertEqual(record["exit.writerUnknown"] as? Bool, false)
        XCTAssertEqual(record["exit.nativeWrite"] as? String, "create")
    }

    func testAWriterLeftByAnEarlierLaunchOutlivesThisLaunchsVMExit() throws {
        var timing = timing(); timing.hold = 30
        let machine = ShellMachine(readyAfter: 0)
        let earlier = try host(readyAfter: 0, machine: machine)
        let held = MeasureProbe.run(.executionHold, host: earlier, timing: timing)
        XCTAssertEqual(held["passed"] as? Bool, true, "\(held)")
        // A second host on the same data root stands in for the next launch; the first one's command still runs.
        let record = MeasureProbe.run(.executionStale, host: try host(readyAfter: 0), project: held["project"] as? String, timing: timing)
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertEqual(record["missed"] as? [String], [])
        XCTAssertEqual(record["stale.command"] as? String, "REFUSED:WRITER_UNKNOWN")
        XCTAssertEqual(record["exit.writerUnknown"] as? Bool, true)
        XCTAssertEqual(record["release"] as? String, "RELEASED")
        machine.stop()
    }

    func testNetworkPassesOnlyWhenEveryCheckExitsZero() throws {
        let checks = [MeasureProbe.NetworkCheck("reach", "true"), MeasureProbe.NetworkCheck("refused", "exit 3")]
        let record = MeasureProbe.run(.network, host: try host(readyAfter: 0.2), timing: timing(), network: checks)
        XCTAssertEqual(record["passed"] as? Bool, false, "\(record)")
        XCTAssertEqual(record["reach.exitCode"] as? Int, 0)
        XCTAssertEqual(record["refused.exitCode"] as? Int, 3)
        XCTAssertNotNil(record["hostLoopback.exitCode"])
        XCTAssertEqual(try saved("network")["passed"] as? Bool, false)
        let again = MeasureProbe.run(.network, host: try host(readyAfter: 0), timing: timing(), network: [checks[0]])
        XCTAssertEqual(again["passed"] as? Bool, true, "\(again)")
    }

    func testGitFetchNeedsARemote() throws {
        let record = MeasureProbe.run(.gitFetch, host: try host(readyAfter: 0), project: "demo", timing: timing())
        XCTAssertEqual(record["failure"] as? String, "REMOTE_MISSING")
    }

    /// A project holding a clone of a bare remote, with a pre-commit hook that runs `hook`, and an edit.
    func cloned(_ host: CandidateHost, hook: String) throws -> (String, String) {
        let project = try host.registry.create(name: "acc", pluginEnabled: true)
        let workspace = host.registry.workspace(project), remote = root + "/remote.git"
        let setup = """
            git init -q --bare -b main '\(remote)' && git init -q -b main && git remote add origin '\(remote)'
            git config user.name test && git config user.email test@invalid && git config core.hooksPath .githooks
            mkdir .githooks && printf '#!/bin/sh\\n%s\\n' '\(hook)' > .githooks/pre-commit && chmod +x .githooks/pre-commit
            echo a > a.txt && git add -A && git commit -q --no-verify -m seed && git push -q origin main 2>/dev/null
            echo b > a.txt
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-ec", setup]
        process.currentDirectoryURL = URL(fileURLWithPath: workspace)
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (workspace, remote)
    }

    func testGitPushCommitsWhileLinuxPreparesAndSeesTheUsersPush() throws {
        let host = try host(readyAfter: 0.5)
        let (workspace, _) = try cloned(host, hook: "grep -q b a.txt")
        // Stands in for the user's push in the App's terminal, once the probe waits for it.
        DispatchQueue.global().async {
            while (try? self.saved("git-push"))?["state"] as? String != "waiting-push" { Thread.sleep(forTimeInterval: 0.05) }
            let push = Process()
            push.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            push.arguments = ["-C", workspace, "push", "-q", "origin", "main"]
            try? push.run(); push.waitUntilExit()
        }
        let record = MeasureProbe.run(.gitPush, host: host, project: "acc", timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertEqual(record["commit.phaseAtSubmit"] as? String, "PREPARING")
        XCTAssertGreaterThanOrEqual(record["commit.ms"] as? Int ?? 0, record["linuxReadyMs"] as? Int ?? .max)
    }

    func testGitPushLeavesHeadWhenTheHookFails() throws {
        let host = try host(readyAfter: 0)
        let (workspace, _) = try cloned(host, hook: "exit 1")
        let before = try String(contentsOfFile: workspace + "/.git/refs/heads/main", encoding: .utf8)
        var short = timing(); short.user = 0.5
        let record = MeasureProbe.run(.gitPush, host: host, project: "acc", timing: short)
        XCTAssertEqual(record["passed"] as? Bool, false, "\(record)")
        XCTAssertEqual(record["commit.exitCode"] as? Int, 1)
        XCTAssertEqual(record["head.moved"] as? Bool, false)
        XCTAssertEqual(try String(contentsOfFile: workspace + "/.git/refs/heads/main", encoding: .utf8), before)
        XCTAssertEqual(record["missed"] as? [String], ["clean", "commit.exitCode", "head.moved", "head.parent", "push.seen"])
    }

    func testGitKeepFindsHistoryOriginAndNoStoredCredential() throws {
        let host = try host(readyAfter: 0.2)
        let (workspace, remote) = try cloned(host, hook: "true")
        // The Mac's own Git config may name a helper; the guest has none of it.
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1); setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        defer { unsetenv("GIT_CONFIG_GLOBAL"); unsetenv("GIT_CONFIG_NOSYSTEM") }
        try FileHandle(forWritingTo: URL(fileURLWithPath: workspace + "/.git/info/exclude")).seekToEndAndWrite(".dsh-*\n.plan500-*\n")
        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commit.arguments = ["-C", workspace, "commit", "-qam", "edit"]
        try commit.run(); commit.waitUntilExit()
        let record = MeasureProbe.run(.gitKeep, host: host, project: "acc", remote: remote, timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, true, "\(record)")
        XCTAssertEqual(record["commits"] as? Int, 2)
        XCTAssertEqual(record["fsck.exitCode"] as? Int, 0)
        XCTAssertEqual(record["tokens.found"] as? [String], [])
        XCTAssertGreaterThan(record["tokens.files"] as? Int ?? 0, 0)
    }

    func testGitKeepFailsOnAStoredTokenOrAnotherOrigin() throws {
        let host = try host(readyAfter: 0)
        let (workspace, _) = try cloned(host, hook: "true")
        let leak = host.registry.root + "/logs/terminal.log"
        try FileManager.default.createDirectory(atPath: host.registry.root + "/logs", withIntermediateDirectories: true)
        try Data(("Password: " + MeasureProbe.tokenPrefixes[0] + "EXAMPLEONLY\n").utf8).write(to: URL(fileURLWithPath: leak))
        try Data("[credential]\n\thelper = store\n".utf8).write(to: URL(fileURLWithPath: workspace + "/.git/config"), options: .init())
        let record = MeasureProbe.run(.gitKeep, host: host, project: "acc", remote: "https://example.invalid/other.git", timing: timing())
        XCTAssertEqual(record["passed"] as? Bool, false, "\(record)")
        XCTAssertEqual(record["tokens.found"] as? [String], ["logs/terminal.log"])
        XCTAssertEqual(record["credential.helper"] as? Bool, true)
        XCTAssertEqual(record["missed"] as? [String], ["clean", "credential.helper", "origin.same", "tokens.found"])
    }
}

private extension FileHandle {
    func seekToEndAndWrite(_ text: String) throws {
        try seekToEnd(); try write(contentsOf: Data(text.utf8)); try close()
    }
}
