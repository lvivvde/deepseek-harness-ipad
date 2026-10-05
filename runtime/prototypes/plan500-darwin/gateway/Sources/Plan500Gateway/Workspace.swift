import CryptoKit
import Darwin
import Foundation

/// A workspace-relative path compared byte for byte. Swift `String` equality is canonical
/// equivalence, so NFC and NFD spellings of one name would collide as `String` keys; a Linux
/// guest can create both, and the gateway must keep them apart.
public struct RelativePath: Hashable, Comparable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(_ string: String) { bytes = Array(string.utf8) }

    public var components: [[UInt8]] { bytes.split(separator: 0x2F, omittingEmptySubsequences: false).map(Array.init) }
    public func appending(_ name: [UInt8]) -> RelativePath { RelativePath(bytes: bytes.isEmpty ? name : bytes + [0x2F] + name) }
    public static func < (a: RelativePath, b: RelativePath) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }

    /// Exact UTF-8 text when the bytes are valid UTF-8 (no BOM stripping, no normalization).
    public var text: String? {
        let decoded = String(decoding: bytes, as: UTF8.self)
        return Array(decoded.utf8) == bytes ? decoded : nil
    }
    public var description: String { text ?? "b64:" + Data(bytes).base64EncodedString() }
    public var json: Any { text.map { $0 as Any } ?? ["b64": Data(bytes).base64EncodedString()] }

    public init(json: Any) throws {
        if let text = json as? String { self.init(text); return }
        guard let object = json as? [String: Any], let encoded = object["b64"] as? String,
              let data = Data(base64Encoded: encoded) else { throw WorkspaceError.pathRefused("PATH_ENCODING") }
        self.init(bytes: Array(data))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self.init(text); return }
        let object = try container.decode([String: String].self)
        guard let encoded = object["b64"], let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "path encoding")
        }
        self.init(bytes: Array(data))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let text { try container.encode(text) } else { try container.encode(["b64": Data(bytes).base64EncodedString()]) }
    }

    /// Native writes accept only plain descendants: no absolute, empty, `.`, `..` or NUL components,
    /// and nothing the gateway reserves for itself.
    public func validate() throws {
        guard !bytes.isEmpty, bytes.first != 0x2F, !bytes.contains(0) else { throw WorkspaceError.pathRefused("PATH_REFUSED") }
        for component in components where component.isEmpty || component == [0x2E] || component == [0x2E, 0x2E] {
            throw WorkspaceError.pathRefused("PATH_REFUSED")
        }
        if bytes == Workspace.identity || components.last!.starts(with: Workspace.temporaryPrefix) {
            throw WorkspaceError.pathRefused("PATH_RESERVED")
        }
    }
}

public enum WorkspaceError: Error, CustomStringConvertible {
    case pathRefused(String)
    case io(String, Int32)
    public var description: String {
        switch self {
        case .pathRefused(let reason): return reason
        case .io(let call, let code): return "\(call): \(String(cString: strerror(code)))"
        }
    }
}

func withCName<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
    var terminated = bytes; terminated.append(0)
    return try terminated.withUnsafeBufferPointer { buffer in
        try buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { try body($0) }
    }
}

/// Durable on Darwin storage: plain fsync does not flush the drive cache.
func fullSync(_ descriptor: Int32) {
    if fcntl(descriptor, F_FULLFSYNC) != 0 { fsync(descriptor) }
}

func writeAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
            if written < 0 { if errno == EINTR { continue }; throw WorkspaceError.io("write", errno) }
            offset += written
        }
    }
}

/// Atomically replace `name` in the directory `directory`: O_EXCL temporary, full sync, rename, directory sync.
func atomicReplace(directory: Int32, name: [UInt8], data: Data, mode: mode_t?) throws {
    let temporary = Workspace.temporaryPrefix + Array(UUID().uuidString.utf8)
    let descriptor = withCName(temporary) { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644) }
    guard descriptor >= 0 else { throw WorkspaceError.io("openat", errno) }
    do {
        try writeAll(descriptor, data)
        if let mode, fchmod(descriptor, mode) != 0 { throw WorkspaceError.io("fchmod", errno) }
        fullSync(descriptor)
        close(descriptor)
    } catch {
        close(descriptor); _ = withCName(temporary) { unlinkat(directory, $0, 0) }; throw error
    }
    let renamed = withCName(temporary) { from in withCName(name) { to in renameat(directory, from, directory, to) } }
    guard renamed == 0 else {
        let code = errno; _ = withCName(temporary) { unlinkat(directory, $0, 0) }; throw WorkspaceError.io("renameat", code)
    }
    fullSync(directory)
}

func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }

