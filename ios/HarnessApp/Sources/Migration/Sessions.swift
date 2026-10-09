import Darwin
import Foundation

/// Decodes one compressed official session log. The old app wrote `.jsonl.zstd`; the Worker store is
/// plaintext-only and refuses a root that still holds the other encoding, so every log is decoded here.
public protocol SessionLogCodec {
    func decompress(_ data: Data) throws -> Data
}

/// zstd through the system or bundled `libzstd` loaded at run time (the research app already ships
/// `zstd.1.framework`; macOS uses Homebrew's). Not finding it is `sessionDecoderUnavailable`.
public final class DynamicZstd: SessionLogCodec {
    private typealias Create = @convention(c) () -> OpaquePointer?
    private typealias Free = @convention(c) (OpaquePointer?) -> Int
    private typealias OutSize = @convention(c) () -> Int
    private typealias Stream = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int
    private typealias IsError = @convention(c) (Int) -> UInt32

    private let create: Create, free: Free, outSize: OutSize, stream: Stream, isError: IsError

    public static let defaultLibraries = [
        "@executable_path/Frameworks/zstd.1.framework/zstd.1",
        "/opt/homebrew/lib/libzstd.1.dylib", "/usr/local/lib/libzstd.1.dylib"
    ]

    public init(libraries: [String] = DynamicZstd.defaultLibraries) throws {
        guard let handle = libraries.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first,
              let create = dlsym(handle, "ZSTD_createDStream"), let free = dlsym(handle, "ZSTD_freeDStream"),
              let outSize = dlsym(handle, "ZSTD_DStreamOutSize"), let stream = dlsym(handle, "ZSTD_decompressStream"),
              let isError = dlsym(handle, "ZSTD_isError") else { throw MigrationError.sessionDecoderUnavailable }
        self.create = unsafeBitCast(create, to: Create.self)
        self.free = unsafeBitCast(free, to: Free.self)
        self.outSize = unsafeBitCast(outSize, to: OutSize.self)
        self.stream = unsafeBitCast(stream, to: Stream.self)
        self.isError = unsafeBitCast(isError, to: IsError.self)
    }

    /// Decodes every frame; a truncated or corrupt frame is `sessionInvalid`.
    public func decompress(_ data: Data) throws -> Data {
        guard let context = create() else { throw MigrationError.sessionInvalid }
        defer { _ = free(context) }
        let capacity = outSize()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        // ZSTD_inBuffer and ZSTD_outBuffer are both { pointer, size_t size, size_t pos }.
        let input = UnsafeMutablePointer<Int>.allocate(capacity: 3), output = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        defer { buffer.deallocate(); input.deallocate(); output.deallocate() }
        var result = Data()
        var hint = 0
        try data.withUnsafeBytes { source in
            input[0] = Int(bitPattern: source.baseAddress); input[1] = source.count; input[2] = 0
            while true {
                output[0] = Int(bitPattern: buffer); output[1] = capacity; output[2] = 0
                hint = stream(context, UnsafeMutableRawPointer(output), UnsafeMutableRawPointer(input))
                guard isError(hint) == 0 else { throw MigrationError.sessionInvalid }
                result.append(buffer.assumingMemoryBound(to: UInt8.self), count: output[2])
                if input[2] == input[1] && output[2] < capacity { break }
            }
        }
        guard hint == 0 else { throw MigrationError.sessionInvalid }
        return result
    }
}

