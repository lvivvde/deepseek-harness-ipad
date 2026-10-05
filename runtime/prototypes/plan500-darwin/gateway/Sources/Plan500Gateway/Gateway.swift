import CryptoKit
import Darwin
import Foundation

public struct Version: Codable, Equatable { public var g: Int; public var fp: String }

public struct Lease: Codable {
    public var op: String
    public var epoch: Int
    public var fence: Int
    public var state: String
    public var baseline: [RelativePath: String]

    struct Entry: Codable { var path: RelativePath; var fp: String }
    enum CodingKeys: String, CodingKey { case op, epoch, fence, state, baseline }

    init(op: String, epoch: Int, fence: Int, state: String, baseline: [RelativePath: String]) {
        self.op = op; self.epoch = epoch; self.fence = fence; self.state = state; self.baseline = baseline
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(String.self, forKey: .op); epoch = try c.decode(Int.self, forKey: .epoch)
        fence = try c.decode(Int.self, forKey: .fence); state = try c.decode(String.self, forKey: .state)
        baseline = Dictionary(uniqueKeysWithValues: try c.decode([Entry].self, forKey: .baseline).map { ($0.path, $0.fp) })
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op); try c.encode(epoch, forKey: .epoch); try c.encode(fence, forKey: .fence)
        try c.encode(state, forKey: .state)
        try c.encode(baseline.sorted { $0.key < $1.key }.map { Entry(path: $0.key, fp: $0.value) }, forKey: .baseline)
    }
}

public struct Draft: Codable { public var id: String; public var path: RelativePath; public var base: String?; public var status: String }
public struct LogEntry: Codable { public var generation: Int; public var origin: String; public var paths: [RelativePath] }

/// Durable gateway state. Path-keyed maps are stored as arrays so JSON object keys (and any
/// String-keyed decoding) never merge byte-distinct names.
public struct GatewayState: Codable {
    public var epoch = 1
    public var generation = 0
    public var fence = 0
    public var lease: Lease?
    public var drafts: [Draft] = []
    public var log: [LogEntry] = []
    public var versions: [RelativePath: Version] = [:]

    struct VersionEntry: Codable { var path: RelativePath; var g: Int; var fp: String }
    enum CodingKeys: String, CodingKey { case epoch, generation, fence, lease, drafts, log, versions }

    init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try c.decode(Int.self, forKey: .epoch); generation = try c.decode(Int.self, forKey: .generation)
        fence = try c.decode(Int.self, forKey: .fence); lease = try c.decodeIfPresent(Lease.self, forKey: .lease)
        drafts = try c.decode([Draft].self, forKey: .drafts); log = try c.decode([LogEntry].self, forKey: .log)
        versions = Dictionary(uniqueKeysWithValues: try c.decode([VersionEntry].self, forKey: .versions).map {
            ($0.path, Version(g: $0.g, fp: $0.fp))
        })
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(epoch, forKey: .epoch); try c.encode(generation, forKey: .generation); try c.encode(fence, forKey: .fence)
        try c.encode(lease, forKey: .lease)  // explicit null, not an absent key
        try c.encode(drafts, forKey: .drafts); try c.encode(log, forKey: .log)
        try c.encode(versions.sorted { $0.key < $1.key }.map { VersionEntry(path: $0.key, g: $0.value.g, fp: $0.value.fp) },
                     forKey: .versions)
    }
}

public func versionToken(_ version: Version?) -> String? {
    guard let version else { return nil }
    return "\(version.g):" + hex(SHA256.hash(data: Data(version.fp.utf8))).prefix(16)
}

/// Swift port of the plan500-lease Python gateway: the sole issuer of write leases, fences and
/// change generations for one workspace. Guest RPCs are made outside the lock except `/revoke`,
/// which, like the Python stand-in, is serialized with every other state change.
public final class Gateway {
    public let workspace: Workspace
    public let identity: String
    let stateDirectory: String
    let transport: GuestTransport
    let lock = NSRecursiveLock()
    public private(set) var s: GatewayState
    public private(set) var guestAck = 0

    var drafts: String { stateDirectory + "/drafts" }

