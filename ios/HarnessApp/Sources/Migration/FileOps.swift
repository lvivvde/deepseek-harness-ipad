import Darwin
import Foundation

extension Array where Element == UInt8 {
    func withCName<T>(_ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        var terminated = self; terminated.append(0)
        return try terminated.withUnsafeBufferPointer { buffer in
            try buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { try body($0) }
        }
    }
}

/// F_FULLFSYNC flushes the drive cache (plain fsync does not on Darwin); file systems without it fall
/// back to fsync. Same rule as the native workspace.
func fullSync(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    let code = errno
    guard code == ENOTSUP || code == EINVAL || code == ENOTTY else { throw MigrationError.io("F_FULLFSYNC", code) }
    try fsyncOrThrow(descriptor)
}

func fsyncOrThrow(_ descriptor: Int32) throws {
    guard fsync(descriptor) == 0 else { throw MigrationError.io("fsync", errno) }
}

func writeAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
            if written < 0 { if errno == EINTR { continue }; throw MigrationError.io("write", errno) }
            offset += written
        }
    }
}

func readAll(_ descriptor: Int32, _ body: (Data) throws -> Void) throws {
    var buffer = Data(count: 1 << 20)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
        if count < 0 { if errno == EINTR { continue }; throw MigrationError.io("read", errno) }
        if count == 0 { return }
        try body(buffer.prefix(count))
    }
}

/// Opens `path` below `root` one component at a time without following symlinks, so a planted link
/// can never redirect a write outside the stage.
func openTree(_ root: Int32, _ path: [Bytes]) throws -> Int32 {
    var current = dup(root)
    guard current >= 0 else { throw MigrationError.io("dup", errno) }
    for part in path {
        let next = part.withCName { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        let code = errno
        close(current)
        guard next >= 0 else { throw code == ELOOP || code == ENOTDIR ? MigrationError.archiveUnsafe("PATH") : MigrationError.io("openat", code) }
        current = next
    }
    return current
}

func withParent<T>(_ root: Int32, _ path: [Bytes], _ body: (Int32, Bytes) throws -> T) throws -> T {
    let directory = try openTree(root, Array(path.dropLast()))
    defer { close(directory) }
    return try body(directory, path.last!)
}

func makeDirectory(_ root: Int32, _ path: [Bytes]) throws {
    let result = try withParent(root, path) { directory, name in name.withCName { mkdirat(directory, $0, 0o700) } }
    guard result == 0 else { throw MigrationError.io("mkdirat", errno) }
}

/// Exclusive create, write, sync.
func writeFile(_ directory: Int32, _ name: Bytes, _ data: Data, mode: mode_t) throws {
    let file = name.withCName { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode) }
    guard file >= 0 else { throw MigrationError.io("openat", errno) }
    defer { close(file) }
    try writeAll(file, data)
    try fsyncOrThrow(file)
}

func readFile(_ directory: Int32, _ name: Bytes) throws -> Data {
    let file = name.withCName { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard file >= 0 else { throw MigrationError.io("openat", errno) }
    defer { close(file) }
    var data = Data()
    try readAll(file) { data.append($0) }
    return data
}

/// Entry names of a directory, without `.` and `..`.
func listDirectory(_ directory: Int32) throws -> [(name: Bytes, type: UInt8)] {
    let copy = dup(directory)
    guard copy >= 0, let stream = fdopendir(copy) else { throw MigrationError.io("fdopendir", errno) }
    defer { closedir(stream) }
    var names: [(Bytes, UInt8)] = []
    while let entry = readdir(stream) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
            Bytes(raw.prefix(Int(entry.pointee.d_namlen)))
        }
        if name == [0x2E] || name == [0x2E, 0x2E] { continue }
        names.append((name, entry.pointee.d_type))
    }
    return names
}

