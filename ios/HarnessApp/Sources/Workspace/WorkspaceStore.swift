import Darwin
import Foundation

public struct Lease: Codable, Equatable {
    public enum State: String, Codable { case active = "ACTIVE", writerUnknown = "WRITER_UNKNOWN" }
    public let fence: Int
    public let epoch: Int
    public let operation: String
    public var state: State
}

public struct Draft: Codable, Equatable {
    public enum Status: String, Codable {
        /// Saved while a Linux writer held the lease; rebased when the lease is released.
        case held = "DRAFT_HELD"
        /// The base version no longer matches the workspace.
        case conflict = "CONFLICT"
        case applied = "APPLIED"
        /// A complete native write that was interrupted before it landed, kept rather than replayed.
        case recovered = "RECOVERED"
        /// The record exists but its bytes are gone (external damage); reported, never invented.
        case missing = "MISSING"
    }
    public let id: String
    public let path: RelativePath
    public let base: String?
    public var status: Status
    public let sha256: String
}

public struct Change: Codable, Equatable {
    public let generation: Int
    public let origin: String
    public let paths: [RelativePath]
}

public enum ReadResult: Equatable {
    case read(Data, String)
    case absent
    case leaseBusy
    case retry
    case refused(String)
}

public enum WriteResult: Equatable {
    case written(String)
    case draftHeld(String)
    case conflict(draft: String, current: String?)
    case refused(String)
    /// Nothing was committed; the bytes on disk are whatever the next read reports.
    case failed(String)
}

public enum LeaseResult: Equatable {
    case granted(Lease)
    case busy(Lease)
}

public struct LeaseRelease: Equatable {
    public enum Reason: String, Codable {
        case completed = "COMPLETED", refused = "REFUSED"
        /// The guest is gone (VM exited or the app restarted): the next boot gets a new epoch.
        case guestTerminated = "GUEST_TERMINATED"
    }
    public let generation: Int
    public let changed: [RelativePath]
    public let drafts: [Draft]
}

public struct RecoveryReport: Equatable {
    public enum IntentOutcome: String, Equatable { case landed = "LANDED", notLanded = "NOT_LANDED", external = "EXTERNAL" }
    public var anomalies: [JournalAnomaly] = []
    /// A lease that was held when the store last stopped. It stays held until its owner releases it.
    public var writerUnknown: Lease?
    public var intents: [String: IntentOutcome] = [:]
    public var recoveredDrafts: [String] = []
    public var missingDrafts: [String] = []
    public var quarantined: [String] = []
    public var externalChanges: [RelativePath] = []
    public var unknownToolCalls: [String] = []
    public var rebasedDrafts: [Draft] = []
}

public struct SessionRestore: Equatable {
    public let snapshot: Data
    public let checkpointGeneration: Int
    public let workspaceGeneration: Int
    /// The checkpoint is older than the workspace: show "工作区在此之后有变化".
    public var workspaceChanged: Bool { checkpointGeneration < workspaceGeneration }
    /// Tool calls with no recorded completion. Their result is unknown and they are never replayed.
    public let unknownToolCalls: [String]
    /// Tool calls that completed after the checkpoint; their workspace bytes are kept as they are.
    public let completedAfterCheckpoint: [String]
    public let drafts: [Draft]
}

struct Version: Codable, Equatable {
    let generation: Int
    let fingerprint: String
    var token: String { "\(generation):\(fingerprint)" }
}

struct PathVersion: Codable, Equatable {
    let path: RelativePath
    /// nil: the path no longer exists.
    let fingerprint: String?
}

struct Intent: Codable, Equatable {
    let id: String
    let path: RelativePath
    let temporary: RelativePath
    let old: String?
    let new: String
}

struct ToolCall: Codable, Equatable {
    let id: String
    var outcome: String?
}

/// Everything the journal records. Replay and live operation both go through `apply`, and a live
/// operation applies a record only after it is durable.
enum Record: Codable {
    case baseline(versions: [PathVersion])
    case intent(Intent)
    case commit(generation: Int, origin: String, paths: [PathVersion], intent: String?)
    case resolve(intent: String, outcome: String)
    case leaseGrant(Lease)
    case leaseUnknown(fence: Int)
    case leaseRelease(fence: Int, reason: LeaseRelease.Reason, generation: Int, paths: [PathVersion])
    case draftAdd(Draft)
    case draftStatus(id: String, status: Draft.Status)
    case checkpoint(serial: Int, generation: Int)
    case toolStart(id: String)
    case toolEnd(id: String, outcome: String)
}