    public init(workspace: String, state: String, identity: String, transport: GuestTransport) throws {
        self.workspace = Workspace(root: workspace); self.identity = identity
        stateDirectory = state; self.transport = transport
        try FileManager.default.createDirectory(atPath: state + "/drafts", withIntermediateDirectories: true)
        if let data = FileManager.default.contents(atPath: state + "/gateway.json") {
            s = try JSONDecoder().decode(GatewayState.self, from: data)
            // A restarted gateway cannot prove a previous writer is gone.
            if s.lease != nil { s.lease!.state = "WRITER_UNKNOWN" }
        } else {
            s = GatewayState()
            s.versions = try self.workspace.scan().mapValues { Version(g: 0, fp: $0) }
        }
        try persist()
    }

    func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let directory = open(stateDirectory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw WorkspaceError.io("open", errno) }
        defer { close(directory) }
        try atomicReplace(directory: directory, name: Array("gateway.json".utf8), data: try encoder.encode(s), mode: 0o600)
    }

    public func snapshot() -> (GatewayState, Int) { lock.lock(); defer { lock.unlock() }; return (s, guestAck) }

    public func version(_ path: RelativePath) -> String? { lock.lock(); defer { lock.unlock() }; return versionToken(s.versions[path]) }

    public func attach() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let bound = try transport.rpc("/bind", ["epoch": s.epoch])
        guestAck = bound["generation"] as? Int ?? 0
        notify()
        return bound
    }

    @discardableResult func notify() -> Bool {
        let entries = s.log.filter { $0.generation > guestAck }
        if entries.isEmpty { return true }
        let body: [String: Any] = ["entries": entries.map {
            ["generation": $0.generation, "origin": $0.origin, "paths": $0.paths.map(\.json)] as [String: Any]
        }]
        guard let answer = try? transport.rpc("/notify", body), let generation = answer["generation"] as? Int else { return false }
        guestAck = generation
        return true
    }

    func commit(_ paths: [RelativePath], origin: String, current: [RelativePath: String]) throws -> Int {
        s.generation += 1
        let generation = s.generation
        for path in paths {
            if let fp = current[path] { s.versions[path] = Version(g: generation, fp: fp) } else { s.versions[path] = nil }
        }
        s.log.append(LogEntry(generation: generation, origin: origin, paths: paths.sorted()))
        try persist(); notify()
        return generation
    }

    func commitOne(_ path: RelativePath, origin: String) throws -> Int {
        var current: [RelativePath: String] = [:]
        current[path] = try workspace.fingerprint(path)
        return try commit([path], origin: origin, current: current)
    }

    func writeNow(_ path: RelativePath, _ data: Data, base: String?) throws -> [String: Any] {
        let current = s.versions[path]
        if versionToken(current) != base {
            return ["status": "CONFLICT", "reason": "VERSION", "current": versionToken(current) ?? NSNull()]
        }
        let disk = try workspace.fingerprint(path)
        if disk != current?.fp {
            // Another host writer bypassed the gateway; record it and refuse to overwrite.
            _ = try commitOne(path, origin: "external")
            return ["status": "CONFLICT", "reason": "EXTERNAL_CHANGE", "current": versionToken(s.versions[path]) ?? NSNull()]
        }
        var mode: mode_t?
        if let disk, disk.hasPrefix("F:"), let parsed = mode_t(disk.split(separator: ":").last!, radix: 8) { mode = parsed }
        try workspace.write(path, data, mode: mode)
        _ = try commitOne(path, origin: "native")
        return ["status": "WRITTEN", "version": versionToken(s.versions[path]) ?? NSNull()]
    }

    public func nativeWrite(_ path: RelativePath, _ data: Data, base: String?) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        do { try path.validate() } catch WorkspaceError.pathRefused(let reason) { return ["status": "REFUSED", "reason": reason] }
        if s.lease != nil {
            let identifier = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let directory = open(drafts, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else { throw WorkspaceError.io("open", errno) }
            defer { close(directory) }
            try atomicReplace(directory: directory, name: Array(identifier.utf8), data: data, mode: 0o600)
            s.drafts.append(Draft(id: identifier, path: path, base: base, status: "HELD"))
            try persist()
            return ["status": "DRAFT_HELD", "draft": identifier]
        }
        do { return try writeNow(path, data, base: base) }
        catch WorkspaceError.pathRefused(let reason) { return ["status": "REFUSED", "reason": reason] }
    }

    public func acquire(_ operation: String) throws -> Lease? {
        lock.lock(); defer { lock.unlock() }
        if s.lease != nil { return nil }
        s.fence += 1
        s.lease = Lease(op: operation, epoch: s.epoch, fence: s.fence, state: "ACTIVE", baseline: try workspace.scan())
        try persist()  // The grant is durable before any request leaves the gateway.
        return s.lease
    }

    public func runLeased(_ operation: String, argv: [String], timeout: Int, test: [String: Any] = [:]) throws -> [String: Any] {
        guard let lease = try acquire(operation) else { return ["status": "LEASE_BUSY"] }
        var request: [String: Any] = ["id": operation, "projectId": identity, "argv": argv, "timeoutMs": timeout,
                                      "cwd": "/workspace", "lease": ["epoch": lease.epoch, "fence": lease.fence]]
        for (key, value) in test { request[key] = value }
        let result: [String: Any]
        do { result = try transport.rpc("/execute", request) }
        catch TransportError.refused(_, let error) {
            // Every agent refusal happens before spawn; nothing can still hold the rw view.
            lock.lock(); defer { lock.unlock() }
            return try release("REFUSED", fence: lease.fence).merging(["refusal": error ?? NSNull()]) { $1 }
        } catch {
            lock.lock(); defer { lock.unlock() }
            if s.lease?.fence == lease.fence { s.lease!.state = "WRITER_UNKNOWN"; try persist() }
            return ["status": "WRITER_UNKNOWN"]
        }
        lock.lock(); defer { lock.unlock() }
        if result["writerQuiescent"] as? Bool != true {
            if s.lease?.fence == lease.fence { s.lease!.state = "WRITER_UNKNOWN"; try persist() }
            return ["status": "WRITER_UNKNOWN", "result": result]
        }
        return try release("COMPLETED", fence: lease.fence).merging(["result": result]) { $1 }
    }

    func release(_ reason: String, fence: Int? = nil) throws -> [String: Any] {
        guard let lease = s.lease, fence == nil || lease.fence == fence else { return ["status": "LEASE_GONE", "reason": reason] }
        let current = try workspace.scan()
        let changed = Set(lease.baseline.keys).union(current.keys).filter { lease.baseline[$0] != current[$0] }.sorted()
        s.lease = nil
        let generation = changed.isEmpty ? s.generation : try commit(changed, origin: "linux", current: current)
        let outcomes = try rebase()
        return ["status": "RELEASED", "reason": reason, "fence": lease.fence, "generation": generation,
                "changed": changed.map(\.json), "drafts": outcomes]
    }

    func rebase() throws -> [[String: Any]] {
        var outcomes: [[String: Any]] = []
        for index in s.drafts.indices where s.drafts[index].status == "HELD" {
            let draft = s.drafts[index]
            let data = try Data(contentsOf: URL(fileURLWithPath: drafts + "/" + draft.id))
            let written: Bool
            do { written = try writeNow(draft.path, data, base: draft.base)["status"] as? String == "WRITTEN" }
            catch WorkspaceError.pathRefused { written = false }
            s.drafts[index].status = written ? "APPLIED" : "CONFLICT"
            outcomes.append(["path": draft.path.json, "status": s.drafts[index].status,
                             "current": versionToken(s.versions[draft.path]) ?? NSNull()])
        }
        try persist()
        return outcomes
    }

    /// `vmExited` comes from the VM owner (QemuBridge on iPad, the Python harness here): only a
    /// confirmed exit may release an unreachable writer.
    public func reconcile(vmExited: Bool) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let lease = s.lease else { return ["status": "NO_LEASE"] }
        if vmExited {
            // The next boot gets a new epoch that old leases cannot use.
            s.epoch += 1; guestAck = 0
            return try release("GUEST_TERMINATED")
        }
        let status: [String: Any]
        do { status = try transport.rpc("/revoke", ["epoch": lease.epoch, "fence": lease.fence]) }
        catch { return ["status": "HELD", "reason": "UNREACHABLE"] }
        if status["revoked"] as? Bool != true { return ["status": "HELD", "reason": "WRITER_RUNNING"] }
        return try release("RECONCILED").merging(["started": status["started"] ?? NSNull()]) { $1 }
    }
}
