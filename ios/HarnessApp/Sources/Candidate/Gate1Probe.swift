import CryptoKit
import Foundation

/// Gate 1 against the real VM writer, driven through the operations the Worker bridge sends, so a
/// device run needs neither the model nor a key. A launch starts one phase:
/// - `hold`: a new plugin project runs a 9P command that appends one line, then sleeps holding the
///   write lease; a native write during it must become a draft. The App is then killed from outside.
/// - `check` (the next launch): the lease must come back as an unknown writer and stay held, the
///   command must not run again, and the draft must read back unchanged.
/// Each phase writes `<root>/probe/gate1-<phase>.json` with fixed fields only, and `passed` when every
/// condition of that phase held; `check` also compares the drafts with the ones `hold` recorded.
public enum Gate1Probe {
    public enum Phase: String { case hold, check }

    public struct Timing {
        public var ready: TimeInterval = 900
        public var writer: TimeInterval = 120
        /// How long `check` watches the unknown writer for an automatic release.
        public var settle: TimeInterval = 30
        public var poll: TimeInterval = 0.5
        public init() {}
    }

    static let command = "echo run >> runs.txt; sleep 300"
    static let draft = Data("draft during lease\n".utf8)

    public static func directory(_ host: CandidateHost) -> String { host.registry.root + "/probe" }