/// Ports of the official `dsh-session-persistence-jsonl` path rules (UTF-16 code units, as in JS).
public enum SessionPaths {
    static func safe(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x5F, 0x2D: return true
        default: return false
        }
    }

    static func escape(_ unit: UInt16) -> String { "~" + String(format: "%04X", unit) }

    public static func encodeSegment(_ raw: String) -> String {
        if raw == "." { return "~002E" }
        if raw == ".." { return "~002E~002E" }
        return raw.utf16.map { safe($0) ? String(UnicodeScalar(UInt8($0))) : escape($0) }.joined()
    }

    public static func projectKey(_ cwd: String) -> String {
        var readable = "", separatorRun = false
        for unit in cwd.utf16 {
            if unit == 0x2F || unit == 0x5C || unit == 0x3A {
                if !separatorRun { readable += "-" }
                separatorRun = true
            } else {
                readable += safe(unit) ? String(UnicodeScalar(UInt8(unit))) : escape(unit)
                separatorRun = false
            }
        }
        let trimmed = String(readable.drop(while: { $0 == "-" }))
        return "--" + String((trimmed.isEmpty ? "root" : trimmed).prefix(251)) + "--"
    }

    /// `session.jsonl` (generation 0) or `session.v<N>.jsonl`, optionally `.zstd`.
    public static func generation(_ name: String) -> (version: Int, compressed: Bool)? {
        var stem = name, compressed = false
        if stem.hasSuffix(".zstd") { stem.removeLast(5); compressed = true }
        guard stem.hasSuffix(".jsonl") else { return nil }
        stem.removeLast(6)
        if stem == "session" { return (0, compressed) }
        guard stem.hasPrefix("session.v") else { return nil }
        let digits = stem.dropFirst(9)
        guard let first = digits.first, first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(digits) else { return nil }
        return (version, compressed)
    }
}

/// Converts the official session store inside the verified stage, before the switch. Each session
/// directory `sessions/<projectKey(cwd)>/<encodeSegment(id)>/` keeps its id and other files; its logs are
/// decoded to plaintext, and a cwd under the old project root is rewritten to the new one, which moves the
/// directory under the new project key (the official loader refuses a log whose cwd and path disagree).
/// Every rewritten log is read back: the header must equal the old one apart from `cwd`, and every byte
/// after it must be unchanged. Older format generations stay as they are; the official store migrates
/// them when the Worker opens the session.
struct SessionMigrator {
    let stage: Int32
    let options: MigrationOptions

    struct Log { let name: Bytes; let version: Int; let compressed: Bool; let header: [String: Any]; let rest: Data }

    func run(_ report: inout MigrationReport) throws {
        let sessionsPath = [Bytes("home".utf8), Bytes("sessions".utf8)]
        let sessions: Int32
        do { sessions = try openTree(stage, sessionsPath) } catch MigrationError.io(_, ENOENT) { return }
        defer { close(sessions) }
        // Listed up front: a converted session can move into a project directory not yet visited.
        var pairs: [(project: Bytes, session: Bytes)] = []
        let projects = try listDirectory(sessions).filter { $0.type == DT_DIR }.map(\.name)
        for project in projects {
            let projectFD = try openTree(sessions, [project])
            defer { close(projectFD) }
            pairs += try listDirectory(projectFD).filter { $0.type == DT_DIR }.map { (project, $0.name) }
        }
        for (project, session) in pairs {
            try options.fault?(.sessions)
            let projectFD = try openTree(sessions, [project])
            defer { close(projectFD) }
            try convert(sessions: sessions, project: project, projectFD: projectFD, session: session, report: &report)
        }
        for project in projects {
            let projectFD = try openTree(sessions, [project])
            let empty = try listDirectory(projectFD).isEmpty
            close(projectFD)
            if empty, project.withCName({ unlinkat(sessions, $0, AT_REMOVEDIR) }) != 0 { throw MigrationError.io("unlinkat", errno) }
        }
        try fsyncOrThrow(sessions)
    }

