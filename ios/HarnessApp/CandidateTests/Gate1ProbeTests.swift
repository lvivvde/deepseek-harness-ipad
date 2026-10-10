import Foundation
import XCTest
import HarnessCandidate
import HarnessHost

/// The gate 1 probe on a fake guest: its writer appends to the 9P share and then holds until the test
/// lets it go, the way a killed App leaves a real one.
final class Gate1ProbeTests: XCTestCase {
    final class HoldingMachine: GuestMachine, GuestRPC, @unchecked Sendable {
        let lock = NSLock()
        let held = DispatchSemaphore(value: 0)
        var share: String?
        var commands: [String] = []
        var onExit: ((Int32?) -> Void)?
        var rpc: GuestRPC { self }
        var exited: Bool { false }
        func boot(workspace: String) throws { lock.lock(); share = workspace; lock.unlock() }
        func stop() {}

        func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
            lock.lock()
            guard let share else { lock.unlock(); throw GuestRPCError.unreachable("down") }
            let identity = (try? String(contentsOfFile: share + "/.plan500-identity", encoding: .utf8)) ?? ""
            switch route {
            case "/ready":
                lock.unlock()
                return ["protocol": 1, "projectId": identity, "mount": "9p", "workspaceReadOnly": true, "cgroupKill": true]
            case "/execute":
                let command = (body?["argv"] as? [String])?.last ?? ""
                if command == "cat /workspace/.dsh-mount-check" {
                    lock.unlock()
                    let text = (try? String(contentsOfFile: share + "/.dsh-mount-check", encoding: .utf8)) ?? ""
                    return ["code": 0, "stdout": text, "stderr": "", "writerQuiescent": true]
                }
                commands.append(command)
                lock.unlock()
                if command.hasPrefix("echo run >> runs.txt") {
                    let runs = share + "/runs.txt"
                    let old = FileManager.default.contents(atPath: runs) ?? Data()
                    // Like the shell's `>>`: the file exists, empty, a moment before the line lands.
                    FileManager.default.createFile(atPath: runs, contents: old)
                    usleep(50_000)
                    FileManager.default.createFile(atPath: runs, contents: old + Data("run\n".utf8))
                    held.wait()
                }
                return ["code": 0, "stdout": "", "stderr": "", "writerQuiescent": true]
            default:
                lock.unlock()
                return ["bound": true, "revoked": true]
            }
        }
    }

    var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "gate1-probe-" + UUID().uuidString
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func host(_ machine: HoldingMachine) throws -> CandidateHost {
        try CandidateHost(registry: ProjectRegistry(root: root), machine: machine, availability: .available,
                          gitScripts: CandidateHostTests.gitScripts(), pollInterval: 0.01)
    }

    var timing: Gate1Probe.Timing {
        var timing = Gate1Probe.Timing()
        timing.ready = 10; timing.writer = 10; timing.settle = 0.2; timing.poll = 0.01
        return timing
    }

    func testAKilledWriterComesBackUnknownWithoutReplayAndKeepsTheDraft() throws {
        let first = HoldingMachine()
        defer { first.held.signal() }
        let hold = Gate1Probe.run(.hold, host: try host(first), timing: timing)
        XCTAssertEqual(hold["phase.open"] as? String, "READY", "\(hold)")
        XCTAssertEqual(hold["runs.hold"] as? String, "run\n", "\(hold)")
        XCTAssertEqual(hold["write"] as? String, "WORKSPACE_DRAFT_HELD")
        XCTAssertEqual(hold["draft.matches"] as? Bool, true)
        XCTAssertEqual(hold["workspace.hasDraft"] as? Bool, false, "the native write waits as a draft")
        XCTAssertEqual(hold["writerUnknown.hold"] as? Bool, false)
        XCTAssertEqual(hold["holding"] as? Bool, true)
        XCTAssertEqual(hold["passed"] as? Bool, true)

        // The next launch: a new host and guest over the same data, the old writer never heard from again.
        let second = HoldingMachine()
        let check = Gate1Probe.run(.check, host: try host(second), timing: timing)
        XCTAssertEqual(check["project"] as? String, hold["project"] as? String)
        XCTAssertEqual(check["writerUnknown.open"] as? Bool, true, "\(check)")
        XCTAssertEqual(check["writerUnknown.settled"] as? Bool, true, "never released by itself")
        XCTAssertEqual(check["command.during"] as? String, "REFUSED:WRITER_UNKNOWN")
        XCTAssertEqual(check["runs.check"] as? String, "run\n", "the command is not replayed")
        XCTAssertEqual(check["drafts"] as? [String: String], hold["drafts"] as? [String: String], "byte-identical drafts")
        XCTAssertEqual(check["draft.matches"] as? Bool, true)
        XCTAssertEqual(check["workspace.hasDraft"] as? Bool, false)
        XCTAssertEqual(check["drafts.unchanged"] as? Bool, true)
        XCTAssertEqual(check["passed"] as? Bool, true)
        XCTAssertTrue(second.commands.isEmpty, "nothing reaches the new guest while the writer is unknown")

        let recorded = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/probe/gate1-check.json")))
        XCTAssertEqual((recorded as? [String: Any])?["phase"] as? String, "check")
    }

    func testCheckWithoutAHoldRecordFails() throws {
        let check = Gate1Probe.run(.check, host: try host(HoldingMachine()), timing: timing)
        XCTAssertEqual(check["failure"] as? String, "NO_HOLD_RECORD")
    }
}
