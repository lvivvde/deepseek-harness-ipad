import Darwin
import Foundation
import XCTest
import NativeWorkspace

/// ENOSPC injected at every stage of every durable write: the operation fails cleanly, nothing is
/// half committed, earlier drafts and the earlier checkpoint survive byte for byte.
final class NoSpaceTests: XCTestCase {
    var root = "", workspace = "", state = ""
    let noSpace = WorkspaceError.io("write", ENOSPC)

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func fresh() throws -> WorkspaceStore {
        try? FileManager.default.removeItem(atPath: root)
        root = NSTemporaryDirectory() + "native-nospace-tests-" + UUID().uuidString
        workspace = root + "/workspace"; state = root + "/state"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        try "base".write(toFile: workspace + "/notes.md", atomically: false, encoding: .utf8)
        return try WorkspaceStore(workspace: workspace, state: state)
    }

    /// Throws ENOSPC at the `occurrence`-th time `point` is reached, once.
    func inject(_ store: WorkspaceStore, _ point: FaultPoint, occurrence: Int = 1) {
        var seen = 0
        store.fault = { [noSpace] reached in
            guard reached == point else { return }
            seen += 1
            if seen == occurrence { throw noSpace }
        }
    }

    func read(_ store: WorkspaceStore, _ path: String = "notes.md") throws -> (String, String) {
        guard case .read(let data, let version) = try store.nativeRead(RelativePath(path)) else { throw XCTSkip("read failed") }
        return (String(decoding: data, as: UTF8.self), version)
    }

    func assertConsistentAfterReopen(_ label: String, drafts expected: [String: Data] = [:]) throws -> WorkspaceStore {
        let reopened = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertEqual(reopened.recovery.anomalies, [], label)
        XCTAssertEqual(try reopened.audit(), [], label)
        for (id, bytes) in expected { XCTAssertEqual(try reopened.draftData(id), bytes, label) }
        return reopened
    }

    let workspaceStages: [FaultPoint.Stage] = [.beforeTemp, .halfWritten, .beforeSync, .beforeRename]

    func testNativeWriteFailsCleanly() throws {
        for stage in workspaceStages {
            let store = try fresh()
            let (_, version) = try read(store)
            inject(store, FaultPoint(.workspace, stage))
            guard case .failed = try store.nativeWrite(RelativePath("notes.md"), Data("new".utf8), base: version) else {
                XCTFail("\(stage)"); continue
            }
            XCTAssertEqual(try read(store).0, "base", "\(stage)")
            XCTAssertEqual(store.version(RelativePath("notes.md")), version, "\(stage)")
            let reopened = try assertConsistentAfterReopen("\(stage)")
            XCTAssertEqual(reopened.version(RelativePath("notes.md")), version, "\(stage)")
        }
    }

    func testJournalFullBeforeOrAfterTheWrite() throws {
        for stage: FaultPoint.Stage in [.halfWritten, .beforeSync] {
            // Occurrence 1 is the intent (nothing written); 2 is the commit after the rename landed.
            for occurrence in [1, 2] {
                let label = "journal.\(stage) #\(occurrence)"
                let store = try fresh()
                let (_, version) = try read(store)
                inject(store, FaultPoint(.journal, stage), occurrence: occurrence)
                let result = try store.nativeWrite(RelativePath("notes.md"), Data("new".utf8), base: version)
                let (text, current) = try read(store)
                switch result {
                case .written(let written):
                    XCTAssertEqual(occurrence, 2, label); XCTAssertEqual(text, "new", label); XCTAssertEqual(written, current, label)
                case .failed:
                    XCTAssertEqual(occurrence, 1, label); XCTAssertEqual(text, "base", label); XCTAssertEqual(current, version, label)
                default: XCTFail(label)
                }
                _ = try assertConsistentAfterReopen(label)
            }
        }
    }

    func testDraftSaveFailsWithoutLosingEarlierDrafts() throws {
        for stage in workspaceStages {
            let store = try fresh()
            let (_, version) = try read(store)
            guard case .granted = try store.acquireLease("build"),
                  case .draftHeld(let kept) = try store.nativeWrite(RelativePath("notes.md"), Data("first".utf8), base: version)
            else { XCTFail("setup"); continue }
            inject(store, FaultPoint(.draft, stage))
            guard case .failed = try store.nativeWrite(RelativePath("notes.md"), Data("second".utf8), base: version) else {
                XCTFail("\(stage)"); continue
            }
            XCTAssertEqual(store.draftList.map(\.id), [kept])
            let reopened = try assertConsistentAfterReopen("draft.\(stage)", drafts: [kept: Data("first".utf8)])
            XCTAssertEqual(reopened.draftList.map(\.id), [kept])
            XCTAssertEqual(reopened.recovery.quarantined, [])
        }
    }

    func testCheckpointFailureKeepsPreviousCheckpoint() throws {
        for stage: FaultPoint.Stage in [.beforeTemp, .halfWritten, .beforeSync, .beforeRename] {
            let store = try fresh()
            _ = try store.checkpointSession(Data("home-1".utf8))
            inject(store, FaultPoint(.checkpoint, stage))
            XCTAssertThrowsError(try store.checkpointSession(Data("home-2".utf8)), "\(stage)")
            XCTAssertEqual(try store.restoreSession()?.snapshot, Data("home-1".utf8), "\(stage)")
            let reopened = try assertConsistentAfterReopen("checkpoint.\(stage)")
            XCTAssertEqual(try reopened.restoreSession()?.snapshot, Data("home-1".utf8), "\(stage)")
        }
    }

    func testCompactionFailureKeepsJournal() throws {
        for stage: FaultPoint.Stage in [.beforeTemp, .halfWritten, .beforeSync, .beforeRename] {
            let store = try fresh()
            let (_, version) = try read(store)
            guard case .written(let written) = try store.nativeWrite(RelativePath("notes.md"), Data("new".utf8), base: version) else {
                XCTFail("write"); continue
            }
            inject(store, FaultPoint(.snapshot, stage))
            XCTAssertThrowsError(try store.compact(), "\(stage)")
            let reopened = try assertConsistentAfterReopen("snapshot.\(stage)")
            XCTAssertEqual(reopened.version(RelativePath("notes.md")), written)
        }
    }
}