    func convert(sessions: Int32, project: Bytes, projectFD: Int32, session: Bytes, report: inout MigrationReport) throws {
        let directory = try openTree(projectFD, [session])
        defer { close(directory) }
        var logs: [Log] = []
        for entry in try listDirectory(directory) where entry.type == DT_REG {
            guard let generation = SessionPaths.generation(String(decoding: entry.name, as: UTF8.self)) else { continue }
            var data = try readFile(directory, entry.name)
            if generation.compressed {
                guard let codec = options.codec else { throw MigrationError.sessionDecoderUnavailable }
                data = try codec.decompress(data)
            }
            let split = data.firstIndex(of: 0x0A) ?? data.endIndex
            guard let header = try? JSONSerialization.jsonObject(with: data[..<split]) as? [String: Any],
                  header["type"] as? String == "session", let id = header["id"] as? String,
                  Bytes(SessionPaths.encodeSegment(id).utf8) == session else { throw MigrationError.sessionInvalid }
            let cwd = header["cwd"] as? String
            let key = cwd.map(SessionPaths.projectKey) ?? "_no-cwd"
            guard Bytes(key.utf8) == project else { throw MigrationError.sessionInvalid }
            logs.append(Log(name: entry.name, version: generation.version, compressed: generation.compressed,
                            header: header, rest: Data(data[split...])))
        }
        guard !logs.isEmpty else { return }
        let cwds = Set(logs.map { $0.header["cwd"] as? String ?? "\u{0}" })
        guard cwds.count == 1 else { throw MigrationError.sessionInvalid }
        let names = Set(logs.map { $0.version }).count
        guard names == logs.count else { throw MigrationError.sessionInvalid }  // Both encodings of one generation.
        report.sessions += 1

        let oldCwd = logs[0].header["cwd"] as? String
        let newCwd = oldCwd.flatMap(rewritten)
        if newCwd == nil { report.sessionsOutsideProjects += 1 }

        for log in logs where log.compressed || newCwd != nil {
            var header = log.header
            if let newCwd { header["cwd"] = newCwd }
            var data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(log.rest)
            let plain = log.compressed ? Bytes(log.name.dropLast(5)) : log.name
            let temporary = Bytes(".migration-".utf8) + plain
            try writeFile(directory, temporary, data, mode: 0o600)
            guard temporary.withCName({ from in plain.withCName { renameat(directory, from, directory, $0) } }) == 0 else {
                throw MigrationError.io("renameat", errno)
            }
            if log.compressed {
                guard log.name.withCName({ unlinkat(directory, $0, 0) }) == 0 else { throw MigrationError.io("unlinkat", errno) }
                report.sessionsDecompressed += 1
            }
            // Read back: only `cwd` may differ, and nothing after the header.
            let back = try readFile(directory, plain)
            let split = back.firstIndex(of: 0x0A) ?? back.endIndex
            guard let parsed = try? JSONSerialization.jsonObject(with: back[..<split]) as? NSDictionary,
                  parsed.isEqual(to: header), back[split...] == log.rest else { throw MigrationError.sessionInvalid }
        }
        try fsyncOrThrow(directory)

        guard let newCwd else { return }
        let newKey = Bytes(SessionPaths.projectKey(newCwd).utf8)
        guard newKey != project else { return }
        var info = stat()
        if newKey.withCName({ fstatat(sessions, $0, &info, AT_SYMLINK_NOFOLLOW) }) != 0 {
            guard errno == ENOENT, newKey.withCName({ mkdirat(sessions, $0, 0o755) }) == 0 else { throw MigrationError.io("mkdirat", errno) }
        }
        let target = try openTree(sessions, [newKey])
        defer { close(target) }
        guard session.withCName({ from in session.withCName { renameat(projectFD, from, target, $0) } }) == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY { throw MigrationError.sessionInvalid }
            throw MigrationError.io("renameat", errno)
        }
        try fsyncOrThrow(target)
        try fsyncOrThrow(projectFD)
        report.sessionsMoved += 1
    }

    /// `/root/projects/<name>[/…]` → `/dsh/workspace/<name>[/…]`; nil for any other cwd.
    func rewritten(_ cwd: String) -> String? {
        let prefix = options.oldProjectsRoot + "/"
        guard cwd.hasPrefix(prefix), !cwd.dropFirst(prefix.count).isEmpty,
              !cwd.dropFirst(prefix.count).hasPrefix("/") else { return nil }
        return options.newProjectsRoot + "/" + cwd.dropFirst(prefix.count)
    }
}
