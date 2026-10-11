import CryptoKit
import Darwin
import Foundation
import UserDataMigration

/// Brings the old App's full backup into the candidate (#17 migration drill). The old App and its disk
/// are never opened: `UserDataMigrator` verifies the archive into `<root>/migrations/<id>` in one rename,
/// then every old project becomes a plugin-enabled candidate project and the old official home becomes
/// a pending home import the next Worker restore merges (`SessionRecovery`). Credentials, caches and the
/// old Linux home (`linux-home`) are not carried into projects; the last stays beside the migration.
///
/// Each step can be repeated after a crash: project ids derive from the archive digest and the name, a
/// project is registered only once its workspace is in place, and `.adopted` marks the end. Running
/// again with the same archive reports what was imported without changing anything.
public enum BackupImport {
    public static let directory = "migrations"
    static let adopted = ".adopted"

    public struct Summary: Codable, Equatable {
        public var archiveSha256 = ""
        public var projects: [String] = []
        public var files = 0, bytes: Int64 = 0, sessions = 0, sessionsMoved = 0
        public var homeFiles = 0, homeSymlinksSkipped = 0
        public var credentialsExcluded = 0, cacheEntriesExcluded = 0, specialSkipped = 0, linuxHomeEntries = 0
        public var alreadyImported = false
    }

    public static func run(archive: String, checksum: String, registry: ProjectRegistry,
                           options: MigrationOptions = defaultOptions()) throws -> Summary {
        let sidecar = (try? String(contentsOfFile: checksum, encoding: .utf8)) ?? ""
        guard let digest = sidecar.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased(),
              digest.count == 64, digest.allSatisfy(\.isHexDigit) else { throw CandidateError(MigrationError.checksumFileInvalid.code) }
        let root = registry.root + "/" + directory
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = root + "/" + digest.prefix(16)
        let report: MigrationReport
        do {
            switch try UserDataMigrator(archive: archive, checksum: checksum, target: target, options: options).run() {
            case .migrated(let value), .alreadyMigrated(let value): report = value
            }
        } catch let error as MigrationError { throw CandidateError(error.code) }

        if let data = FileManager.default.contents(atPath: target + "/" + adopted),
           var done = try? JSONDecoder().decode(Summary.self, from: data) {
            done.alreadyImported = true
            return done
        }
        var summary = Summary(archiveSha256: report.archiveSha256, files: report.files, bytes: report.bytes,
                              sessions: report.sessions, sessionsMoved: report.sessionsMoved,
                              credentialsExcluded: report.credentialsExcluded.count, cacheEntriesExcluded: report.cacheEntriesExcluded,
                              specialSkipped: report.specialSkipped.count)
        summary.linuxHomeEntries = ((try? FileManager.default.contentsOfDirectory(atPath: target + "/linux-home")) ?? []).count
        let names = try plan(target, registry, digest)
        summary.projects = names

        // The home goes first: a project without its sessions is still usable, the reverse is not.
        let home = try homeSnapshot(target + "/home", &summary)
        let importFile = registry.root + "/" + SessionRecovery.importDirectory + "/" + digest.prefix(16) + ".json"
        if !FileManager.default.fileExists(atPath: importFile) {
            try FileManager.default.createDirectory(atPath: registry.root + "/" + SessionRecovery.importDirectory,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ProjectRegistry.durableWrite(try JSONEncoder().encode(home), to: importFile)
        }
        for name in names {
            let id = projectId(digest, name)
            if registry.project(id) != nil { continue }
            try registry.adopt(id: id, name: name, workspace: target + "/projects/" + name)
        }
        try ProjectRegistry.durableWrite(try JSONEncoder().encode(summary), to: target + "/" + adopted)
        return summary
    }

    public static func defaultOptions() -> MigrationOptions {
        var options = MigrationOptions()
        options.codec = try? DynamicZstd()
        return options
    }

    /// Old projects by name, decided once and kept beside the migration so a resumed run adopts the same
    /// set after some workspaces already moved. Any name the candidate cannot take refuses the whole import.
    private static func plan(_ target: String, _ registry: ProjectRegistry, _ digest: String) throws -> [String] {
        let record = target + "/.adopt-plan.json"
        let names: [String]
        if let data = FileManager.default.contents(atPath: record) {
            guard let saved = try? JSONDecoder().decode([String].self, from: data) else { throw CandidateError("IMPORT_PLAN_CORRUPT") }
            names = saved
        } else {
            var found: [String] = []
            for name in (try? FileManager.default.contentsOfDirectory(atPath: target + "/projects")) ?? [] {
                var info = stat()
                guard lstat(target + "/projects/" + name, &info) == 0 else { throw CandidateError("IMPORT_READ_FAILED") }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw CandidateError("IMPORT_PROJECT_NOT_DIRECTORY") }
                try ProjectRegistry.validate(name: name)
                found.append(name)
            }
            names = found.sorted()
            try ProjectRegistry.durableWrite(try JSONEncoder().encode(names), to: record)
        }
        for name in names {
            if let other = registry.projects.first(where: { $0.name == name }), other.id != projectId(digest, name) {
                throw CandidateError("PROJECT_NAME_TAKEN")
            }
        }
        return names
    }

    /// A stable UUID (version 8 layout) from the archive digest and the project name.
    static func projectId(_ digest: String, _ name: String) -> String {
        var bytes = Array(SHA256.hash(data: Data((digest + "\0" + name).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    /// The migrated official home as the Worker's home transport. Symlinks have no form there and are
    /// counted, not followed.
    private static func homeSnapshot(_ home: String, _ summary: inout Summary) throws -> HomeSnapshot {
        var directories: [HomeSnapshot.Directory] = [], files: [HomeSnapshot.File] = []
        func walk(_ relative: String) throws {
            let path = relative.isEmpty ? home : home + "/" + relative
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                let child = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(home + "/" + child, &info) == 0 else { throw CandidateError("IMPORT_READ_FAILED") }
                let time = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec / 1_000_000)
                let mode = Int(info.st_mode)
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    directories.append(.init(path: "/dsh/home/" + child, mode: mode, mtimeMs: time))
                    try walk(child)
                case S_IFREG:
                    guard let data = FileManager.default.contents(atPath: home + "/" + child) else { throw CandidateError("IMPORT_READ_FAILED") }
                    files.append(.init(path: "/dsh/home/" + child, mode: mode, mtimeMs: time, base64: data.base64EncodedString()))
                default: summary.homeSymlinksSkipped += 1
                }
            }
        }
        if FileManager.default.fileExists(atPath: home) { try walk("") }
        let snapshot = HomeSnapshot(formatVersion: 1, directories: directories, files: files)
        try snapshot.validate()
        summary.homeFiles = files.count
        return snapshot
    }
}