/// POSIX view of the host side of the 9P share. Every walk is relative to directory descriptors
/// with O_NOFOLLOW, so a symlinked parent cannot redirect a native write outside the workspace,
/// and special files (FIFO, socket, device) are fingerprinted from lstat without being opened.
public final class Workspace {
    public static let identity = Array(".plan500-identity".utf8)
    public static let temporaryPrefix = Array(".plan500-tmp-".utf8)
    public let root: String

    public init(root: String) { self.root = root }

    func openRoot() throws -> Int32 {
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.io("open", errno) }
        return descriptor
    }

    /// Opens the parent directory of `path` and returns it with the leaf name. Returns nil when a
    /// parent is missing and `create` is false. A symlinked or non-directory parent is refused.
    func openParent(_ path: RelativePath, create: Bool) throws -> (Int32, [UInt8])? {
        try path.validate()
        var directory = try openRoot()
        let components = path.components
        for component in components.dropLast() {
            var next = withCName(component) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if next < 0 && errno == ENOENT && create {
                if withCName(component, { mkdirat(directory, $0, 0o755) }) != 0 && errno != EEXIST {
                    let code = errno; close(directory); throw WorkspaceError.io("mkdirat", code)
                }
                next = withCName(component) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            }
            let code = errno
            close(directory)
            if next < 0 {
                if code == ENOENT { return nil }
                if code == ELOOP || code == ENOTDIR { throw WorkspaceError.pathRefused("PATH_REFUSED") }
                throw WorkspaceError.io("openat", code)
            }
            directory = next
        }
        return (directory, components.last!)
    }

    /// Fingerprint of one entry, or nil when it does not exist.
    public func fingerprint(_ path: RelativePath) throws -> String? {
        guard let (directory, name) = try openParent(path, create: false) else { return nil }
        defer { close(directory) }
        return try fingerprint(directory: directory, name: name)
    }

    func fingerprint(directory: Int32, name: [UInt8]) throws -> String? {
        var status = stat()
        if withCName(name, { fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW) }) != 0 {
            if errno == ENOENT { return nil }
            return "U:\(errno)"
        }
        let mode = String(status.st_mode & 0o777, radix: 8)
        switch status.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = withCName(name) { cName in
                buffer.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.withMemoryRebound(to: CChar.self, capacity: out.count) { readlinkat(directory, cName, $0, out.count) }
                }
            }
            return length < 0 ? "U:\(errno)" : "L:" + hex(buffer[0..<length])
        case S_IFREG:
            let descriptor = withCName(name) { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            if descriptor < 0 { return errno == ENOENT ? nil : "U:\(errno)" }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { return "S:raced:\(mode)" }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
                if count < 0 { if errno == EINTR { continue }; return "U:\(errno)" }
                if count == 0 { break }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            }
            return "F:" + hex(hasher.finalize()) + ":" + String(opened.st_mode & 0o777, radix: 8)
        case S_IFDIR: return "D"
        case S_IFIFO: return "S:fifo:\(mode)"
        case S_IFSOCK: return "S:socket:\(mode)"
        case S_IFCHR: return "S:char:\(mode)"
        case S_IFBLK: return "S:block:\(mode)"
        default: return "S:other:\(mode)"
        }
    }

    func names(_ directory: Int32) throws -> [[UInt8]] {
        let copy = dup(directory)
        guard copy >= 0 else { throw WorkspaceError.io("dup", errno) }
        guard let stream = fdopendir(copy) else { let code = errno; close(copy); throw WorkspaceError.io("fdopendir", code) }
        defer { closedir(stream) }
        var found: [[UInt8]] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)) }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            found.append(name)
        }
        return found
    }

    /// Every non-directory entry (files, symlinks including symlinked directories, special files),
    /// keyed by exact bytes. Empty directories are not tracked, matching the Python stand-in.
    public func scan() throws -> [RelativePath: String] {
        var found: [RelativePath: String] = [:]
        let directory = try openRoot()
        defer { close(directory) }
        try walk(directory, RelativePath(bytes: []), &found)
        return found
    }

    func walk(_ directory: Int32, _ prefix: RelativePath, _ found: inout [RelativePath: String]) throws {
        for name in try names(directory) {
            if name.starts(with: Workspace.temporaryPrefix) || (prefix.bytes.isEmpty && name == Workspace.identity) { continue }
            let path = prefix.appending(name)
            guard let fingerprint = try fingerprint(directory: directory, name: name) else { continue }
            if fingerprint != "D" { found[path] = fingerprint; continue }
            let child = withCName(name) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if child < 0 { found[path] = "U:\(errno)"; continue }
            defer { close(child) }
            try walk(child, path, &found)
        }
    }

    /// Atomic replace of a regular file. An existing regular file keeps its mode.
    public func write(_ path: RelativePath, _ data: Data, mode: mode_t?) throws {
        guard let (directory, name) = try openParent(path, create: true) else { throw WorkspaceError.io("openParent", ENOENT) }
        defer { close(directory) }
        try atomicReplace(directory: directory, name: name, data: data, mode: mode)
    }
}