/// Removes a subtree of `directory` without following links; directories are made writable first so a
/// read-only directory from the archive cannot pin a stale stage.
func removeTree(_ directory: Int32, _ name: Bytes) throws {
    var info = stat()
    if name.withCName({ fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) != 0 {
        if errno == ENOENT { return }
        throw MigrationError.io("fstatat", errno)
    }
    if info.st_mode & S_IFMT == S_IFDIR {
        _ = name.withCName { fchmodat(directory, $0, 0o700, AT_SYMLINK_NOFOLLOW) }
        let child = name.withCName { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard child >= 0 else { throw MigrationError.io("openat", errno) }
        defer { close(child) }
        for entry in try listDirectory(child) { try removeTree(child, entry.name) }
        guard name.withCName({ unlinkat(directory, $0, AT_REMOVEDIR) }) == 0 else { throw MigrationError.io("unlinkat", errno) }
    } else {
        guard name.withCName({ unlinkat(directory, $0, 0) }) == 0 else { throw MigrationError.io("unlinkat", errno) }
    }
}

/// Walks the extracted stage on its own, from disk, and compares it with the plan: the same set of
/// paths, the same types and modes, every file's content digest, every symlink's target, and every hard
/// link sharing its source's inode. Anything else is `verifyFailed`.
struct Verifier {
    let root: Int32

    struct Seen {
        var kind: UInt16
        var mode: UInt32
        var sha256: String?
        var link: Bytes?
        var inode: UInt64
    }

    func check(_ manifest: [Bytes: Planned]) throws {
        var seen: [Bytes: Seen] = [:]
        try walk(root, prefix: [], into: &seen)
        guard Set(seen.keys) == Set(manifest.keys) else { throw MigrationError.verifyFailed }
        for (key, node) in manifest {
            let disk = seen[key]!
            switch node.kind {
            case .directory:
                guard disk.kind == S_IFDIR, disk.mode == node.mode else { throw MigrationError.verifyFailed }
            case .file(let sha, _):
                guard disk.kind == S_IFREG, disk.mode == node.mode, disk.sha256 == sha else { throw MigrationError.verifyFailed }
            case .symlink(let link):
                guard disk.kind == S_IFLNK, disk.link == link else { throw MigrationError.verifyFailed }
            case .hardlink(let source):
                guard disk.kind == S_IFREG, let original = seen[source.joinedPath], original.inode == disk.inode,
                      case .file(let sha, _) = manifest[source.joinedPath]?.kind, disk.sha256 == sha
                else { throw MigrationError.verifyFailed }
            }
        }
    }

    func walk(_ directory: Int32, prefix: Bytes, into seen: inout [Bytes: Seen]) throws {
        for entry in try listDirectory(directory) {
            let key = prefix.isEmpty ? entry.name : prefix + [0x2F] + entry.name
            var info = stat()
            guard entry.name.withCName({ fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw MigrationError.io("fstatat", errno)
            }
            var node = Seen(kind: info.st_mode & S_IFMT, mode: UInt32(info.st_mode & 0o777), sha256: nil, link: nil, inode: info.st_ino)
            switch node.kind {
            case S_IFDIR:
                let child = entry.name.withCName { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard child >= 0 else { throw MigrationError.io("openat", errno) }
                defer { close(child) }
                try walk(child, prefix: key, into: &seen)
            case S_IFREG:
                let file = entry.name.withCName { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
                guard file >= 0 else { throw MigrationError.io("openat", errno) }
                defer { close(file) }
                var digest = StreamingDigest()
                try readAll(file) { digest.update($0) }
                node.sha256 = digest.hex()
            case S_IFLNK:
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = entry.name.withCName { readlinkat(directory, $0, &buffer, buffer.count - 1) }
                guard count >= 0 else { throw MigrationError.io("readlinkat", errno) }
                node.link = buffer.prefix(count).map { UInt8(bitPattern: $0) }
            default:
                throw MigrationError.verifyFailed
            }
            seen[key] = node
        }
    }
}
