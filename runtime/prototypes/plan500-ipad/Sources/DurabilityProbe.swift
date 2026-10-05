// PROTOTYPE: #39 gate 1 (G2) evidence on the iPad candidate app. Synthetic workspace inside this
// research app's container only; never opens Harness data. Launch with `--durability-probe --run-id <id>`.
//
// Each launch first verifies the scenario the previous launch was killed in, then starts the next
// scenario and SIGKILLs itself at its injection point. The Mac side relaunches until the receipt
// (Documents/DurabilityProbe/durability-safe.json) says finished. The last launch runs the
// in-process corruption and ENOSPC checks. The receipt holds names, booleans and counts only.
#if os(iOS)
import Darwin
import Foundation
import NativeWorkspace
import SwiftUI

struct DurabilityProbeView: View {
    @State private var status = "耐久检查运行中"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("方案500 · 工作区耐久检查").font(.title)
            Text("独立合成工作区。每次启动先验证上一次被杀的场景，再在下一个注入点结束进程。")
            Text(status).font(.headline)
        }.padding().task {
            let arguments = ProcessInfo.processInfo.arguments
            let index = arguments.firstIndex(of: "--run-id").map { $0 + 1 }
            let runId = index.flatMap { arguments.indices.contains($0) ? arguments[$0] : nil } ?? "manual"
            status = await Task.detached(priority: .userInitiated) { DurabilityProbe.step(runId: runId) }.value
        }
    }
}

struct DurabilityReceipt: Codable {
    struct Scenario: Codable {
        let name: String
        var killed: Bool
        var checks: [String: Bool]
        var passed: Bool { killed && !checks.isEmpty && checks.values.allSatisfy { $0 } }
    }
    var runId: String
    var physicalDevice: Bool
    var next = 0
    var pending: String?
    var scenarios: [Scenario] = []
    var inProcess: [String: Bool] = [:]
    var finished = false
    var passed = false
}

enum DurabilityProbe {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DurabilityProbe")
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DurabilityProbe")
    static var receiptURL: URL { documents.appendingPathComponent("durability-safe.json") }

    struct Paths {
        let root: URL
        var workspace: String { root.appendingPathComponent("workspace").path }
        var state: String { root.appendingPathComponent("state").path }
        var killed: URL { root.appendingPathComponent("killed") }
    }

    struct Scenario {
        let name: String
        /// Runs the operation; must SIGKILL the process before returning.
        let start: (WorkspaceStore, Paths) throws -> Void
        let verify: (Paths, inout [String: Bool]) throws -> Void
    }

    static let notes = NativeWorkspace.RelativePath("notes.md")

    static func killSelf(_ paths: Paths) -> Never {
        FileManager.default.createFile(atPath: paths.killed.path, contents: Data())
        kill(getpid(), SIGKILL)
        while true { pause() }
    }

    static func killAt(_ name: String, _ paths: Paths) -> FaultHook {
        let parts = name.split(separator: "#")
        let point = FaultPoint(name: String(parts[0]))!
        let occurrence = parts.count > 1 ? Int(parts[1])! : 1
        var seen = 0
        return { reached in
            guard reached == point else { return }
            seen += 1
            if seen == occurrence { killSelf(paths) }
        }
    }

    static func base(_ store: WorkspaceStore, _ path: NativeWorkspace.RelativePath = notes) throws -> String? {
        if case .read(_, let version) = try store.nativeRead(path) { return version }
        return nil
    }

    static func disk(_ paths: Paths, _ name: String = "notes.md") -> String? {
        try? String(contentsOfFile: paths.workspace + "/" + name, encoding: .utf8)
    }

    /// Reopens twice: clean audit, no anomalies except `allowed`, and the second open quarantines nothing.
    static func reopen(_ paths: Paths, _ checks: inout [String: Bool], allowed: [JournalAnomaly.Kind] = []) throws -> WorkspaceStore {
        let store = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
        checks["anomalies"] = store.recovery.anomalies.map(\.kind) == allowed
        checks["audit"] = try store.audit().isEmpty
        let again = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
        checks["idempotent"] = try again.recovery.anomalies.isEmpty && again.recovery.quarantined.isEmpty && (again.audit().isEmpty)
        return store
    }

