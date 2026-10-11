import Darwin
import Foundation
import NativeWorkspace

/// A refusal with a fixed code, made before anything ran.
public struct CandidateError: Error, Equatable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

/// One candidate project: a native workspace the Worker sees at `/dsh/workspace/<name>`, with the
/// Linux plugin enabled or not.
public struct CandidateProject: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let pluginEnabled: Bool
    public var mount: String { "/dsh/workspace/" + name }
}

/// The candidate's projects under `<root>/projects/<id>/`: `project.json`, the native `workspace`,
/// the store's `state`. Native tools share one scratch directory, `<root>/scratch`.
public final class ProjectRegistry: @unchecked Sendable {
    public let root: String
    private let lock = NSLock()
    private var known: [CandidateProject] = []

    public init(root: String) throws {
        self.root = root
        try FileManager.default.createDirectory(atPath: root + "/projects", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        for id in try FileManager.default.contentsOfDirectory(atPath: root + "/projects") where UUID(uuidString: id) != nil {
            guard let data = FileManager.default.contents(atPath: root + "/projects/" + id + "/project.json") else { continue }
            let project = try JSONDecoder().decode(CandidateProject.self, from: data)
            guard project.id == id else { throw CandidateError("PROJECT_RECORD_REFUSED") }
            known.append(project)
        }
    }

    public var projects: [CandidateProject] {
        lock.lock(); defer { lock.unlock() }; return known.sorted { $0.name < $1.name }
    }

    public var scratch: String { root + "/scratch" }
    public func directory(_ project: CandidateProject) -> String { root + "/projects/" + project.id }
    public func workspace(_ project: CandidateProject) -> String { directory(project) + "/workspace" }
    public func state(_ project: CandidateProject) -> String { directory(project) + "/state" }

    public func project(_ id: String) -> CandidateProject? {
        lock.lock(); defer { lock.unlock() }; return known.first { $0.id == id }
    }

    /// Names are one visible path component: no `/`, NUL or control characters, no leading dot, at
    /// most 64 bytes.
    public func create(name: String, pluginEnabled: Bool) throws -> CandidateProject {
        try Self.validate(name: name)
        lock.lock(); defer { lock.unlock() }
        guard !known.contains(where: { $0.name == name }) else { throw CandidateError("PROJECT_NAME_TAKEN") }
        let project = CandidateProject(id: UUID().uuidString, name: name, pluginEnabled: pluginEnabled)
        let base = directory(project)
        try FileManager.default.createDirectory(atPath: workspace(project), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: state(project), withIntermediateDirectories: true)
        try Self.durableWrite(try JSONEncoder().encode(project), to: base + "/project.json")
        known.append(project)
        return project
    }

    static func validate(name: String) throws {
        guard (1...64).contains(name.utf8.count), !name.hasPrefix("."), !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CandidateError("PROJECT_NAME_REFUSED")
        }
    }

    /// Registers a migrated project, plugin enabled, by moving `workspace` into place. The record is
    /// written last, so a crash before it leaves no project and a later call finishes the same one.
    func adopt(id: String, name: String, workspace source: String) throws {
        try Self.validate(name: name)
        lock.lock(); defer { lock.unlock() }
        guard !known.contains(where: { $0.id == id }) else { return }
        guard !known.contains(where: { $0.name == name }) else { throw CandidateError("PROJECT_NAME_TAKEN") }
        let project = CandidateProject(id: id, name: name, pluginEnabled: true)
        let base = directory(project)
        try FileManager.default.createDirectory(atPath: state(project), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: source) {
            guard !FileManager.default.fileExists(atPath: workspace(project)) else { throw CandidateError("IMPORT_WORKSPACE_EXISTS") }
            guard rename(source, workspace(project)) == 0 else { throw CandidateError("IMPORT_MOVE_FAILED") }
        }
        guard FileManager.default.fileExists(atPath: workspace(project)) else { throw CandidateError("IMPORT_WORKSPACE_MISSING") }
        try Self.durableWrite(try JSONEncoder().encode(project), to: base + "/project.json")
        known.append(project)
    }

    /// The workspace store's durable replace; the record is private to the App.
    static func durableWrite(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
        do { try durableReplace(path, data, mode: mode) } catch { throw CandidateError("STORE_FAILED") }
    }
}
