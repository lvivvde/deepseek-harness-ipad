import Foundation
import XCTest
import NativeWorkspace

/// Damaged journals: only the valid complete prefix is replayed, the original is quarantined, the
/// store reports what happened and keeps working. Frame layout: docs/design/workspace-durability.md.
final class JournalRecoveryTests: XCTestCase {
    var root = "", workspace = "", state = ""
    var journal: String { state + "/journal.log" }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "native-journal-tests-" + UUID().uuidString
        workspace = root + "/workspace"; state = root + "/state"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        try "v0".write(toFile: workspace + "/notes.md", atomically: false, encoding: .utf8)
        let store = try WorkspaceStore(workspace: workspace, state: state)
        for text in ["v1", "v2", "v3"] {
            guard case .read(_, let version) = try store.nativeRead(RelativePath("notes.md")),
                  case .written = try store.nativeWrite(RelativePath("notes.md"), Data(text.utf8), base: version)
            else { return XCTFail("write \(text)") }
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    /// Byte ranges of each frame after the 8-byte magic.
    func frames(_ data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = [], offset = 8
        while offset + 28 <= data.count {
            let size = Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
            ranges.append(offset..<offset + 28 + size); offset += 28 + size
        }
        return ranges
    }

    func reopenAfterDamage(_ damage: (inout Data) -> Void) throws -> (WorkspaceStore, Data) {
        var data = try Data(contentsOf: URL(fileURLWithPath: journal))
        damage(&data)
        try data.write(to: URL(fileURLWithPath: journal))
        let store = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertEqual(store.recovery.anomalies.count, 1)
        let kept = try XCTUnwrap(store.recovery.anomalies.first?.quarantined)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: state + "/quarantine/" + kept)), data, "original kept verbatim")
        return (store, data)
    }

    func assertKeepsWorking(_ store: WorkspaceStore, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try store.audit(), [], file: file, line: line)
        guard case .read(let text, let version) = try store.nativeRead(RelativePath("notes.md")) else { return XCTFail("read", file: file, line: line) }
        XCTAssertEqual(text, Data("v3".utf8), file: file, line: line)
        guard case .written = try store.nativeWrite(RelativePath("notes.md"), Data("after".utf8), base: version) else {
            return XCTFail("write", file: file, line: line)
        }
        let reopened = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertEqual(reopened.recovery.anomalies, [], file: file, line: line)
        XCTAssertEqual(try reopened.audit(), [], file: file, line: line)
    }

    func testTornTailKeepsCompletePrefix() throws {
        let (store, _) = try reopenAfterDamage { data in data.append(contentsOf: [0x40, 0, 0, 0, 9, 9]) }
        XCTAssertEqual(store.recovery.anomalies.first?.kind, .tornTail)
        XCTAssertEqual(store.generation, 3, "all three complete commits survive")
        XCTAssertEqual(store.recovery.externalChanges, [])
        try assertKeepsWorking(store)
    }

    func testChecksumErrorInMiddleStopsReplayThere() throws {
        let (store, damaged) = try reopenAfterDamage { data in
            let middle = self.frames(data)[3]  // the second write's intent
            data[middle.upperBound - 1] ^= 0xFF
        }
        XCTAssertEqual(store.recovery.anomalies.first?.kind, .checksum)
        XCTAssertEqual(store.recovery.anomalies.first?.offset, frames(damaged)[3].lowerBound)
        XCTAssertEqual(store.recovery.externalChanges, [RelativePath("notes.md")], "later bytes are adopted, not rolled back")
        try assertKeepsWorking(store)
    }

    func testDuplicateRecordIsRejected() throws {
        let (store, _) = try reopenAfterDamage { data in data.append(data[self.frames(data).last!]) }
        XCTAssertEqual(store.recovery.anomalies.first?.kind, .duplicate)
        XCTAssertEqual(store.generation, 3)
        try assertKeepsWorking(store)
    }

    func testZeroLengthJournal() throws {
        let (store, _) = try reopenAfterDamage { data in data = Data() }
        XCTAssertEqual(store.recovery.anomalies.first?.kind, .emptyFile)
        try assertKeepsWorking(store)
    }
}