    /// Runs one phase and records it; `hold` returns while its command still holds the lease.
    @discardableResult
    public static func run(_ phase: Phase, host: CandidateHost, timing: Timing = .init()) -> [String: Any] {
        var record: [String: Any]
        do {
            record = try phase == .hold ? hold(host, timing) : check(host, timing)
        } catch let error as CandidateError {
            record = ["failure": error.code]
        } catch {
            record = ["failure": "PROBE_FAILED"]
        }
        record["phase"] = phase.rawValue
        try? FileManager.default.createDirectory(atPath: directory(host), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]) {
            FileManager.default.createFile(atPath: directory(host) + "/gate1-\(phase.rawValue).json", contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
        return record
    }

    private static func hold(_ host: CandidateHost, _ timing: Timing) throws -> [String: Any] {
        let name = "gate1-probe-\(host.registry.projects.count + 1)"
        let created = host.handle(["operation": "project-create", "name": name, "pluginEnabled": true])
        guard let id = (created["project"] as? [String: Any])?["id"] as? String else { throw CandidateError("PROJECT_REFUSED") }
        var record: [String: Any] = ["project": id]
        let mount = try open(host, id, &record, timing)
        guard record["phase.open"] as? String == "READY" else { return record }

        let command: [String: Any] = ["operation": "execute", "operationId": "gate1-hold", "command": command,
                                      "cwd": mount, "timeoutMs": 600_000, "trigger": "shell"]
        Thread.detachNewThread { _ = host.handle(command) }
        // Native reads keep the store's view until the lease ends; the writer shows on the share itself.
        let project = try registered(host, id)
        let runs = host.registry.workspace(project) + "/runs.txt"
        // `>>` creates the file before it writes the line; wait for the line itself.
        guard wait(timing.writer, timing.poll, { !(FileManager.default.contents(atPath: runs) ?? Data()).isEmpty }) else {
            record["failure"] = "WRITER_NOT_SEEN"; return record
        }
        record["runs.hold"] = FileManager.default.contents(atPath: runs).map { String(decoding: $0, as: UTF8.self) }

        let written = host.handle(["operation": "fs", "method": "write",
                                   "args": ["path": mount + "/draft.txt", "data": draft.base64EncodedString(),
                                            "expected": ["kind": "createIfAbsent"]]])
        record["write"] = (written["value"] as? [String: Any])?["operation"] as? String
            ?? ((written["failure"] as? [String: Any])?["code"] as? String) ?? "NONE"
        recordDrafts(host, project, &record)
        record["writerUnknown.hold"] = entry(host, id)?["writerUnknown"] as? Bool
        let passed = record["runs.hold"] as? String == "run\n" && record["write"] as? String == "WORKSPACE_DRAFT_HELD"
            && record["draft.matches"] as? Bool == true && record["workspace.hasDraft"] as? Bool == false
            && record["writerUnknown.hold"] as? Bool == false
        // Only a passed hold leaves a lease worth killing the App over; `check` refuses anything else.
        record["holding"] = passed
        record["passed"] = passed
        return record
    }

    private static func check(_ host: CandidateHost, _ timing: Timing) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: directory(host) + "/gate1-hold.json"),
              let hold = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              hold["holding"] as? Bool == true, let id = hold["project"] as? String else { throw CandidateError("NO_HOLD_RECORD") }
        var record: [String: Any] = ["project": id]
        let mount = try open(host, id, &record, timing)
        record["writerUnknown.open"] = entry(host, id)?["writerUnknown"] as? Bool
        Thread.sleep(forTimeInterval: timing.settle)
        record["writerUnknown.settled"] = entry(host, id)?["writerUnknown"] as? Bool
        let again = host.handle(["operation": "execute", "operationId": "gate1-check", "command": "true",
                                 "cwd": mount, "timeoutMs": 30_000, "trigger": "shell"])
        record["command.during"] = [again["status"] as? String ?? "NONE", again["reason"] as? String ?? ""].joined(separator: ":")
        let project = try registered(host, id)
        record["runs.check"] = FileManager.default.contents(atPath: host.registry.workspace(project) + "/runs.txt")
            .map { String(decoding: $0, as: UTF8.self) }
        recordDrafts(host, project, &record)
        record["drafts.unchanged"] = record["drafts"] as? [String: String] == hold["drafts"] as? [String: String]
        record["passed"] = record["writerUnknown.open"] as? Bool == true && record["writerUnknown.settled"] as? Bool == true
            && record["command.during"] as? String == "REFUSED:WRITER_UNKNOWN" && record["runs.check"] as? String == "run\n"
            && record["drafts.unchanged"] as? Bool == true && record["draft.matches"] as? Bool == true
            && record["workspace.hasDraft"] as? Bool == false
        return record
    }

    /// Opens the project and waits for Linux to settle; records the phase and returns the mount.
    private static func open(_ host: CandidateHost, _ id: String, _ record: inout [String: Any], _ timing: Timing) throws -> String {
        guard let mount = (host.handle(["operation": "project-open", "id": id])["project"] as? [String: Any])?["mount"] as? String else {
            throw CandidateError("PROJECT_UNKNOWN")
        }
        _ = wait(timing.ready, timing.poll) { entry(host, id)?["phase"] as? String != "PREPARING" }
        record["phase.open"] = entry(host, id)?["phase"] as? String
        record["reason.open"] = entry(host, id)?["reason"] as? String
        return mount
    }

    private static func registered(_ host: CandidateHost, _ id: String) throws -> CandidateProject {
        guard let project = host.registry.project(id) else { throw CandidateError("PROJECT_UNKNOWN") }
        return project
    }

    private static func entry(_ host: CandidateHost, _ id: String) -> [String: Any]? {
        (host.handle(["operation": "projects"])["projects"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    /// Records the store's held drafts on disk (name: SHA-256), whether exactly one carries the probe's
    /// bytes, and whether the draft leaked into the workspace.
    private static func recordDrafts(_ host: CandidateHost, _ project: CandidateProject, _ record: inout [String: Any]) {
        let directory = host.registry.state(project) + "/drafts"
        var drafts: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            if let data = FileManager.default.contents(atPath: directory + "/" + name) { drafts[name] = digest(data) }
        }
        record["drafts"] = drafts
        record["draft.matches"] = drafts.values.filter { $0 == digest(draft) }.count == 1
        record["workspace.hasDraft"] = FileManager.default.fileExists(atPath: host.registry.workspace(project) + "/draft.txt")
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func wait(_ limit: TimeInterval, _ poll: TimeInterval, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while !done() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
        return true
    }
}