struct State: Codable {
    var generation = 0
    var versions: [RelativePath: Version] = [:]
    var epoch = 1
    var fence = 0
    var lease: Lease?
    var drafts: [Draft] = []
    var intents: [String: Intent] = [:]
    var changes: [Change] = []
    var checkpointSerial = 0
    var tools: [ToolCall] = []

    static let retainedChanges = 512

    mutating func setVersions(_ paths: [PathVersion], generation: Int) {
        for entry in paths {
            versions[entry.path] = entry.fingerprint.map { Version(generation: generation, fingerprint: $0) }
        }
    }

    mutating func logChange(_ origin: String, _ paths: [PathVersion]) {
        changes.append(Change(generation: generation, origin: origin, paths: paths.map(\.path)))
        if changes.count > Self.retainedChanges { changes.removeFirst(changes.count - Self.retainedChanges) }
    }

    mutating func apply(_ record: Record) {
        switch record {
        case .baseline(let paths):
            setVersions(paths, generation: generation)
        case .intent(let intent):
            intents[intent.id] = intent
        case .commit(let next, let origin, let paths, let intent):
            generation = next
            setVersions(paths, generation: next)
            logChange(origin, paths)
            if let intent { intents[intent] = nil }
        case .resolve(let intent, _):
            intents[intent] = nil
        case .leaseGrant(let granted):
            lease = granted
            fence = max(fence, granted.fence)
        case .leaseUnknown(let fence):
            if lease?.fence == fence { lease?.state = .writerUnknown }
        case .leaseRelease(let fence, let reason, let next, let paths):
            guard lease?.fence == fence else { return }
            lease = nil
            if reason == .guestTerminated { epoch += 1 }
            if next != generation {
                generation = next
                setVersions(paths, generation: next)
                logChange("linux", paths)
            }
        case .draftAdd(let draft):
            drafts.append(draft)
        case .draftStatus(let id, let status):
            if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].status = status }
        case .checkpoint(let serial, _):
            checkpointSerial = serial
            tools.removeAll { $0.outcome != nil }
        case .toolStart(let id):
            tools.append(ToolCall(id: id, outcome: nil))
        case .toolEnd(let id, let outcome):
            if let index = tools.lastIndex(where: { $0.id == id }) { tools[index].outcome = outcome }
        }
    }
}

/// The durable layer of the native gateway: CAS native writes, the write lease shared with Linux,
/// drafts, the change-generation log and the `/dsh/home` session checkpoint. Callers serialize
/// access (one gateway owns one store); every state change is journaled before it is acknowledged.
/// Recovery rules: docs/design/workspace-durability.md.
public final class WorkspaceStore {
    public static let unknownOutcome = "UNKNOWN"

    public let files: WorkspaceFiles
    public let stateDirectory: String
    public private(set) var recovery = RecoveryReport()
    /// Journal records between snapshots; compaction folds them into `state.snapshot`.
    public var compactionThreshold = 4096
    public var fault: FaultHook? { didSet { journal.fault = fault } }

    private var state = State()
    private var journal: Journal!
    private let quarantine: Quarantine
    private var drafts: String { stateDirectory + "/drafts" }
    private var session: String { stateDirectory + "/session" }
    static let snapshotMagic = Array("DSHSNAP1".utf8)
    static let checkpointMagic = Array("DSHCKPT1".utf8)

