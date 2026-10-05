import Darwin
import Foundation
import XCTest
import NativeWorkspace

final class WorkspaceStoreTests: XCTestCase {
    var root = "", workspace = "", state = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "native-workspace-tests-" + UUID().uuidString
        workspace = root + "/workspace"; state = root + "/state"
        try FileManager.default.createDirectory(atPath: workspace + "/src", withIntermediateDirectories: true)
        try put("notes.md", "base-notes"); try put("src/app.js", "base-app")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func put(_ path: String, _ text: String) throws { try text.write(toFile: workspace + "/" + path, atomically: false, encoding: .utf8) }
    func disk(_ path: String) -> String? { try? String(contentsOfFile: workspace + "/" + path, encoding: .utf8) }
    func store() throws -> WorkspaceStore { try WorkspaceStore(workspace: workspace, state: state) }
    func p(_ text: String) -> RelativePath { RelativePath(text) }

    func testNativeWriteIsDurableAcrossReopen() throws {
        let first = try store()
        guard case .read(let text, let version) = try first.nativeRead(p("notes.md")) else { return XCTFail("read") }
        XCTAssertEqual(text, Data("base-notes".utf8))
        guard case .written(let written) = try first.nativeWrite(p("notes.md"), Data("原生修改".utf8), base: version) else {
            return XCTFail("write")
        }
        XCTAssertNotEqual(written, version)
        let reopened = try store()
        XCTAssertEqual(reopened.recovery.anomalies, [])
        XCTAssertEqual(reopened.version(p("notes.md")), written)
        XCTAssertEqual(reopened.generation, 1)
        XCTAssertEqual(disk("notes.md"), "原生修改")
    }

    func testStaleBaseKeepsDraftAndBypassingWriterBecomesConflict() throws {
        let store = try store()
        guard case .read(_, let version) = try store.nativeRead(p("notes.md")) else { return XCTFail("read") }
        try put("notes.md", "same-uid bypass")
        guard case .conflict(let draft, let current) = try store.nativeWrite(p("notes.md"), Data("mine".utf8), base: version) else {
            return XCTFail("conflict expected")
        }
        XCTAssertNotEqual(current, version)
        XCTAssertEqual(disk("notes.md"), "same-uid bypass")
        XCTAssertEqual(store.generation, 1)
        XCTAssertEqual(store.changes(since: 0).map(\.origin), ["external"])
        let reopened = try self.store()
        XCTAssertEqual(reopened.draftList.map(\.status), [.conflict])
        XCTAssertEqual(try reopened.draftData(draft), Data("mine".utf8))
        XCTAssertEqual(try reopened.audit(), [])
    }

    func testCreateNeedsAbsentBaseAndRefusesReservedPaths() throws {
        let store = try store()
        guard case .written = try store.nativeWrite(p("new/dir/file.txt"), Data("x".utf8), base: nil) else { return XCTFail("create") }
        XCTAssertEqual(disk("new/dir/file.txt"), "x")
        guard case .conflict = try store.nativeWrite(p("new/dir/file.txt"), Data("y".utf8), base: nil) else { return XCTFail("cas") }
        XCTAssertEqual(try store.nativeWrite(p("../escape"), Data(), base: nil), .refused("PATH_REFUSED"))
        XCTAssertEqual(try store.nativeWrite(p(".dsh-tmp-x"), Data(), base: nil), .refused("PATH_RESERVED"))
        XCTAssertEqual(try store.audit(), [])
    }

