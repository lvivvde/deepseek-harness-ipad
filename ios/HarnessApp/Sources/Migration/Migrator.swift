import Darwin
import Foundation

/// Places where a migration can be interrupted. The crash probe kills the process at one of them; tests
/// throw an injected error (ENOSPC) at one of them. Production code passes no hook.
public enum MigrationStage: String, CaseIterable {
    /// After the archive digest matched, before the plan pass.
    case digest
    /// After the plan, before the stage directory exists.
    case plan
    /// Inside each file write, after its first half (reached once per file, empty files included).
    case extract
    /// After every entry is in the stage, before the independent verify walk.
    case verify
    /// Before each session directory is converted.
    case sessions
    /// Before the marker is written into the stage.
    case marker
    /// Everything is durable in the stage; the switch rename is next.
    case switching
    /// The target is in place; the parent directory is not yet synced.
    case switched
}

public typealias MigrationFaultHook = (MigrationStage) throws -> Void

public struct MigrationOptions {
    /// The old guest's project root and the cwd prefix the Worker uses now (ADR 0003 leaves the mapping
    /// open; the research prototype mounts each project at `/dsh/workspace/<name>`).
    public var oldProjectsRoot = "/root/projects"
    public var newProjectsRoot = "/dsh/workspace"
    /// Free space that must remain after the migrated tree (on top of a block per entry).
    public var reserveBytes: Int64 = 64 << 20
    public var maxEntries = 100_000
    public var codec: SessionLogCodec?
    public var fault: MigrationFaultHook?
    /// Free bytes on the target volume; tests replace it.
    public var availableBytes: (String) throws -> Int64 = UserDataMigrator.freeBytes

    public init() {}
}

/// Counts and digests only; the path lists stay in the private report the app keeps beside the data.
public struct MigrationReport: Codable, Equatable {
    public var archiveSha256 = ""
    /// SHA-256 over the sorted manifest lines (kind, path, mode, content digest or link): the same archive
    /// gives the same value on every device.
    public var manifestSha256 = ""
    public var files = 0, directories = 0, symlinks = 0, hardlinks = 0
    public var bytes: Int64 = 0
    public var specialSkipped: [String] = []
    public var credentialsExcluded: [String] = []
    public var cacheEntriesExcluded = 0
    public var sessions = 0, sessionsDecompressed = 0, sessionsMoved = 0, sessionsOutsideProjects = 0
}

public enum MigrationOutcome: Equatable {
    case migrated(MigrationReport)
    /// The target already holds this archive's migration; nothing was read or written.
    case alreadyMigrated(MigrationReport)
}

/// Migrates the old app's full backup (`HarnessBackup.tar` plus its `.sha256` sidecar) into a new target
/// directory. The old app's disk is never opened: the backup is the only input, so the old app keeps its
/// data and keeps working after a reinstall. Credentials are never carried over.
///
/// The target changes in exactly one step, the rename of a fully verified stage directory beside it. Any
/// failure or process death before that leaves the target as it was; a later run cleans stale stages and
/// starts over. After it, the target carries `.migration.json` with the archive digest, so running again
/// with the same archive is `alreadyMigrated` and never overwrites changes made since; a different archive
/// is `targetExists`.
public final class UserDataMigrator {
    public static let marker = ".migration.json"
    public static let lockName = ".migration.lock"
    public static let stagePrefix = ".migration-stage-"

    let archive: String, checksum: String, target: String
    let options: MigrationOptions
    let parent: String, targetName: Bytes

    public init(archive: String, checksum: String, target: String, options: MigrationOptions = MigrationOptions()) {
        self.archive = archive; self.checksum = checksum; self.options = options
        var trimmed = target
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.target = trimmed
        parent = (trimmed as NSString).deletingLastPathComponent
        targetName = Bytes((trimmed as NSString).lastPathComponent.utf8)
    }

