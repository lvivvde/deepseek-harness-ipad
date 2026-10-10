import Foundation
import Darwin
import CryptoKit
import CoreFoundation
import NativeWorkspace

/// Owns the native half of the home recovery contract. Its lock serializes selection, capture tickets,
/// durable replacement and status; project stores are sampled through their existing gateway locks.
final class SessionRecovery {
    struct Baseline: Codable { let generation: Int; let available: Bool }
    private struct Body: Codable {
        let initialization: String
        let id: String; let sequence: Int; let revision: Int; let savedAt: Double
        let home: HomeSnapshot; let projects: [String: Baseline]
    }
    private struct Envelope: Codable { let formatVersion: Int; let body: Data; let checksum: String }
    private struct Marker: Codable {
        let formatVersion: Int; let initialization: String; let empty: Bool
        let diagnosis: String?
        /// Exact preserved bytes from the blocked state; only these may be ignored by an empty marker.
        let preserved: [String: String]?
    }
    private struct Copy { let body: Body; let bytes: Data }
    private struct Capture { let id: String; let revision: Int; let projects: [String: Baseline] }
    private let root: String
    private let lock = NSLock()
    private let fault: FaultHook?
    private var worker = ""
    private var initialization = UUID().uuidString
    private var revision = 0, savedRevision = 0
    private var capture: Capture?
    private var selected: Copy?
    private var baseline: [String: Baseline] = [:]
    private var phase = "NOT_STARTED", diagnosis: String?, saveError: String?
    private var savedAt: Double?
    init(root: String, fault: FaultHook? = nil) { self.root = root; self.fault = fault }

