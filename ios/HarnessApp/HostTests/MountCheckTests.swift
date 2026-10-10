import Foundation
import XCTest
import HarnessHost
import LinuxPlugin

/// The host-side sentinel check: the guest's `/workspace` must be this project's live share before
/// Linux is offered. The fake guest reads the sentinel through `share`, the directory it mounts.
final class MountCheckTests: XCTestCase {
    final class Guest: GuestRPC {
        var share: String
        var requests: [[String: Any]] = []
        var refuse: GuestRPCError?
        init(share: String) { self.share = share }
        func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
            XCTAssertEqual(route, "/execute")
            requests.append(body ?? [:])
            if let refuse { throw refuse }
            guard let text = try? String(contentsOfFile: share + "/.dsh-mount-check", encoding: .utf8) else {
                return ["code": 1, "stdout": "", "stderr": "cat: No such file", "writerQuiescent": true]
            }
            return ["code": 0, "stdout": text, "stderr": "", "writerQuiescent": true]
        }
    }

    var root = "", workspace = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "mount-check-tests-" + UUID().uuidString
        workspace = root + "/workspace"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func code(_ work: () throws -> Void) -> String? {
        do { try work(); return nil }
        catch let failure as LinuxPlugin.LaunchFailure { return failure.code }
        catch { return "UNEXPECTED \(error)" }
    }

    var sentinelLeft: Bool { FileManager.default.fileExists(atPath: workspace + "/.dsh-mount-check") }

    func testTheGuestReadsBackAFreshNonceAsAnUnleasedReader() throws {
        let guest = Guest(share: workspace)
        XCTAssertNil(code { try MountCheck(rpc: guest, workspace: workspace, project: "A").verify() })
        XCTAssertNil(code { try MountCheck(rpc: guest, workspace: workspace, project: "A").verify() })
        XCTAssertEqual(guest.requests.count, 2)
        let request = guest.requests[0]
        XCTAssertEqual(request["projectId"] as? String, "A")
        XCTAssertEqual(request["argv"] as? [String], ["/bin/sh", "-c", "cat /workspace/.dsh-mount-check"])
        XCTAssertEqual(request["cwd"] as? String, "/workspace")
        XCTAssertNil(request["lease"], "the check never takes the writer")
        XCTAssertNotEqual(request["id"] as? String, guest.requests[1]["id"] as? String)
        XCTAssertFalse(sentinelLeft)
    }

    func testAnotherShareFails() throws {
        let other = root + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try "stale-nonce".write(toFile: other + "/.dsh-mount-check", atomically: false, encoding: .utf8)
        XCTAssertEqual(code { try MountCheck(rpc: Guest(share: other), workspace: workspace, project: "A").verify() },
                       "MOUNT_CHECK_FAILED")
        XCTAssertEqual(code { try MountCheck(rpc: Guest(share: root + "/missing"), workspace: workspace, project: "A").verify() },
                       "MOUNT_CHECK_FAILED")
        XCTAssertFalse(sentinelLeft)
    }

    func testAGuestThatCannotRunTheCheckFails() {
        let guest = Guest(share: workspace)
        guest.refuse = .refused("ARGV_REFUSED")
        XCTAssertEqual(code { try MountCheck(rpc: guest, workspace: workspace, project: "A").verify() }, "MOUNT_CHECK_FAILED")
        guest.refuse = .unreachable("timeout")
        XCTAssertEqual(code { try MountCheck(rpc: guest, workspace: workspace, project: "A").verify() }, "MOUNT_CHECK_FAILED")
        XCTAssertFalse(sentinelLeft)
    }
}