    public init(workspace: String, state stateDirectory: String, fault: FaultHook? = nil) throws {
        files = WorkspaceFiles(root: workspace)
        self.stateDirectory = stateDirectory
        quarantine = Quarantine(directory: stateDirectory + "/quarantine")
        for directory in [stateDirectory, stateDirectory + "/quarantine", stateDirectory + "/drafts", stateDirectory + "/session"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let through = try loadSnapshot()
        let (journal, payloads, anomaly) = try Journal.open(directory: stateDirectory, after: through, quarantine: quarantine)
        self.journal = journal
        if let anomaly { recovery.anomalies.append(anomaly) }
        // A checksummed record that does not decode was written by another format version: refuse
        // to open rather than guess.
        let decoder = JSONDecoder()
        for payload in payloads { state.apply(try decoder.decode(Record.self, from: payload)) }
        try recover()
        self.fault = fault
        journal.fault = fault
    }

    // MARK: Reading state

    public var generation: Int { state.generation }
    public var epoch: Int { state.epoch }
    public var lease: Lease? { state.lease }
    public var draftList: [Draft] { state.drafts }
    public func version(_ path: RelativePath) -> String? { state.versions[path]?.token }
    public func changes(since generation: Int) -> [Change] { state.changes.filter { $0.generation > generation } }

    public func draftData(_ id: String) throws -> Data {
        guard let draft = state.drafts.first(where: { $0.id == id }) else { throw WorkspaceError.io("draft", ENOENT) }
        return try WorkspaceFiles(root: drafts).readData(RelativePath(draft.id), limit: .max)
    }

    // MARK: Journal

    private func record(_ record: Record) throws {
        let payload = try JSONEncoder().encode(record)
        try journal.append(payload)
        state.apply(record)
        if journal.recordCount >= compactionThreshold { try compact() }
    }

    /// Folds the journal into a checksummed snapshot, then empties the journal. A crash between
    /// the two leaves records the snapshot already covers; recovery skips them by sequence.
    public func compact() throws {
        struct Snapshot: Codable { let through: UInt64; let state: State }
        let body = try JSONEncoder().encode(Snapshot(through: journal.lastSequence, state: state))
        let directory = try openDirectory(stateDirectory)
        defer { close(directory) }
        try atomicReplace(directory: directory, name: Array("state.snapshot".utf8), temporary: temporaryName(),
                          data: Self.sealed(Self.snapshotMagic, body), mode: 0o600, site: .snapshot, fault: fault)
        try journal.reset()
    }

    private func loadSnapshot() throws -> UInt64? {
        struct Snapshot: Codable { let through: UInt64; let state: State }
        let path = stateDirectory + "/state.snapshot"
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let body = Self.unsealed(Self.snapshotMagic, data), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: body) {
            state = snapshot.state
            return snapshot.through
        }
        let kept = try quarantine.move(path, label: "state.snapshot")
        recovery.anomalies.append(JournalAnomaly(kind: .badSnapshot, offset: 0, quarantined: kept))
        return nil
    }

    static func sealed(_ magic: [UInt8], _ body: Data) -> Data {
        Data(magic) + Data(sha256(body).utf8) + body
    }

    static func unsealed(_ magic: [UInt8], _ data: Data) -> Data? {
        let header = magic.count + 64
        guard data.count >= header, Array(data.prefix(magic.count)) == magic else { return nil }
        let body = data.dropFirst(header)
        guard String(decoding: data.dropFirst(magic.count).prefix(64), as: UTF8.self) == sha256(Data(body)) else { return nil }
        return Data(body)
    }

    // MARK: Recovery

    private func recover() throws {
        if state.versions.isEmpty && state.generation == 0 && journal.lastSequence == 0 {
            let scanned = try files.scan()
            try record(.baseline(versions: scanned.keys.sorted().map { PathVersion(path: $0, fingerprint: scanned[$0]) }))
        }
        if var lease = state.lease, lease.state == .active {
            try record(.leaseUnknown(fence: lease.fence))
            lease.state = .writerUnknown
        }
        recovery.writerUnknown = state.lease
        for call in state.tools where call.outcome == nil {
            try record(.toolEnd(id: call.id, outcome: Self.unknownOutcome))
        }
        recovery.unknownToolCalls = state.tools.filter { $0.outcome == Self.unknownOutcome }.map(\.id)
        recovery.intents = try resolveIntents()
        try reconcileDrafts()
        try sweepTemporaries()
        if state.lease == nil {
            recovery.externalChanges = try reconcileWorkspace(origin: "recovered")
            recovery.rebasedDrafts = try rebaseHeldDrafts()
        }
    }