    public static func freeBytes(_ path: String) throws -> Int64 {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw MigrationError.io("statfs", errno) }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    public func run() throws -> MigrationOutcome {
        let parentFD = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw MigrationError.io("open", errno) }
        defer { close(parentFD) }
        let lock = Bytes(Self.lockName.utf8).withCName { openat(parentFD, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard lock >= 0 else { throw MigrationError.io("openat", errno) }
        defer { close(lock) }  // Closing releases the lock, including on process death.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw MigrationError.busy }
            throw MigrationError.io("flock", errno)
        }

        let expected = try readChecksum()
        if let existing = try existingMigration(parentFD) {
            guard existing.archiveSha256 == expected else { throw MigrationError.targetExists }
            return .alreadyMigrated(existing)
        }
        try removeStaleStages(parentFD)
        do {
            return .migrated(try migrate(parentFD: parentFD, expected: expected))
        } catch let error as MigrationError {
            if case .io(_, ENOSPC) = error { throw MigrationError.insufficientSpace }
            throw error
        }
    }

    // MARK: Inputs

    /// `<64 hex>` optionally followed by whitespace and a file name, as `shasum -a 256` and the old export write.
    func readChecksum() throws -> String {
        guard let data = FileManager.default.contents(atPath: checksum), data.count <= 4096,
              let text = String(data: data, encoding: .utf8) else { throw MigrationError.checksumFileInvalid }
        let hex = text.prefix(64)
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }),
              text.count == 64 || text.dropFirst(64).first.map({ $0 == " " || $0 == "\t" || $0 == "\n" }) == true
        else { throw MigrationError.checksumFileInvalid }
        return hex.lowercased()
    }

    /// The report of a finished migration in the target, nil when the target is absent or an empty
    /// directory (which the switch rename replaces), `targetExists` for anything else.
    func existingMigration(_ parentFD: Int32) throws -> MigrationReport? {
        var info = stat()
        if targetName.withCName({ fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }) != 0 {
            if errno == ENOENT { return nil }
            throw MigrationError.io("fstatat", errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw MigrationError.targetExists }
        let names = try FileManager.default.contentsOfDirectory(atPath: target)
        if names.isEmpty { return nil }
        guard names.contains(Self.marker),
              let data = FileManager.default.contents(atPath: target + "/" + Self.marker),
              let report = try? JSONDecoder().decode(MigrationReport.self, from: data) else { throw MigrationError.targetExists }
        return report
    }

    func removeStaleStages(_ parentFD: Int32) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: parent) where name.hasPrefix(Self.stagePrefix) {
            try removeTree(parentFD, Bytes(name.utf8))
        }
    }

    func openArchive() throws -> Int32 {
        let descriptor = open(archive, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MigrationError.io("open", errno) }
        return descriptor
    }

    func archiveDigest() throws -> String {
        let descriptor = try openArchive()
        defer { close(descriptor) }
        var digest = StreamingDigest()
        var buffer = Data(count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw MigrationError.io("read", errno) }
            if count == 0 { break }
            digest.update(buffer.prefix(count))
        }
        return digest.hex()
    }

    // MARK: Migration

    func migrate(parentFD: Int32, expected: String) throws -> MigrationReport {
        guard try archiveDigest() == expected else { throw MigrationError.digestMismatch }
        try options.fault?(.digest)
        var report = MigrationReport()
        report.archiveSha256 = expected
        let plan = try makePlan(&report)
        guard plan.conflicts.isEmpty else { throw MigrationError.nameConflict(plan.conflicts.sorted()) }
        guard try options.availableBytes(parent) >= plan.requiredBytes + options.reserveBytes else {
            throw MigrationError.insufficientSpace
        }
        try options.fault?(.plan)

        let stageName = Bytes((Self.stagePrefix + UUID().uuidString).utf8)
        guard stageName.withCName({ mkdirat(parentFD, $0, 0o700) }) == 0 else { throw MigrationError.io("mkdirat", errno) }
        do {
            let stage = stageName.withCName { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard stage >= 0 else { throw MigrationError.io("openat", errno) }
            defer { close(stage) }
            try extract(plan, into: stage, expected: expected)
            try options.fault?(.verify)
            try Verifier(root: stage).check(plan.manifest)
            try SessionMigrator(stage: stage, options: options).run(&report)
            try options.fault?(.marker)
            let data = try JSONEncoder.sorted.encode(report)
            try writeFile(stage, Bytes(Self.marker.utf8), data, mode: 0o600)
            // fsync per file handed the data to the drive; one full sync flushes the drive cache for all of it.
            try fullSync(stage)
            try options.fault?(.switching)
            let renamed = stageName.withCName { from in targetName.withCName { renameat(parentFD, from, parentFD, $0) } }
            if renamed != 0 {
                if errno == ENOTEMPTY || errno == EEXIST || errno == ENOTDIR { throw MigrationError.targetExists }
                throw MigrationError.io("renameat", errno)
            }
        } catch {
            try? removeTree(parentFD, stageName)
            throw error
        }
        try options.fault?(.switched)
        try fullSync(parentFD)
        return report
    }

    /// Read-only pass: every entry is classified and every file hashed before anything is written.
    func makePlan(_ report: inout MigrationReport) throws -> Plan {
        let descriptor = try openArchive()
        defer { close(descriptor) }
        let reader = TarReader(descriptor: descriptor)
        var plan = Plan()
        var entries = 0
        while let entry = try reader.next() {
            entries += 1
            guard entries <= options.maxEntries else { throw MigrationError.archiveUnsafe("ENTRY_COUNT") }
            let step = try classify(entry, plan: plan)
            switch step {
            case .layoutVersion:
                guard plan.layoutVersion == nil, entry.kind == .file, entry.size <= 64 else { throw MigrationError.layoutInvalid }
                var bytes = Data()
                try reader.readBody { bytes.append($0) }
                plan.layoutVersion = Bytes(bytes)
            case .create(let node):
                var planned = node
                if case .file = node.kind {
                    var digest = StreamingDigest()
                    try reader.readBody { digest.update($0) }
                    planned = Planned(path: node.path, kind: .file(sha256: digest.hex(), size: entry.size), mode: node.mode)
                }
                try plan.add(planned)
                plan.steps.append(.create(planned))
                continue
            case .credential(let path): report.credentialsExcluded.append(path)
            case .special(let path): report.specialSkipped.append(path)
            case .cache: report.cacheEntriesExcluded += 1
            }
            plan.steps.append(step)
        }
        guard let version = plan.layoutVersion,
              String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              plan.manifest[Bytes("projects".utf8)]?.kind == .directory, plan.implicit.contains(Bytes("projects".utf8)) == false,
              plan.manifest[Bytes("home".utf8)]?.kind == .directory, plan.implicit.contains(Bytes("home".utf8)) == false
        else { throw MigrationError.layoutInvalid }
        for node in plan.manifest.values {
            switch node.kind {
            case .file(_, let size): report.files += 1; report.bytes += Int64(size)
            case .directory: report.directories += 1
            case .symlink: report.symlinks += 1
            case .hardlink: report.hardlinks += 1
            }
        }
        report.manifestSha256 = plan.manifestDigest
        return plan
    }

    /// Classifies one entry against the plan so far (hard links need their earlier target).
    func classify(_ entry: TarEntry, plan: Plan) throws -> Step {
        let parts = try Rules.components(entry.path)
        let display = parts.display
        if parts == [Bytes(".harness-layout-version".utf8)] { return .layoutVersion }
        if Rules.isCredential(parts) { return .credential(display) }
        if parts.starts(with: Rules.cache) { return .cache }
        let path = Rules.mapped(parts)
        switch entry.kind {
        case .special: return .special(display)
        case .directory:
            return .create(Planned(path: path, kind: .directory, mode: Rules.effectiveMode(entry.mode, directory: true)))
        case .file:
            return .create(Planned(path: path, kind: .file(sha256: "", size: entry.size), mode: Rules.effectiveMode(entry.mode, directory: false)))
        case .symlink:
            guard Rules.normalized(entry.link, from: Array(parts.dropLast())) != nil else { throw MigrationError.archiveUnsafe("LINK") }
            return .create(Planned(path: path, kind: .symlink(entry.link), mode: 0o755))
        case .hardlink:
            guard let source = Rules.normalized(entry.link, from: []), !source.isEmpty else { throw MigrationError.archiveUnsafe("LINK") }
            if Rules.isCredential(source) { return .credential(display) }
            if source.starts(with: Rules.cache) { return .cache }
            let mappedSource = Rules.mapped(source)
            guard let node = plan.manifest[mappedSource.joinedPath], case .file = node.kind else {
                throw MigrationError.archiveUnsafe("LINK_TARGET")
            }
            return .create(Planned(path: path, kind: .hardlink(mappedSource), mode: node.mode))
        }
    }

    /// Second pass: writes the planned tree into the stage. Each entry must classify exactly as planned and
    /// hash to the planned digest, and the archive must still hash to the sidecar: an archive replaced
    /// between the passes is `digestMismatch`.
    func extract(_ plan: Plan, into stage: Int32, expected: String) throws {
        let descriptor = try openArchive()
        defer { close(descriptor) }
        let reader = TarReader(descriptor: descriptor)
        var index = 0
        var created = Set<Bytes>()
        var directories = Set<Bytes>()
        func ensureParents(_ path: [Bytes]) throws {
            for depth in stride(from: 1, to: path.count, by: 1) {
                let parent = Array(path.prefix(depth))
                guard !created.contains(parent.joinedPath) else { continue }
                try makeDirectory(stage, parent)
                created.insert(parent.joinedPath); directories.insert(parent.joinedPath)
            }
        }
        while let entry = try reader.next() {
            guard index < plan.steps.count else { throw MigrationError.digestMismatch }
            let planned = plan.steps[index]
            index += 1
            let step = try classify(entry, plan: plan)
            guard case .create(let node) = planned else {
                guard step == planned else { throw MigrationError.digestMismatch }
                continue
            }
            guard case .create(let classified) = step, classified.path == node.path else { throw MigrationError.digestMismatch }
            try ensureParents(node.path)
            switch node.kind {
            case .directory:
                if !created.contains(node.path.joinedPath) { try makeDirectory(stage, node.path) }
                directories.insert(node.path.joinedPath)
            case .file(let sha256, _):
                let written = try writeStream(stage, node.path, mode: node.mode, reader: reader)
                guard written == sha256 else { throw MigrationError.digestMismatch }
            case .symlink(let link):
                let result = try withParent(stage, node.path) { directory, name in
                    link.withCName { target in name.withCName { symlinkat(target, directory, $0) } }
                }
                guard result == 0 else { throw MigrationError.io("symlinkat", errno) }
            case .hardlink(let source):
                let result = try withParent(stage, node.path) { directory, name in
                    source.joinedPath.withCName { from in name.withCName { linkat(stage, from, directory, $0, 0) } }
                }
                guard result == 0 else { throw MigrationError.io("linkat", errno) }
            }
            created.insert(node.path.joinedPath)
        }
        guard index == plan.steps.count, reader.digest.hex() == expected else { throw MigrationError.digestMismatch }
        // Final directory modes last, deepest first, so a read-only directory does not block its children.
        for key in directories.sorted(by: { $0.filter { $0 == 0x2F }.count > $1.filter { $0 == 0x2F }.count }) {
            guard let node = plan.manifest[key] else { continue }
            let directory = try openTree(stage, node.path)
            defer { close(directory) }
            guard fchmod(directory, mode_t(node.mode)) == 0 else { throw MigrationError.io("fchmod", errno) }
            try fsyncOrThrow(directory)
        }
    }

    func writeStream(_ stage: Int32, _ path: [Bytes], mode: UInt32, reader: TarReader) throws -> String {
        try withParent(stage, path) { directory, name in
            let file = name.withCName { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard file >= 0 else { throw MigrationError.io("openat", errno) }
            defer { close(file) }
            var digest = StreamingDigest()
            var faulted = false
            try reader.readBody { chunk in
                let half = faulted ? chunk.count : chunk.count / 2
                try writeAll(file, chunk.prefix(half))
                if !faulted { faulted = true; try options.fault?(.extract) }
                try writeAll(file, chunk.dropFirst(half))
                digest.update(chunk)
            }
            if !faulted { try options.fault?(.extract) }
            guard fchmod(file, mode_t(mode)) == 0 else { throw MigrationError.io("fchmod", errno) }
            try fsyncOrThrow(file)
            return digest.hex()
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension Plan {
    var manifestDigest: String {
        let lines = manifest.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { key -> String in
            let node = manifest[key]!
            let path = key.map { String(format: "%02x", $0) }.joined()
            switch node.kind {
            case .file(let sha, let size): return "f \(path) \(String(node.mode, radix: 8)) \(size) \(sha)"
            case .directory: return "d \(path) \(String(node.mode, radix: 8))"
            case .symlink(let link): return "l \(path) \(link.map { String(format: "%02x", $0) }.joined())"
            case .hardlink(let source): return "h \(path) \(source.joinedPath.map { String(format: "%02x", $0) }.joined())"
            }
        }
        return StreamingDigest.hex(Data(lines.joined(separator: "\n").utf8))
    }
}