    func testRestartDuringLinuxLeaseKeepsWriterUnknownAndHeldDraftBytes() throws {
        let first = try store()
        guard case .read(_, let notes) = try first.nativeRead(p("notes.md")) else { return XCTFail("read") }
        guard case .read(_, let app) = try first.nativeRead(p("src/app.js")) else { return XCTFail("read") }
        guard case .granted(let lease) = try first.acquireLease("npm test") else { return XCTFail("lease") }
        XCTAssertEqual(try first.nativeRead(p("notes.md")), .leaseBusy)
        let bytes = Data([0xE8, 0x8D, 0x89, 0x00, 0xFF, 0x0A])
        guard case .draftHeld(let held) = try first.nativeWrite(p("notes.md"), bytes, base: notes) else { return XCTFail("held") }
        guard case .draftHeld(let other) = try first.nativeWrite(p("src/app.js"), Data("native app".utf8), base: app) else {
            return XCTFail("held")
        }
        try put("src/app.js", "linux wrote this")

        let restarted = try store()
        XCTAssertEqual(restarted.recovery.writerUnknown?.fence, lease.fence)
        XCTAssertEqual(restarted.lease?.state, .writerUnknown)
        XCTAssertEqual(restarted.recovery.externalChanges, [])
        XCTAssertEqual(try restarted.draftData(held), bytes)
        XCTAssertEqual(restarted.draftList.map(\.status), [.held, .held])
        XCTAssertEqual(disk("src/app.js"), "linux wrote this")
        guard case .busy = try restarted.acquireLease("again") else { return XCTFail("lease must stay held") }

        let again = try store()
        XCTAssertEqual(again.lease?.fence, lease.fence)
        guard let release = try again.releaseLease(fence: lease.fence, reason: .guestTerminated) else { return XCTFail("release") }
        XCTAssertEqual(release.changed, [p("src/app.js")])
        XCTAssertEqual(release.drafts.map(\.id), [held, other])
        XCTAssertEqual(release.drafts.map(\.status), [.applied, .conflict])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: workspace + "/notes.md")), bytes)
        XCTAssertEqual(disk("src/app.js"), "linux wrote this")
        XCTAssertEqual(again.epoch, 2)
        XCTAssertNil(try again.releaseLease(fence: lease.fence, reason: .completed))
        XCTAssertEqual(try self.store().audit(), [])
    }

    func testSessionRestoresLastCheckpointAndMarksUnfinishedToolsUnknown() throws {
        let first = try store()
        XCTAssertNil(try first.restoreSession())
        _ = try first.checkpointSession(Data("/dsh/home v1".utf8))
        try first.toolStarted("call-write")
        guard case .read(_, let version) = try first.nativeRead(p("notes.md")),
              case .written = try first.nativeWrite(p("notes.md"), Data("tool wrote".utf8), base: version)
        else { return XCTFail("write") }
        try first.toolFinished("call-write", outcome: "ok")
        guard case .granted(let lease) = try first.acquireLease("tool"),
              case .draftHeld(let draft) = try first.nativeWrite(p("src/app.js"), Data("draft".utf8), base: nil)
        else { return XCTFail("draft") }
        _ = try first.releaseLease(fence: lease.fence, reason: .completed)
        try first.toolStarted("call-lost")

        let restarted = try store()
        XCTAssertEqual(restarted.recovery.unknownToolCalls, ["call-lost"])
        let restore = try XCTUnwrap(try restarted.restoreSession())
        XCTAssertEqual(restore.snapshot, Data("/dsh/home v1".utf8))
        XCTAssertEqual(restore.checkpointGeneration, 0)
        XCTAssertEqual(restore.workspaceGeneration, 1)
        XCTAssertTrue(restore.workspaceChanged)
        XCTAssertEqual(restore.unknownToolCalls, ["call-lost"])
        XCTAssertEqual(restore.completedAfterCheckpoint, ["call-write"])
        XCTAssertEqual(restore.drafts.map(\.id), [draft])
        XCTAssertEqual(restore.drafts.map(\.status), [.conflict])
        XCTAssertEqual(try restarted.draftData(draft), Data("draft".utf8))
        XCTAssertEqual(disk("notes.md"), "tool wrote", "tool writes after the checkpoint are not rolled back")

        _ = try restarted.checkpointSession(Data("/dsh/home v2".utf8))
        let again = try XCTUnwrap(try self.store().restoreSession())
        XCTAssertEqual(again.snapshot, Data("/dsh/home v2".utf8))
        XCTAssertFalse(again.workspaceChanged)
        XCTAssertEqual(again.unknownToolCalls, [])
        XCTAssertEqual(again.completedAfterCheckpoint, [])
    }

    func testCompactionPreservesStateAcrossReopen() throws {
        let first = try store()
        first.compactionThreshold = 5
        guard case .granted(let lease) = try first.acquireLease("hold"),
              case .draftHeld(let draft) = try first.nativeWrite(p("src/app.js"), Data("kept".utf8), base: nil)
        else { return XCTFail("draft") }
        _ = try first.releaseLease(fence: lease.fence, reason: .completed)
        var last = ""
        for index in 1...12 {
            guard case .read(_, let version) = try first.nativeRead(p("notes.md")),
                  case .written(let written) = try first.nativeWrite(p("notes.md"), Data("v\(index)".utf8), base: version)
            else { return XCTFail("write \(index)") }
            last = written
        }
        let reopened = try store()
        XCTAssertEqual(reopened.recovery.anomalies, [])
        XCTAssertEqual(reopened.generation, 12)
        XCTAssertEqual(reopened.version(p("notes.md")), last)
        XCTAssertEqual(try reopened.draftData(draft), Data("kept".utf8))
        XCTAssertEqual(reopened.changes(since: 10).map(\.generation), [11, 12])
        XCTAssertEqual(try reopened.audit(), [])
    }
}