    /// Settles native writes whose outcome was never recorded, judging only by the bytes on disk:
    /// the new fingerprint landed, the old one is still there, or someone else wrote the path.
    @discardableResult
    private func resolveIntents() throws -> [String: RecoveryReport.IntentOutcome] {
        var outcomes: [String: RecoveryReport.IntentOutcome] = [:]
        for intent in state.intents.values.sorted(by: { $0.id < $1.id }) {
            if let leftover = try files.fingerprint(intent.temporary), leftover != "D" {
                if leftover == intent.new {
                    let id = Self.newIdentifier()
                    try files.moveOut(intent.temporary, to: drafts + "/" + id)
                    try record(.draftAdd(Draft(id: id, path: intent.path, base: state.versions[intent.path]?.token,
                                               status: .recovered, sha256: Self.digest(of: intent.new))))
                    recovery.recoveredDrafts.append(id)
                } else {
                    let kept = quarantinePath(intent.temporary)
                    try files.moveOut(intent.temporary, to: quarantine.directory + "/" + kept)
                    recovery.quarantined.append(kept)
                }
            }
            let disk = try files.fingerprint(intent.path)
            let outcome: RecoveryReport.IntentOutcome
            if disk == intent.new {
                outcome = .landed
                try record(.commit(generation: state.generation + 1, origin: "native", paths: [PathVersion(path: intent.path, fingerprint: disk)],
                                   intent: intent.id))
            } else if disk == intent.old && disk == state.versions[intent.path]?.fingerprint {
                outcome = .notLanded
                try record(.resolve(intent: intent.id, outcome: outcome.rawValue))
            } else {
                outcome = .external
                try record(.commit(generation: state.generation + 1, origin: "external",
                                   paths: [PathVersion(path: intent.path, fingerprint: disk)], intent: intent.id))
            }
            outcomes[intent.id] = outcome
        }
        return outcomes
    }