    static func nativeWriteKill(_ stage: FaultPoint.Stage, landed: Bool, recovered: Bool, quarantined: Bool) -> Scenario {
        let name = "workspace.\(stage.rawValue)"
        return Scenario(name: name, start: { store, paths in
            let version = try base(store)
            store.fault = killAt(name, paths)
            _ = try store.nativeWrite(notes, Data("native bytes".utf8), base: version)
        }, verify: { paths, checks in
            let store = try reopen(paths, &checks)
            checks["disk"] = disk(paths) == (landed ? "native bytes" : "base")
            checks["generation"] = store.generation == (landed ? 1 : 0)
            if stage != .afterCommit { checks["intent"] = Array(store.recovery.intents.values) == [landed ? .landed : .notLanded] }
            checks["recoveredDraft"] = store.recovery.recoveredDrafts.count == (recovered ? 1 : 0)
            checks["quarantined"] = store.recovery.quarantined.count == (quarantined ? 1 : 0)
            if recovered, let draft = store.draftList.first {
                checks["draftBytes"] = try draft.status == .recovered && (store.draftData(draft.id)) == Data("native bytes".utf8)
            }
        })
    }

    static func checkpointKill(_ stage: FaultPoint.Stage) -> Scenario {
        let name = "checkpoint.\(stage.rawValue)"
        return Scenario(name: name, start: { store, paths in
            _ = try store.checkpointSession(Data("home v1".utf8))
            store.fault = killAt(name, paths)
            _ = try store.checkpointSession(Data("home v2".utf8))
        }, verify: { paths, checks in
            let restore = try reopen(paths, &checks).restoreSession()
            checks["checkpointReadable"] = restore?.snapshot == Data((stage == .afterRename ? "home v2" : "home v1").utf8)
        })
    }

    static let draftText = "草稿 bytes \u{1F600} e\u{301}\u{0}"

    static let scenarios: [Scenario] = [
        nativeWriteKill(.beforeTemp, landed: false, recovered: false, quarantined: false),
        nativeWriteKill(.halfWritten, landed: false, recovered: false, quarantined: true),
        nativeWriteKill(.beforeSync, landed: false, recovered: true, quarantined: false),
        nativeWriteKill(.beforeRename, landed: false, recovered: true, quarantined: false),
        nativeWriteKill(.afterRename, landed: true, recovered: false, quarantined: false),
        nativeWriteKill(.afterCommit, landed: true, recovered: false, quarantined: false),
        Scenario(name: "lease", start: { store, paths in
            let version = try base(store)
            guard case .granted(let lease) = try store.acquireLease("linux-writer") else { return }
            try Data(String(lease.fence).utf8).write(to: paths.root.appendingPathComponent("fence"))
            guard case .draftHeld(let id) = try store.nativeWrite(notes, Data(draftText.utf8), base: version) else { return }
            try Data(id.utf8).write(to: paths.root.appendingPathComponent("draft"))
            // The Linux writer is mid-command when the app dies (simulated writer; the VM is not started).
            try Data("linux partial output".utf8).write(to: URL(fileURLWithPath: paths.workspace + "/linux-output.txt"))
            killSelf(paths)
        }, verify: { paths, checks in
            let fence = try Int(String(contentsOf: paths.root.appendingPathComponent("fence"), encoding: .utf8))
            let draft = try String(contentsOf: paths.root.appendingPathComponent("draft"), encoding: .utf8)
            let store = try reopen(paths, &checks)
            checks["writerUnknown"] = store.recovery.writerUnknown?.fence == fence && store.lease?.state == .writerUnknown
            checks["nothingReplayed"] = store.generation == 0 && disk(paths) == "base"
            checks["draftByteIdentical"] = try (store.draftData(draft)) == Data(draftText.utf8)
            checks["linuxBytesKept"] = disk(paths, "linux-output.txt") == "linux partial output"
            checks["notAutoReleased"] = try (WorkspaceStore(workspace: paths.workspace, state: paths.state)).lease?.fence == fence
        }),
        Scenario(name: "session", start: { store, paths in
            _ = try store.nativeWrite(notes, Data("v1".utf8), base: try base(store))
            _ = try store.checkpointSession(Data("home".utf8))
            try store.toolStarted("call-1")
            _ = try store.nativeWrite(notes, Data("tool bytes".utf8), base: try base(store))
            killSelf(paths)
        }, verify: { paths, checks in
            let restore = try reopen(paths, &checks).restoreSession()
            checks["lastCheckpoint"] = restore?.snapshot == Data("home".utf8)
            checks["toolBytesKept"] = disk(paths) == "tool bytes"
            checks["unknownTool"] = restore?.unknownToolCalls == ["call-1"]
            checks["workspaceChanged"] = restore?.workspaceChanged == true
        }),
        Scenario(name: "journal.halfWritten", start: { store, paths in
            store.fault = killAt("journal.halfWritten", paths)
            _ = try store.nativeWrite(notes, Data("native bytes".utf8), base: try base(store))
        }, verify: { paths, checks in
            let store = try reopen(paths, &checks, allowed: [.tornTail])
            checks["originalKept"] = store.recovery.anomalies.allSatisfy {
                FileManager.default.fileExists(atPath: paths.state + "/quarantine/" + $0.quarantined)
            }
            checks["disk"] = disk(paths) == "base"
        }),
        checkpointKill(.halfWritten),
        checkpointKill(.beforeRename),
        checkpointKill(.afterRename),
    ]

