import Darwin
import Foundation
import NativeWorkspace

/// A refusal with a fixed code. File codes are the dsh-fs `FsErrorCode` vocabulary; the
/// `WORKSPACE_*` codes are the gateway's own (a Linux command holds the write lease).
public struct ToolError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let detail: String
    public init(_ code: String, _ detail: String = "") { self.code = code; self.detail = detail }
    public var description: String { detail.isEmpty ? code : code + ": " + detail }
}

func withCName<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
    try (bytes + [0]).withUnsafeBufferPointer { buffer in
        try buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { try body($0) }
    }
}

/// The project as the Worker and Linux see it, `/dsh/workspace/<name>`, mapped onto the native
/// directory. Every lookup walks from the root with `O_NOFOLLOW`; symlinks are resolved here, by
/// hand, and only while they stay inside the workspace.
struct Mount {
    static let maximumHops = 40
    let processRoot: [UInt8]
    let directory: String

    /// Path components below the mount, or nil for a path outside it. `.` and `..` are kept: they
    /// are resolved against the real tree, never lexically.
    func components(_ processPath: String) -> [[UInt8]]? {
        let bytes = Array(processPath.utf8)
        guard bytes.starts(with: processRoot) else { return nil }
        let rest = bytes.dropFirst(processRoot.count)
        guard rest.isEmpty || rest.first == 0x2F else { return nil }
        return rest.split(separator: 0x2F, omittingEmptySubsequences: true).map(Array.init)
    }

    func processPath(_ components: [[UInt8]]) -> String {
        let bytes = components.reduce(processRoot) { $0 + [0x2F] + $1 }
        return String(decoding: bytes, as: UTF8.self)
    }

    func relative(_ components: [[UInt8]]) -> RelativePath { RelativePath(bytes: Array(components.joined(separator: [0x2F]))) }

    enum Resolution: Equatable {
        /// Every component exists; none is a symlink (except the leaf when not followed).
        case found([[UInt8]])
        /// `existing` exists and is a directory; `missing` does not exist below it.
        case missing(existing: [[UInt8]], missing: [[UInt8]])
    }

    /// Canonical components of `processPath`, following symlinks that stay inside the workspace.
    func resolve(_ processPath: String, followLeaf: Bool) throws -> Resolution {
        guard let requested = components(processPath) else { throw ToolError("FS_SANDBOX_DENIED", "outside the workspace") }
        var resolved: [[UInt8]] = [], pending = requested[...], hops = 0
        while let component = pending.first {
            pending = pending.dropFirst()
            if component == [0x2E] { continue }
            if component == [0x2E, 0x2E] {
                guard !resolved.isEmpty else { throw ToolError("FS_SANDBOX_DENIED", "outside the workspace") }
                resolved.removeLast(); continue
            }
            let isLeaf = !pending.contains { $0 != [0x2E] }
            guard let info = try lstat(resolved + [component]) else {
                return .missing(existing: resolved, missing: [component] + pending.filter { $0 != [0x2E] })
            }
            switch info.st_mode & S_IFMT {
            case S_IFLNK where !isLeaf || followLeaf:
                hops += 1
                guard hops <= Self.maximumHops else { throw ToolError("FS_IO_ERROR", "too many levels of symbolic links") }
                let target = try readlink(resolved + [component])
                if target.first == 0x2F {
                    guard let inside = components(String(decoding: target, as: UTF8.self)) else {
                        throw ToolError("FS_SANDBOX_DENIED", "symlink leaves the workspace")
                    }
                    resolved = []; pending = (inside + pending)[...]
                } else {
                    pending = (target.split(separator: 0x2F).map(Array.init) + pending)[...]
                }
            case S_IFDIR:
                resolved.append(component)
            default:
                guard isLeaf else { throw ToolError("FS_NOT_FOUND", "a parent path segment is not a directory") }
                resolved.append(component)
            }
        }
        return .found(resolved)
    }

    /// `lstat` of a path whose parents are real directories, or nil when it does not exist.
    func lstat(_ components: [[UInt8]]) throws -> stat? {
        guard let leaf = components.last else {
            var info = stat()
            guard Darwin.lstat(directory, &info) == 0 else { throw ToolError("FS_IO_ERROR", "workspace root: \(errno)") }
            return info
        }
        let parent = try openDirectory(components.dropLast())
        defer { close(parent) }
        var info = stat()
        if withCName(leaf, { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }) != 0 {
            if errno == ENOENT { return nil }
            if errno == ENOTDIR { throw ToolError("FS_NOT_FOUND", "a parent path segment is not a directory") }
            throw ToolError(errno == EACCES ? "FS_PERMISSION_DENIED" : "FS_IO_ERROR", "fstatat: \(errno)")
        }
        return info
    }

    func readlink(_ components: [[UInt8]]) throws -> [UInt8] {
        let parent = try openDirectory(components.dropLast())
        defer { close(parent) }
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = withCName(components.last!) { name in
            buffer.withUnsafeMutableBufferPointer { out in
                out.baseAddress!.withMemoryRebound(to: CChar.self, capacity: out.count) { readlinkat(parent, name, $0, out.count) }
            }
        }
        guard length >= 0 else { throw ToolError("FS_IO_ERROR", "readlinkat: \(errno)") }
        return Array(buffer[0..<length])
    }

    /// Opens a directory that must be reachable without following any symlink.
    func openDirectory<C: Collection>(_ components: C) throws -> Int32 where C.Element == [UInt8] {
        var current = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw ToolError("FS_IO_ERROR", "open workspace: \(errno)") }
        for component in components {
            let next = withCName(component) { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            let code = errno
            close(current)
            guard next >= 0 else {
                switch code {
                case ENOENT, ENOTDIR, ELOOP: throw ToolError("FS_NOT_FOUND", "a parent path segment is not a directory")
                case EACCES: throw ToolError("FS_PERMISSION_DENIED", "openat")
                default: throw ToolError("FS_IO_ERROR", "openat: \(code)")
                }
            }
            current = next
        }
        return current
    }

    func names<C: Collection>(_ components: C) throws -> [[UInt8]] where C.Element == [UInt8] {
        let descriptor = try openDirectory(components)
        guard let stream = fdopendir(descriptor) else { let code = errno; close(descriptor); throw ToolError("FS_IO_ERROR", "fdopendir: \(code)") }
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

    /// Up to `length` bytes at `offset` of a regular file reached without following symlinks.
    func readRange(_ components: [[UInt8]], offset: Int, length: Int) throws -> Data {
        let parent = try openDirectory(components.dropLast())
        defer { close(parent) }
        let descriptor = withCName(components.last!) { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ToolError(errno == ENOENT ? "FS_NOT_FOUND" : "FS_IO_ERROR", "openat: \(errno)") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ToolError("FS_NOT_REGULAR_FILE") }
        var data = Data(count: length), filled = 0
        while filled < length {
            let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + filled, length - filled, off_t(offset + filled)) }
            if count < 0 { if errno == EINTR { continue }; throw ToolError("FS_IO_ERROR", "pread: \(errno)") }
            if count == 0 { break }
            filled += count
        }
        return data.prefix(filled)
    }
}
