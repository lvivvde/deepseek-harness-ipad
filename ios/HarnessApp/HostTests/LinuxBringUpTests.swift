import Foundation
import XCTest
import HarnessHost
import LinuxPlugin

/// The plugin's launcher: Linux becomes ready only on the guest's verified proof, after the gateway
/// told the guest the durable epoch.
final class LinuxBringUpTests: XCTestCase {
    final class Guest: GuestRPC {
        var readyAfter = 3
        var proof: [String: Any] = ["protocol": 1, "projectId": "A", "mount": "9p", "workspaceReadOnly": true, "cgroupKill": true]
        var polls = 0
        func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
            XCTAssertEqual(route, "/ready")
            polls += 1
            if polls < readyAfter { throw GuestRPCError.unreachable("BOOTING") }
            return proof
        }
    }

    var boots: [String] = []
    var attaches = 0
    var checks = 0
    var stops = 0
    var exited = false

    func bringUp(_ guest: Guest, timeout: TimeInterval = 2, attach: (() throws -> Void)? = nil,
                 check: (() throws -> Void)? = nil) -> LinuxBringUp {
        LinuxBringUp(rpc: guest, boot: { self.boots.append($0) }, exited: { self.exited },
                     attach: attach ?? { self.attaches += 1 }, check: check ?? { self.checks += 1 }, stop: { self.stops += 1 },
                     readyTimeout: timeout, pollInterval: 0.01)
    }

    func code(_ work: () throws -> Void) -> String? {
        do { try work(); return nil }
        catch let failure as LinuxPlugin.LaunchFailure { return failure.code }
        catch { return "UNEXPECTED \(error)" }
    }

    func testBootsOncePollsUntilTheProofAndThenBinds() {
        let guest = Guest()
        XCTAssertNil(code { try bringUp(guest).launch("A") })
        XCTAssertEqual(boots, ["A"])
        XCTAssertEqual(guest.polls, 3)
        XCTAssertEqual(attaches, 1)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(stops, 0)
    }

    func testVMExitBeforeReadyFailsWithoutWaitingForTheDeadline() {
        let guest = Guest(); guest.readyAfter = .max
        exited = true
        let started = Date()
        XCTAssertEqual(code { try bringUp(guest, timeout: 30).launch("A") }, "VM_EXIT_BEFORE_READY")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(attaches, 0)
    }

    func testNoProofBeforeTheDeadlineFails() {
        let guest = Guest(); guest.readyAfter = .max
        XCTAssertEqual(code { try bringUp(guest, timeout: 0.1).launch("A") }, "READY_TIMEOUT")
        XCTAssertEqual(attaches, 0)
    }

    func testARefusedProofIsNeverBound() {
        let guest = Guest(); guest.proof["projectId"] = "B"
        XCTAssertEqual(code { try bringUp(guest).launch("A") }, "READY_PROJECT_MISMATCH")
        XCTAssertEqual(attaches, 0)
    }

    func testBootAndBindFailuresHaveFixedCodes() {
        XCTAssertEqual(code {
            try LinuxBringUp(rpc: Guest(), boot: { _ in throw NSError(domain: "qemu", code: 1) }, exited: { false },
                             attach: {}, readyTimeout: 1, pollInterval: 0.01).launch("A")
        }, "VM_START_FAILED")
        XCTAssertEqual(code { try bringUp(Guest(), attach: { throw GuestRPCError.refused("EPOCH_CONFLICT") }).launch("A") },
                       "BIND_REFUSED")
    }

    func testEveryFailureStopsTheVMItStarted() {
        let refused = Guest(); refused.proof["mount"] = "virtiofs"
        XCTAssertNotNil(code { try bringUp(refused).launch("A") })
        XCTAssertEqual(stops, 1)
        let silent = Guest(); silent.readyAfter = .max
        XCTAssertEqual(code { try bringUp(silent, timeout: 0.05).launch("A") }, "READY_TIMEOUT")
        XCTAssertEqual(stops, 2)
        XCTAssertEqual(code { try bringUp(Guest(), attach: { throw GuestRPCError.refused(nil) }).launch("A") }, "BIND_REFUSED")
        XCTAssertEqual(stops, 3)
        XCTAssertEqual(checks, 0, "the mount is checked only after a bound guest")
    }

    func testTheMountCheckRunsAfterBindAndItsFailureIsTheLaunchFailure() {
        var order: [String] = []
        let failure = code {
            try bringUp(Guest(), attach: { order.append("attach") },
                        check: { order.append("check"); throw LinuxPlugin.LaunchFailure("MOUNT_CHECK_FAILED") }).launch("A")
        }
        XCTAssertEqual(failure, "MOUNT_CHECK_FAILED")
        XCTAssertEqual(order, ["attach", "check"])
        XCTAssertEqual(stops, 1)
    }
}
