import CryptoKit
import Darwin
import Foundation

func withCName<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
    var terminated = bytes; terminated.append(0)
    return try terminated.withUnsafeBufferPointer { buffer in
        try buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { try body($0) }
    }
}

/// Durable on Darwin storage: plain fsync hands data to the drive but does not flush its cache,
/// so a power loss can still drop or reorder it. F_FULLFSYNC asks the drive to flush; it fails on
/// file systems that do not support it, and then fsync is the best remaining guarantee.
func fullSync(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    if fsync(descriptor) != 0 { throw WorkspaceError.io("fsync", errno) }
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

func openDirectory(_ path: String) throws -> Int32 {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw WorkspaceError.io("open", errno) }
    return descriptor
}

/// Atomically replace `name` in `directory`: O_EXCL temporary `temporary`, full sync, rename,
/// directory sync. An interruption at any stage leaves the previous `name` intact.
func atomicReplace(directory: Int32, name: [UInt8], temporary: [UInt8], data: Data, mode: mode_t?,
                   site: FaultPoint.Site, fault: FaultHook?) throws {
    try fault?(FaultPoint(site, .beforeTemp))
    let descriptor = withCName(temporary) { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644) }
    guard descriptor >= 0 else { throw WorkspaceError.io("openat", errno) }
    do {
        let half = data.count / 2
        try writeAll(descriptor, data.prefix(half))
        try fault?(FaultPoint(site, .halfWritten))
        try writeAll(descriptor, data.dropFirst(half))
        if let mode, fchmod(descriptor, mode) != 0 { throw WorkspaceError.io("fchmod", errno) }
        try fault?(FaultPoint(site, .beforeSync))
        try fullSync(descriptor)
        close(descriptor)
        try fault?(FaultPoint(site, .beforeRename))
    } catch {
        close(descriptor); _ = withCName(temporary) { unlinkat(directory, $0, 0) }; throw error
    }
    let renamed = withCName(temporary) { from in withCName(name) { to in renameat(directory, from, directory, to) } }
    guard renamed == 0 else {
        let code = errno; _ = withCName(temporary) { unlinkat(directory, $0, 0) }; throw WorkspaceError.io("renameat", code)
    }
    try fullSync(directory)
    try fault?(FaultPoint(site, .afterRename))
}

func temporaryName(_ suffix: String = UUID().uuidString.lowercased()) -> [UInt8] { WorkspaceFiles.temporaryPrefix + Array(suffix.utf8) }

/// POSIX view of the native workspace. Every walk is relative to directory descriptors with
/// O_NOFOLLOW, so a symlinked parent cannot redirect a native write outside the workspace, and
/// special files (FIFO, socket, device) are fingerprinted from lstat without being opened.
public final class WorkspaceFiles {
    public static let identity = Array(".dsh-identity".utf8)
    public static let temporaryPrefix = Array(".dsh-tmp-".utf8)
    public let root: String

    public init(root: String) { self.root = root }

    /// Opens the parent directory of `path` and returns it with the leaf name. Returns nil when a
    /// parent is missing and `create` is false. A symlinked or non-directory parent is refused.
    func openParent(_ path: RelativePath, create: Bool) throws -> (Int32, [UInt8])? {
        var directory = try openDirectory(root)
        let components = path.components
        for component in components.dropLast() {
            var next = withCName(component) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if next < 0 && errno == ENOENT && create {
                if withCName(component, { mkdirat(directory, $0, 0o755) }) != 0 {
                    if errno != EEXIST { let code = errno; close(directory); throw WorkspaceError.io("mkdirat", code) }
                } else {
                    do { try fullSync(directory) } catch { close(directory); throw error }
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
        return fingerprint(directory: directory, name: name)
    }

    func fingerprint(directory: Int32, name: [UInt8]) -> String? {
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
            return Self.fileFingerprint(digest: hex(hasher.finalize()), mode: opened.st_mode & 0o777)
        case S_IFDIR: return "D"
        case S_IFIFO: return "S:fifo:\(mode)"
        case S_IFSOCK: return "S:socket:\(mode)"
        case S_IFCHR: return "S:char:\(mode)"
        case S_IFBLK: return "S:block:\(mode)"
        default: return "S:other:\(mode)"
        }
    }

    static func fileFingerprint(digest: String, mode: mode_t) -> String { "F:" + digest + ":" + String(mode, radix: 8) }
    static func mode(of fingerprint: String?) -> mode_t? {
        guard let fingerprint, fingerprint.hasPrefix("F:"), let last = fingerprint.split(separator: ":").last else { return nil }
        return mode_t(last, radix: 8)
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
    /// keyed by exact bytes. Empty directories and the store's own temporaries are not tracked.
    public func scan() throws -> [RelativePath: String] {
        var found: [RelativePath: String] = [:], temporaries: [RelativePath] = []
        let directory = try openDirectory(root)
        defer { close(directory) }
        try walk(directory, RelativePath(bytes: []), &found, &temporaries)
        return found
    }

    /// Store temporaries left anywhere in the workspace by an interrupted write.
    public func temporaries() throws -> [RelativePath] {
        var found: [RelativePath: String] = [:], temporaries: [RelativePath] = []
        let directory = try openDirectory(root)
        defer { close(directory) }
        try walk(directory, RelativePath(bytes: []), &found, &temporaries)
        return temporaries.sorted()
    }

    private func walk(_ directory: Int32, _ prefix: RelativePath, _ found: inout [RelativePath: String],
                      _ temporaries: inout [RelativePath]) throws {
        for name in try names(directory) {
            let path = prefix.appending(name)
            if name.starts(with: Self.temporaryPrefix) { temporaries.append(path); continue }
            if prefix.bytes.isEmpty && name == Self.identity { continue }
            guard let fingerprint = fingerprint(directory: directory, name: name) else { continue }
            if fingerprint != "D" { found[path] = fingerprint; continue }
            let child = withCName(name) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if child < 0 { found[path] = "U:\(errno)"; continue }
            defer { close(child) }
            try walk(child, path, &found, &temporaries)
        }
    }

    /// Bounded regular-file read without following a leaf or parent symlink.
    public func readData(_ path: RelativePath, limit: Int = 8 << 20) throws -> Data {
        guard let (directory, name) = try openParent(path, create: false) else { throw WorkspaceError.io("read", ENOENT) }
        defer { close(directory) }
        let descriptor = withCName(name) { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw WorkspaceError.io("openat", errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceError.pathRefused("NOT_REGULAR") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw WorkspaceError.io("read", errno) }
            if count == 0 { return data }
            guard data.count + count <= limit else { throw WorkspaceError.pathRefused("READ_TOO_LARGE") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// Atomic replace of a regular file through the caller-chosen temporary name.
    func write(_ path: RelativePath, _ data: Data, mode: mode_t?, temporary: [UInt8], fault: FaultHook?) throws {
        guard let (directory, name) = try openParent(path, create: true) else { throw WorkspaceError.io("openParent", ENOENT) }
        defer { close(directory) }
        try atomicReplace(directory: directory, name: name, temporary: temporary, data: data, mode: mode,
                          site: .workspace, fault: fault)
    }

    /// Moves a store temporary out of the workspace (same volume) so Linux never sees it.
    func moveOut(_ path: RelativePath, to destination: String) throws {
        guard let (directory, name) = try openParent(path, create: false) else { return }
        defer { close(directory) }
        let moved = withCName(name) { from in renameat(directory, from, AT_FDCWD, destination) }
        if moved != 0 && errno != ENOENT { throw WorkspaceError.io("renameat", errno) }
        try fullSync(directory)
    }
}