    static func fresh(_ root: URL) throws -> Paths {
        try? FileManager.default.removeItem(at: root)
        let paths = Paths(root: root)
        try FileManager.default.createDirectory(atPath: paths.workspace, withIntermediateDirectories: true)
        try Data("base".utf8).write(to: URL(fileURLWithPath: paths.workspace + "/notes.md"))
        return paths
    }

    static func save(_ receipt: DurabilityReceipt) throws {
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
    }

    /// One step. Returns a status line for the UI; usually never returns because it kills itself.
    static func step(runId: String) -> String {
        var receipt = (try? JSONDecoder().decode(DurabilityReceipt.self, from: Data(contentsOf: receiptURL)))
            .flatMap { $0.runId == runId ? $0 : nil }
        if receipt == nil {
            try? FileManager.default.removeItem(at: support)
            #if targetEnvironment(simulator)
            receipt = DurabilityReceipt(runId: runId, physicalDevice: false)
            #else
            receipt = DurabilityReceipt(runId: runId, physicalDevice: true)
            #endif
        }
        guard var receipt else { return "收据不可用" }
        if receipt.finished { return receipt.passed ? "耐久检查完成：通过" : "耐久检查完成：未通过" }
        do {
            if let pending = receipt.pending, let scenario = scenarios.first(where: { $0.name == pending }) {
                let paths = Paths(root: support.appendingPathComponent(pending))
                var result = DurabilityReceipt.Scenario(name: pending, killed: FileManager.default.fileExists(atPath: paths.killed.path), checks: [:])
                do { try scenario.verify(paths, &result.checks) } catch { result.checks["verifyThrew"] = false }
                receipt.scenarios.append(result)
                receipt.pending = nil
                try save(receipt)
            }
            if receipt.next < scenarios.count {
                let scenario = scenarios[receipt.next]
                receipt.next += 1; receipt.pending = scenario.name
                try save(receipt)
                let paths = try fresh(support.appendingPathComponent(scenario.name))
                let store = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
                try scenario.start(store, paths)
                // Reaching here means the injection point was never hit; verification records killed=false.
                return "未到达注入点：\(scenario.name)"
            }
            receipt.inProcess = try inProcessChecks()
            receipt.finished = true
            receipt.passed = receipt.scenarios.count == scenarios.count && receipt.scenarios.allSatisfy(\.passed)
                && !receipt.inProcess.isEmpty && receipt.inProcess.values.allSatisfy { $0 }
            try save(receipt)
            return receipt.passed ? "耐久检查完成：通过" : "耐久检查完成：未通过"
        } catch {
            receipt.inProcess["stepThrew"] = false
            try? save(receipt)
            return "耐久检查出错"
        }
    }

    // MARK: in-process checks (no kill needed)

    static func frames(_ data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = [], offset = 8
        while offset + 28 <= data.count {
            let size = Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
            ranges.append(offset..<offset + 28 + size); offset += 28 + size
        }
        return ranges
    }