    private func quarantinePath(_ path: RelativePath) -> String {
        "\(Int(Date().timeIntervalSince1970))-\(Self.newIdentifier().prefix(8))-" + Data(path.bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }

    private func reconcileDrafts() throws {
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: drafts))
        for draft in state.drafts where draft.status != .missing && !present.contains(draft.id) {
            try record(.draftStatus(id: draft.id, status: .missing))
            recovery.missingDrafts.append(draft.id)
        }
        let known = Set(state.drafts.map(\.id))
        for name in present.sorted() where !known.contains(name) {
            // A blob whose record never committed: the writer was never answered. Keep the bytes.
            recovery.quarantined.append(try quarantine.move(drafts + "/" + name, label: "draft-" + name))
        }
    }

    private func sweepTemporaries() throws {
        for directory in [stateDirectory, session] {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory)
            where name.utf8.starts(with: WorkspaceFiles.temporaryPrefix) {
                recovery.quarantined.append(try quarantine.move(directory + "/" + name, label: name))
            }
        }
        for path in try files.temporaries() {
            let kept = quarantinePath(path)
            try files.moveOut(path, to: quarantine.directory + "/" + kept)
            recovery.quarantined.append(kept)
        }
    }

    /// Records every difference between the disk and the committed versions as one generation.
    @discardableResult
    private func reconcileWorkspace(origin: String) throws -> [RelativePath] {
        let changed = try differences()
        if !changed.isEmpty { try record(.commit(generation: state.generation + 1, origin: origin, paths: changed, intent: nil)) }
        return changed.map(\.path)
    }

    private func differences() throws -> [PathVersion] {
        let scanned = try files.scan()
        return Set(scanned.keys).union(state.versions.keys).sorted()
            .filter { scanned[$0] != state.versions[$0]?.fingerprint }
            .map { PathVersion(path: $0, fingerprint: scanned[$0]) }
    }

    /// Detects a same-uid writer that bypassed the gateway and records it as its own generation.
    private func reconcile(_ path: RelativePath) throws -> String? {
        let disk = try files.fingerprint(path)
        if disk != state.versions[path]?.fingerprint {
            try record(.commit(generation: state.generation + 1, origin: "external",
                               paths: [PathVersion(path: path, fingerprint: disk)], intent: nil))
        }
        return disk
    }

    // MARK: Native access

    public func nativeRead(_ path: RelativePath) throws -> ReadResult {
        do { try path.validate() } catch WorkspaceError.pathRefused(let reason) { return .refused(reason) }
        guard state.lease == nil else { return .leaseBusy }
        try resolveIntents()
        guard let disk = try reconcile(path) else { return .absent }
        guard disk.hasPrefix("F:") else { return .refused("NOT_REGULAR") }
        let data: Data
        do { data = try files.readData(path) } catch WorkspaceError.io(_, ENOENT) { return .retry }
        guard WorkspaceFiles.fileFingerprint(digest: sha256(data), mode: WorkspaceFiles.mode(of: disk) ?? 0) == disk else {
            return .retry
        }
        return .read(data, state.versions[path]!.token)
    }

    public func nativeWrite(_ path: RelativePath, _ data: Data, base: String?) throws -> WriteResult {
        do {
            try path.validate()
            if state.lease != nil { return .draftHeld(try keepDraft(path, data, base: base, status: .held)) }
            try resolveIntents()
            switch try writeNow(path, data, base: base) {
            case .success(let version): return .written(version)
            case .failure(let refusal):
                guard refusal.conflict else { return .refused(refusal.reason) }
                return .conflict(draft: try keepDraft(path, data, base: base, status: .conflict), current: version(path))
            }
        } catch WorkspaceError.pathRefused(let reason) {
            return .refused(reason)
        } catch let error as WorkspaceError {
            return .failed(error.description)
        }
    }

    struct Refusal: Error { let reason: String; let conflict: Bool }

    private func writeNow(_ path: RelativePath, _ data: Data, base: String?) throws -> Result<String, Refusal> {
        let disk = try reconcile(path)
        guard version(path) == base else { return .failure(Refusal(reason: "VERSION", conflict: true)) }
        if let disk, !disk.hasPrefix("F:") { return .failure(Refusal(reason: "NOT_REGULAR", conflict: false)) }
        let id = Self.newIdentifier()
        let temporaryLeaf = temporaryName(id)
        let temporary = RelativePath(bytes: path.components.dropLast().flatMap { $0 + [0x2F] } + temporaryLeaf)
        let mode = WorkspaceFiles.mode(of: disk) ?? 0o644
        let new = WorkspaceFiles.fileFingerprint(digest: sha256(data), mode: mode)
        try record(.intent(Intent(id: id, path: path, temporary: temporary, old: disk, new: new)))
        do {
            try files.write(path, data, mode: mode, temporary: temporaryLeaf, fault: fault)
            try record(.commit(generation: state.generation + 1, origin: "native", paths: [PathVersion(path: path, fingerprint: new)],
                               intent: id))
        } catch {
            // Settle the intent by what is on disk; a write that landed and is now recorded succeeded.
            if (try? resolveIntents())?[id] == .landed, let landed = version(path) { return .success(landed) }
            throw error
        }
        try? fault?(FaultPoint(.workspace, .afterCommit))
        return .success(version(path)!)
    }

    private func keepDraft(_ path: RelativePath, _ data: Data, base: String?, status: Draft.Status) throws -> String {
        let id = Self.newIdentifier()
        let directory = try openDirectory(drafts)
        defer { close(directory) }
        try atomicReplace(directory: directory, name: Array(id.utf8), temporary: temporaryName(), data: data, mode: 0o600,
                          site: .draft, fault: fault)
        do {
            try record(.draftAdd(Draft(id: id, path: path, base: base, status: status, sha256: sha256(data))))
        } catch {
            // Unacknowledged: move the blob aside so the draft list and the disk never disagree.
            _ = try? quarantine.move(drafts + "/" + id, label: "draft-" + id)
            throw error
        }
        return id
    }

    static func newIdentifier() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    static func digest(of fingerprint: String) -> String { String(fingerprint.split(separator: ":")[1]) }

    // MARK: Lease

    /// Grants the single write lease to a Linux command. The grant is durable before it is returned.
    public func acquireLease(_ operation: String) throws -> LeaseResult {
        if let lease = state.lease { return .busy(lease) }
        try resolveIntents()
        try reconcileWorkspace(origin: "external")
        let lease = Lease(fence: state.fence + 1, epoch: state.epoch, operation: operation, state: .active)
        try record(.leaseGrant(lease))
        return .granted(lease)
    }

    public func markWriterUnknown(fence: Int) throws {
        guard state.lease?.fence == fence, state.lease?.state == .active else { return }
        try record(.leaseUnknown(fence: fence))
    }

    /// Commits whatever the writer left in the workspace and releases the lease in one record, then
    /// rebases held drafts. Returns nil when `fence` is not the current lease.
    public func releaseLease(fence: Int, reason: LeaseRelease.Reason) throws -> LeaseRelease? {
        guard state.lease?.fence == fence else { return nil }
        let changed = try differences()
        let next = changed.isEmpty ? state.generation : state.generation + 1
        try record(.leaseRelease(fence: fence, reason: reason, generation: next, paths: changed))
        return LeaseRelease(generation: next, changed: changed.map(\.path), drafts: try rebaseHeldDrafts())
    }

    private func rebaseHeldDrafts() throws -> [Draft] {
        var outcomes: [Draft] = []
        for draft in state.drafts where draft.status == .held {
            let data = try draftData(draft.id)
            let status: Draft.Status
            do {
                if case .success = try writeNow(draft.path, data, base: draft.base) { status = .applied } else { status = .conflict }
            } catch WorkspaceError.pathRefused {
                status = .conflict
            }
            try record(.draftStatus(id: draft.id, status: status))
            outcomes.append(state.drafts.first { $0.id == draft.id }!)
        }
        return outcomes
    }

    // MARK: Session

    /// Durably replaces the `/dsh/home` checkpoint. The file is replaced atomically, so an
    /// interrupted replacement leaves the previous checkpoint readable.
    public func checkpointSession(_ snapshot: Data) throws -> Int {
        struct Body: Codable { let serial: Int; let generation: Int; let snapshot: Data }
        let serial = max(state.checkpointSerial, (try? readCheckpoint()?.serial) ?? 0) + 1
        let body = try JSONEncoder().encode(Body(serial: serial, generation: state.generation, snapshot: snapshot))
        let directory = try openDirectory(session)
        defer { close(directory) }
        try atomicReplace(directory: directory, name: Array("home.checkpoint".utf8), temporary: temporaryName(),
                          data: Self.sealed(Self.checkpointMagic, body), mode: 0o600, site: .checkpoint, fault: fault)
        try record(.checkpoint(serial: serial, generation: state.generation))
        return serial
    }

    private func readCheckpoint() throws -> (serial: Int, generation: Int, snapshot: Data)? {
        struct Body: Codable { let serial: Int; let generation: Int; let snapshot: Data }
        let path = session + "/home.checkpoint"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let body = Self.unsealed(Self.checkpointMagic, data), let decoded = try? JSONDecoder().decode(Body.self, from: body) else {
            let kept = try quarantine.move(path, label: "home.checkpoint")
            recovery.anomalies.append(JournalAnomaly(kind: .badCheckpoint, offset: 0, quarantined: kept))
            return nil
        }
        return (decoded.serial, decoded.generation, decoded.snapshot)
    }

    /// The last complete checkpoint and what happened after it. Nothing is replayed.
    public func restoreSession() throws -> SessionRestore? {
        guard let checkpoint = try readCheckpoint() else { return nil }
        return SessionRestore(snapshot: checkpoint.snapshot, checkpointGeneration: checkpoint.generation,
                              workspaceGeneration: state.generation,
                              unknownToolCalls: state.tools.filter { $0.outcome == Self.unknownOutcome }.map(\.id),
                              completedAfterCheckpoint: state.tools.filter { $0.outcome != nil && $0.outcome != Self.unknownOutcome }.map(\.id),
                              drafts: state.drafts)
    }

    public func toolStarted(_ id: String) throws { try record(.toolStart(id: id)) }
    public func toolFinished(_ id: String, outcome: String) throws { try record(.toolEnd(id: id, outcome: outcome)) }

    // MARK: Audit

    /// Invariants that must hold after any recovery; empty means consistent.
    public func audit() throws -> [String] {
        var problems: [String] = []
        if state.lease == nil {
            for entry in try differences() { problems.append("unrecorded change: \(entry.path)") }
        }
        for path in try files.temporaries() { problems.append("temporary in workspace: \(path)") }
        for intent in state.intents.keys { problems.append("unresolved intent: \(intent)") }
        for draft in state.drafts where draft.status != .missing {
            guard let data = try? draftData(draft.id) else { problems.append("draft bytes missing: \(draft.id)"); continue }
            if sha256(data) != draft.sha256 { problems.append("draft bytes changed: \(draft.id)") }
        }
        return problems
    }
}