    private func path(_ name: String) -> String { root + "/" + name }
    private func write(_ bytes: Data, _ name: String) throws { try durableReplace(path(name), bytes, mode: 0o600, fault: fault) }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func read(_ name: String) throws -> Data? {
        do { return try Data(contentsOf: URL(fileURLWithPath: path(name))) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            var entry = stat()
            if lstat(path(name), &entry) == 0 || errno != ENOENT { throw CandidateError("CHECKPOINT_READ_FAILED") }
            return nil
        }
    }
    private func decode(_ bytes: Data) throws -> Copy {
        if let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let version = object["formatVersion"] as? Int, version != 2 { throw CandidateError("CHECKPOINT_VERSION") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.formatVersion == 2 else { throw CandidateError("CHECKPOINT_VERSION") }
        guard Self.hash(envelope.body) == envelope.checksum else { throw CandidateError("CHECKPOINT_CORRUPT") }
        let body = try JSONDecoder().decode(Body.self, from: envelope.body)
        guard !body.initialization.isEmpty, !body.id.isEmpty, body.sequence > 0, body.revision >= 0, body.savedAt.isFinite, body.savedAt > 0,
              body.projects.values.allSatisfy({ $0.generation >= 0 }) else { throw CandidateError("CHECKPOINT_CORRUPT") }
        try body.home.validate()
        return Copy(body: body, bytes: bytes)
    }
    /// Copies evidence durably; the source stays until a successful replacement. Failure blocks recovery.
    private func quarantine(_ bytes: Data, _ name: String) throws {
        let directory = path("home-quarantine")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try durableReplace(directory + "/" + name + "-" + Self.hash(bytes) + ".json", bytes, mode: 0o600, fault: fault)
        // Sync the new directory's parent entry using the same durable primitive.
        try write(Data("1".utf8), "home-quarantine-created")
    }

    func restore() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        worker = UUID().uuidString; revision = 0; savedRevision = 0; capture = nil
        selected = nil; baseline = [:]; savedAt = nil; saveError = nil; diagnosis = nil
        do {
            let markerBytes = try read("home-initialized.json")
            let marker = try markerBytes.map { try JSONDecoder().decode(Marker.self, from: $0) }
            guard marker == nil || marker?.formatVersion == 1 else { throw CandidateError("CHECKPOINT_VERSION") }
            if let marker {
                guard !marker.initialization.isEmpty else { throw CandidateError("CHECKPOINT_CORRUPT") }
                initialization = marker.initialization; diagnosis = marker.diagnosis
            } else { initialization = UUID().uuidString }
            var copies: [Copy] = [], damaged = false
            for name in ["home-current.json", "home-previous.json"] {
                if let bytes = try read(name) {
                    if marker?.empty == true, marker?.preserved?[name] == Self.hash(bytes) { continue }
                    do {
                        let copy = try decode(bytes)
                        guard marker == nil || copy.body.initialization == initialization else { throw CandidateError("CHECKPOINT_IDENTITY") }
                        copies.append(copy)
                    }
                    catch {
                        try quarantine(bytes, name); damaged = true
                        if (error as? CandidateError)?.code == "CHECKPOINT_VERSION" { throw error }
                    }
                }
            }
            if let latest = copies.max(by: { $0.body.sequence < $1.body.sequence }) {
                initialization = latest.body.initialization
                selected = latest; baseline = latest.body.projects; savedAt = latest.body.savedAt
                phase = "SAVED"; if damaged { diagnosis = "CHECKPOINT_FALLBACK" }
                // Persist initialized status even if an earlier save died after replacing the home.
                try write(try JSONEncoder().encode(Marker(formatVersion: 1, initialization: initialization, empty: false, diagnosis: diagnosis, preserved: nil)), "home-initialized.json")
                return reply(latest.body.home)
            }
            if marker?.empty == true && !damaged { phase = "UNSAVED"; return reply(nil) }
            if marker == nil, let legacy = try read(CandidateHost.homeCheckpoint) {
                do {
                    let home = try HomeSnapshot.decode(JSONSerialization.jsonObject(with: legacy))
                    phase = "UNSAVED"; diagnosis = "LEGACY_CHECKPOINT"
                    return reply(home)
                } catch { try quarantine(legacy, CandidateHost.homeCheckpoint); throw error }
            }
            guard marker == nil && !damaged else { throw CandidateError("CHECKPOINT_MISSING_OR_CORRUPT") }
            try write(try JSONEncoder().encode(Marker(formatVersion: 1, initialization: initialization, empty: true, diagnosis: nil, preserved: nil)), "home-initialized.json")
            phase = "UNSAVED"; return reply(nil)
        } catch {
            phase = "BLOCKED"; diagnosis = (error as? CandidateError)?.code ?? "CHECKPOINT_READ_FAILED"
            return ["error": "RECOVERY_BLOCKED", "diagnosis": diagnosis!, "worker": worker]
        }
    }
    private func reply(_ home: HomeSnapshot?) -> [String: Any] {
        ["snapshot": home.map(CandidateHost.json) ?? NSNull(), "worker": worker,
         "diagnosis": diagnosis as Any? ?? NSNull(), "savedAt": savedAt as Any? ?? NSNull()]
    }
    func fresh() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard phase == "BLOCKED" else { throw CandidateError("FRESH_START_REFUSED") }
        var preserved: [String: String] = [:]
        for name in ["home-current.json", "home-previous.json", CandidateHost.homeCheckpoint, "home-initialized.json"] {
            if let bytes = try read(name) { try quarantine(bytes, name); preserved[name] = Self.hash(bytes) }
        }
        let next = UUID().uuidString
        let retainedDiagnosis = "FRESH_START_PRESERVED: " + (diagnosis ?? "RECOVERY_BLOCKED")
        try write(try JSONEncoder().encode(Marker(formatVersion: 1, initialization: next, empty: true,
                                                diagnosis: retainedDiagnosis, preserved: preserved)), "home-initialized.json")
        initialization = next
        worker = ""; capture = nil; selected = nil; baseline = [:]; phase = "UNSAVED"; savedAt = nil
        diagnosis = retainedDiagnosis; saveError = nil
        return ["fresh": true]
    }
    private func authorize(_ body: [String: Any]) throws {
        guard !worker.isEmpty, body["worker"] as? String == worker else { throw CandidateError("STALE_WORKER") }
        guard phase != "BLOCKED" else { throw CandidateError("RECOVERY_BLOCKED") }
    }
    private func receivedRevision(_ body: [String: Any]) throws -> Int {
        guard let value = body["revision"] as? Int, (body["revision"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true, value >= 0 else { throw CandidateError("REVISION_REFUSED") }
        return value
    }
    func changed(_ body: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; try authorize(body)
        revision = max(revision, try receivedRevision(body))
        if revision > savedRevision && phase != "SAVING" { phase = "UNSAVED" }
        if let code = body["failure"] as? String { saveError = String(code.prefix(80)); phase = "UNSAVED"; capture = nil }
        return [:]
    }
    func begin(_ request: [String: Any], sample: () -> [String: Baseline]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; try authorize(request)
        let value = try receivedRevision(request)
        guard value >= savedRevision, capture == nil else { throw CandidateError("CAPTURE_REFUSED") }
        revision = max(revision, value)
        let ticket = Capture(id: UUID().uuidString, revision: value, projects: sample())
        capture = ticket; phase = "SAVING"
        return ["capture": ticket.id, "worker": worker]
    }
    func save(_ request: [String: Any]) throws -> [String: Any] {
        // Validate before modifying state or any file.
        let home = try HomeSnapshot.decode(request["snapshot"])
        lock.lock(); defer { lock.unlock() }; try authorize(request)
        guard let ticket = capture, request["capture"] as? String == ticket.id else { throw CandidateError("CAPTURE_REFUSED") }
        let value = try receivedRevision(request)
        guard value >= ticket.revision, value >= savedRevision else { throw CandidateError("REVISION_REFUSED") }
        defer { capture = nil }
        do {
            let body = Body(initialization: initialization, id: UUID().uuidString, sequence: (selected?.body.sequence ?? 0) + 1, revision: value,
                            savedAt: Date().timeIntervalSince1970, home: home, projects: ticket.projects)
            let bytes = try JSONEncoder().encode(body)
            let envelope = try JSONEncoder().encode(Envelope(formatVersion: 2, body: bytes, checksum: Self.hash(bytes)))
            // With no selected copy (first save, legacy migration or explicit fresh), replace both slots.
            // Fresh preserved them in quarantine; a higher sequence from the old home must never win.
            try write(selected?.bytes ?? envelope, "home-previous.json")
            try write(envelope, "home-current.json")
            let verified = try decode(Data(contentsOf: URL(fileURLWithPath: path("home-current.json"))))
            guard verified.body.id == body.id else { throw CandidateError("CHECKPOINT_VERIFY_FAILED") }
            let retainedDiagnosis = diagnosis == "LEGACY_CHECKPOINT" ? nil : diagnosis
            try write(try JSONEncoder().encode(Marker(formatVersion: 1, initialization: initialization, empty: false, diagnosis: retainedDiagnosis, preserved: nil)), "home-initialized.json")
            selected = verified; savedRevision = value; revision = max(revision, value); savedAt = body.savedAt
            phase = revision > value ? "UNSAVED" : "SAVED"; saveError = nil
            // Baselines used for reopen notices stay attached to the restored home for this Worker.
            return ["durable": true, "worker": worker, "capture": ticket.id, "revision": value, "savedAt": body.savedAt]
        } catch { phase = "UNSAVED"; saveError = "CHECKPOINT_FAILED"; throw CandidateError("CHECKPOINT_FAILED") }
    }
    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["phase": phase, "diagnosis": diagnosis as Any? ?? NSNull(), "failure": saveError as Any? ?? NSNull(),
                "savedAt": savedAt as Any? ?? NSNull()]
    }
    func comparison(_ id: String, generation: Int, available: Bool) -> String {
        lock.lock(); defer { lock.unlock() }
        guard available, let previous = baseline[id], previous.available else { return "UNAVAILABLE" }
        return generation == previous.generation ? "UNCHANGED" : "CHANGED"
    }
}
