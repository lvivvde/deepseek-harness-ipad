import XCTest
import LinuxPlugin
import HarnessHost

/// Ready means the guest proved it: 9P mount of the right project, read-only outside a lease,
/// cgroup kill for draining a writer, and an answering RPC of the expected protocol.
final class ReadyProofTests: XCTestCase {
    let good: [String: Any] = ["protocol": 1, "projectId": "A", "mount": "9p", "workspaceReadOnly": true,
                               "cgroupKill": true, "node": "v22.0.0"]

    func refusal(_ change: [String: Any], project: String = "A") -> String? {
        do { try ReadyProof.verify(good.merging(change) { $1 }, project: project); return nil }
        catch let failure as LinuxPlugin.LaunchFailure { return failure.code }
        catch { return "UNEXPECTED" }
    }

    func testCompleteProofOfTheOpenedProjectIsReady() {
        XCTAssertNil(refusal([:]))
    }

    func testEachMissingConditionIsRefusedWithAFixedCode() {
        XCTAssertEqual(refusal([:], project: "B"), "READY_PROJECT_MISMATCH")
        XCTAssertEqual(refusal(["protocol": 2]), "READY_PROTOCOL_REFUSED")
        XCTAssertEqual(refusal(["mount": "virtiofs"]), "READY_MOUNT_REFUSED")
        XCTAssertEqual(refusal(["workspaceReadOnly": false]), "READY_MOUNT_REFUSED")
        XCTAssertEqual(refusal(["cgroupKill": false]), "READY_CGROUP_KILL_MISSING")
    }

    func testAbsentFieldsAreRefusedNotAssumed() {
        do { try ReadyProof.verify(["protocol": 1, "projectId": "A"], project: "A"); XCTFail("must refuse") }
        catch let failure as LinuxPlugin.LaunchFailure { XCTAssertEqual(failure.code, "READY_MOUNT_REFUSED") }
        catch { XCTFail("\(error)") }
    }
}