    static func inProcessChecks() throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let damages: [(String, JournalAnomaly.Kind, (inout Data) -> Void)] = [
            ("tornTail", .tornTail, { $0.append(contentsOf: [0x40, 0, 0, 0, 9, 9]) }),
            ("checksum", .checksum, { data in data[frames(data)[3].upperBound - 1] ^= 0xFF }),
            ("duplicate", .duplicate, { data in data.append(data[frames(data).last!]) }),
            ("zeroLength", .emptyFile, { data in data = Data() }),
        ]
        for (label, kind, damage) in damages {
            let paths = try fresh(support.appendingPathComponent("corrupt-" + label))
            let store = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            for text in ["v1", "v2", "v3"] { _ = try store.nativeWrite(notes, Data(text.utf8), base: try base(store)) }
            let journal = URL(fileURLWithPath: paths.state + "/journal.log")
            var data = try Data(contentsOf: journal)
            damage(&data)
            try data.write(to: journal)
            let reopened = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            let anomaly = reopened.recovery.anomalies.first
            checks["corrupt.\(label).reported"] = reopened.recovery.anomalies.count == 1 && anomaly?.kind == kind
            checks["corrupt.\(label).originalQuarantined"] = anomaly.map {
                (try? Data(contentsOf: URL(fileURLWithPath: paths.state + "/quarantine/" + $0.quarantined))) == data
            } ?? false
            checks["corrupt.\(label).keepsWorking"] = try (reopened.audit().isEmpty) && disk(paths) == "v3"
                && { if case .written = try reopened.nativeWrite(notes, Data("after".utf8), base: try base(reopened)) { return true }; return false }()
                && (WorkspaceStore(workspace: paths.workspace, state: paths.state).audit().isEmpty)
        }

        let noSpace = NativeWorkspace.WorkspaceError.io("write", ENOSPC)
        func inject(_ store: WorkspaceStore, _ point: FaultPoint, occurrence: Int = 1, persistent: Bool = false) {
            var seen = 0
            store.fault = { reached in
                guard reached == point else { return }
                seen += 1
                if seen == occurrence || (persistent && seen > occurrence) { throw noSpace }
            }
        }
        // afterRename is the directory sync after the rename: the new file is undone, not kept.
        for stage: FaultPoint.Stage in [.beforeTemp, .halfWritten, .beforeSync, .beforeRename, .afterRename] {
            let paths = try fresh(support.appendingPathComponent("nospace-workspace-" + stage.rawValue))
            let store = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            let version = try base(store)
            inject(store, FaultPoint(.workspace, stage))
            let failed: Bool
            if case .failed = try store.nativeWrite(notes, Data("new".utf8), base: version) { failed = true } else { failed = false }
            let reopened = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            checks["enospc.workspace.\(stage.rawValue)"] = try failed && disk(paths) == "base"
                && reopened.version(notes) == version && (reopened.audit().isEmpty) && reopened.recovery.anomalies.isEmpty
        }
        // 1: the intent append fails (nothing written); 2: the commit append fails after the rename,
        // which is undone; full: every append from the commit on fails, so not even the undo is recorded.
        for (label, occurrence, persistent) in [("1", 1, false), ("2", 2, false), ("full", 2, true)] {
            let paths = try fresh(support.appendingPathComponent("nospace-journal-" + label))
            let store = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            let version = try base(store)
            inject(store, FaultPoint(.journal, .beforeSync), occurrence: occurrence, persistent: persistent)
            let result = try store.nativeWrite(notes, Data("new".utf8), base: version)
            let reopened = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            let consistent = try reopened.audit().isEmpty && reopened.recovery.anomalies.isEmpty
                && reopened.version(notes) == version && reopened.recovery.recoveredDrafts.isEmpty
            if case .failed = result { checks["enospc.journal." + label] = consistent && disk(paths) == "base" }
            else { checks["enospc.journal." + label] = false }
        }
        do {
            let paths = try fresh(support.appendingPathComponent("nospace-draft"))
            let store = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            let version = try base(store)
            _ = try store.acquireLease("linux-writer")
            guard case .draftHeld(let earlier) = try store.nativeWrite(notes, Data(draftText.utf8), base: version) else {
                throw NativeWorkspace.WorkspaceError.io("draft", EINVAL)
            }
            inject(store, FaultPoint(.draft, .beforeSync))
            let failedCleanly: Bool
            if case .failed = try store.nativeWrite(notes, Data("later".utf8), base: version) { failedCleanly = true } else { failedCleanly = false }
            let reopened = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            checks["enospc.draft"] = try failedCleanly && reopened.draftList.count == 1
                && (reopened.draftData(earlier)) == Data(draftText.utf8) && (reopened.audit().isEmpty)
        }
        do {
            let paths = try fresh(support.appendingPathComponent("nospace-checkpoint"))
            let store = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            _ = try store.checkpointSession(Data("home v1".utf8))
            inject(store, FaultPoint(.checkpoint, .halfWritten))
            let failedCleanly = (try? store.checkpointSession(Data("home v2".utf8))) == nil
            let reopened = try WorkspaceStore(workspace: paths.workspace, state: paths.state)
            checks["enospc.checkpoint"] = try failedCleanly && (reopened.restoreSession())?.snapshot == Data("home v1".utf8)
                && (reopened.audit().isEmpty)
        }
        return checks
    }
}
#endif
