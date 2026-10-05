import Darwin
import Foundation
import XCTest
import NativeWorkspace

/// Real process death at every injection point: the probe SIGKILLs itself there, then the store is
/// reopened in this process and checked against the recovery rules.
/// CRASH_REPEATS (default 2) and CRASH_RANDOM_RUNS (default 20) scale the matrix for evidence runs.
final class CrashMatrixTests: XCTestCase {
    var root = "", workspace = "", state = ""
    let environment = ProcessInfo.processInfo.environment
    var repeats: Int { Int(environment["CRASH_REPEATS"] ?? "") ?? 2 }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func fresh() throws {
        try? FileManager.default.removeItem(atPath: root)
        root = NSTemporaryDirectory() + "native-crash-tests-" + UUID().uuidString
        workspace = root + "/workspace"; state = root + "/state"
        try FileManager.default.createDirectory(atPath: workspace + "/src", withIntermediateDirectories: true)
        try "base".write(toFile: workspace + "/notes.md", atomically: false, encoding: .utf8)
        _ = try WorkspaceStore(workspace: workspace, state: state)
    }

    var probe: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("workspace-crash-probe")
    }

    struct Run { let status: Int32; let killed: Bool; let output: String }

    /// Runs the probe; with `killAfter` the parent kills it after that many microseconds.
    func run(_ arguments: [String], killAfter: useconds_t? = nil) throws -> Run {
        let process = Process()
        process.executableURL = probe
        process.arguments = [workspace, state] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        if let killAfter {
            usleep(killAfter)
            kill(process.processIdentifier, SIGKILL)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Run(status: process.terminationStatus, killed: process.terminationReason == .uncaughtSignal, output: output)
    }

    func killed(_ arguments: [String], at point: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try run(arguments + [point])
        XCTAssertTrue(result.killed && result.status == SIGKILL, "\(point) not reached: \(result.output)", file: file, line: line)
        XCTAssertTrue(result.output.contains("KILL \(point)"), point, file: file, line: line)
    }

    func reopen(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceStore {
        let store = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertEqual(store.recovery.anomalies, [], label, file: file, line: line)
        XCTAssertEqual(try store.audit(), [], label, file: file, line: line)
        let again = try WorkspaceStore(workspace: workspace, state: state)
        XCTAssertEqual(again.recovery.anomalies, [], label, file: file, line: line)
        XCTAssertEqual(again.recovery.quarantined, [], "\(label): recovery is idempotent", file: file, line: line)
        return store
    }

    func disk(_ path: String) -> String? { try? String(contentsOfFile: workspace + "/" + path, encoding: .utf8) }

    func testNativeWriteAtEveryInjectionPoint() throws {
        // The six points of gate 1: before the temp, half written, before fsync, before rename,
        // after rename before the log commit, after the log commit before the reply.
        let expectations: [(FaultPoint.Stage, landed: Bool, recovered: Bool, quarantined: Bool)] = [
            (.beforeTemp, false, false, false), (.halfWritten, false, false, true), (.beforeSync, false, true, false),
            (.beforeRename, false, true, false), (.afterRename, true, false, false), (.afterCommit, true, false, false)
        ]
        for (stage, landed, recovered, quarantined) in expectations {
            for attempt in 1...repeats {
                let label = "workspace.\(stage.rawValue) run \(attempt)"
                try fresh()
                try killed(["write", "notes.md", "native bytes"], at: "workspace.\(stage.rawValue)")
                let store = try reopen(label)
                XCTAssertEqual(disk("notes.md"), landed ? "native bytes" : "base", label)
                XCTAssertEqual(store.generation, landed ? 1 : 0, label)
                if stage != .afterCommit {
                    XCTAssertEqual(Array(store.recovery.intents.values), [landed ? .landed : .notLanded], label)
                }
                XCTAssertEqual(store.recovery.recoveredDrafts.count, recovered ? 1 : 0, label)
                XCTAssertEqual(store.recovery.quarantined.count, quarantined ? 1 : 0, label)
                if recovered {
                    // A complete write that never landed is kept as a draft, not replayed.
                    let draft = store.draftList[0]
                    XCTAssertEqual(draft.status, .recovered, label)
                    XCTAssertEqual(try store.draftData(draft.id), Data("native bytes".utf8), label)
                }
            }
        }
    }

    func testDraftSaveAtEveryStageKeepsEarlierDraft() throws {
        for stage: FaultPoint.Stage in [.beforeTemp, .halfWritten, .beforeSync, .beforeRename, .afterRename] {
            for attempt in 1...repeats {
                let label = "draft.\(stage.rawValue) run \(attempt)"
                try fresh()
                let setup = try run(["draft", "notes.md", "earlier draft"])
                XCTAssertEqual(setup.status, 0, setup.output)
                try killed(["draft", "notes.md", "later draft"], at: "draft.\(stage.rawValue)")
                let store = try reopen(label)
                XCTAssertEqual(store.lease?.state, .writerUnknown, label)
                let earlier = try XCTUnwrap(store.draftList.first, label)
                XCTAssertEqual(try store.draftData(earlier.id), Data("earlier draft".utf8), label)
                XCTAssertEqual(store.draftList.count, 1, "\(label): an unacknowledged draft is not invented")
            }
        }
    }

    func testCheckpointReplacementKeepsAReadableCheckpoint() throws {
        for stage: FaultPoint.Stage in [.beforeTemp, .halfWritten, .beforeSync, .beforeRename, .afterRename] {
            for attempt in 1...repeats {
                let label = "checkpoint.\(stage.rawValue) run \(attempt)"
                try fresh()
                XCTAssertEqual(try run(["checkpoint", "home v1"]).status, 0)
                try killed(["checkpoint", "home v2"], at: "checkpoint.\(stage.rawValue)")
                let restore = try XCTUnwrap(try reopen(label).restoreSession(), label)
                let expected = stage == .afterRename ? "home v2" : "home v1"
                XCTAssertEqual(String(decoding: restore.snapshot, as: UTF8.self), expected, label)
            }
        }
    }

    func testCompactionInterruptedAnywhere() throws {
        let points = FaultPoint.Stage.allCases.filter { $0 != .afterCommit }.map { "snapshot.\($0.rawValue)" }
            + ["journal.beforeTemp", "journal.beforeRename", "journal.afterRename"]
        for point in points {
            for attempt in 1...repeats {
                try fresh()
                XCTAssertEqual(try run(["write", "notes.md", "before compaction"]).status, 0)
                try killed(["compact"], at: point)
                let store = try reopen("\(point) run \(attempt)")
                XCTAssertEqual(store.generation, 1, point)
                XCTAssertEqual(disk("notes.md"), "before compaction", point)
            }
        }
    }

    func testTornJournalAppendIsReportedAndRecovered() throws {
        for attempt in 1...repeats {
            try fresh()
            try killed(["write", "notes.md", "native bytes"], at: "journal.halfWritten")
            let store = try WorkspaceStore(workspace: workspace, state: state)
            XCTAssertEqual(store.recovery.anomalies.map(\.kind), [.tornTail], "run \(attempt)")
            XCTAssertEqual(disk("notes.md"), "base")
            XCTAssertEqual(try store.audit(), [])
            _ = try reopen("torn tail run \(attempt)")
        }
    }

    func testAppKilledWhileLinuxWriterHoldsLease() throws {
        for attempt in 1...repeats {
            let label = "lease run \(attempt)"
            try fresh()
            let result = try run(["lease", "notes.md", "草稿 bytes \u{1F600} e\u{301}"])
            XCTAssertTrue(result.killed, result.output)
            let fence = try XCTUnwrap(result.output.split(separator: "\n").first { $0.hasPrefix("LEASE ") }.map { Int($0.dropFirst(6)) } ?? nil)
            let draft = try XCTUnwrap(result.output.split(separator: "\n").first { $0.hasPrefix("DRAFT ") }.map { String($0.dropFirst(6)) })
            let store = try reopen(label)
            XCTAssertEqual(store.recovery.writerUnknown?.fence, fence, label)
            XCTAssertEqual(store.lease?.state, .writerUnknown, label)
            XCTAssertEqual(store.generation, 0, "\(label): nothing committed or replayed while the writer is unknown")
            XCTAssertEqual(try store.draftData(draft), Data("草稿 bytes \u{1F600} e\u{301}".utf8), label)
            XCTAssertEqual(disk("notes.md"), "base", label)
            XCTAssertEqual(disk("linux-output.txt"), "linux partial output", label)
            let reopened = try reopen(label)
            XCTAssertEqual(reopened.lease?.fence, fence, "\(label): never auto-released")
        }
    }

    func testRandomKillPositions() throws {
        let runs = Int(environment["CRASH_RANDOM_RUNS"] ?? "") ?? 20
        var generator = SystemRandomNumberGenerator()
        try fresh()
        var anomalies = 0
        for index in 1...runs {
            let delay = useconds_t.random(in: 5_000...250_000, using: &generator)
            let result = try run(["loop", String(UInt64.random(in: 1...UInt64.max, using: &generator))], killAfter: delay)
            XCTAssertTrue(result.killed, "run \(index): \(result.output)")
            let store = try WorkspaceStore(workspace: workspace, state: state)
            // A kill between the two halves of a journal append leaves a torn tail; nothing else may.
            XCTAssertTrue(store.recovery.anomalies.allSatisfy { $0.kind == .tornTail }, "run \(index): \(store.recovery.anomalies)")
            anomalies += store.recovery.anomalies.count
            XCTAssertEqual(try store.audit(), [], "run \(index)")
            XCTAssertFalse(store.draftList.contains { $0.status == .missing }, "run \(index)")
            if let lease = store.lease { _ = try store.releaseLease(fence: lease.fence, reason: .guestTerminated) }
            XCTAssertEqual(try store.audit(), [], "run \(index) after release")
        }
        print("random kills: \(runs) runs, \(anomalies) torn tails")
    }
}
