import Foundation
import XCTest
import HarnessCandidate
import HarnessHost

/// The measurement probe on a fake guest that runs each command in the shared directory with the Mac's
/// shell and answers `/ready` only after a delay, so Linux is still preparing when the probe acts.
final class MeasureProbeTests: XCTestCase {
    final class ShellMachine: GuestMachine, GuestRPC, @unchecked Sendable {
        let lock = NSLock()
        let readyAfter: TimeInterval
        var share: String?
        var bootedAt: Date?
        var ended = false
        var onExit: ((Int32?) -> Void)?
        var rpc: GuestRPC { self }
        var exited: Bool { lock.lock(); defer { lock.unlock() }; return ended }

        init(readyAfter: TimeInterval) { self.readyAfter = readyAfter }

        func boot(workspace: String) throws { lock.lock(); share = workspace; bootedAt = Date(); lock.unlock() }

        func stop() {
            lock.lock(); let first = !ended; ended = true; lock.unlock()
            if first { onExit?(9) }
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
                let cwd = (request["cwd"] as? String ?? "/workspace").replacingOccurrences(of: "/workspace", with: share)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                // Absolute guest paths (the host's mount check) read the share.
                process.arguments = ["-c", ((request["argv"] as? [String])?.last ?? "").replacingOccurrences(of: "/workspace", with: share)]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return ["code": Int(process.terminationStatus), "stdout": String(decoding: data, as: UTF8.self), "stderr": "",
                        "writerQuiescent": true]
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

    func host(readyAfter: TimeInterval) throws -> CandidateHost {
        try CandidateHost(registry: ProjectRegistry(root: root), machine: ShellMachine(readyAfter: readyAfter), availability: .available,
                          gitScripts: CandidateHostTests.gitScripts(), pollInterval: 0.01)
    }

    func timing() -> MeasureProbe.Timing {
        var timing = MeasureProbe.Timing()
        timing.ready = 30; timing.poll = 0.01; timing.background = 0.3; timing.tick = 0.1
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
}
