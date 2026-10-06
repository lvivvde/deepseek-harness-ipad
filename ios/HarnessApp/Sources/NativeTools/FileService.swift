import Darwin
import Foundation
import NativeWorkspace

public enum EntryType: String, Codable, Equatable { case file, directory, symlink, other }

public struct EntryInfo: Equatable {
    public let type: EntryType
    public let size: Int
    /// The store token for files, symlinks and special entries; directories have none.
    public let version: String?
    public let mode: Int
}

public struct ListedEntry: Equatable {
    public let name: String
    public let type: EntryType
    /// Canonical process path of the child (a followed symlink names its target).
    public let target: String
    public let version: String?
    public let size: Int?
}

public enum WriteExpectation: Equatable {
    case createIfAbsent
    case replaceIfVersion(String)
}

public struct WriteOutcome: Equatable {
    public enum Operation: String { case create, update }
    public let operation: Operation
    public let version: String
    /// The previous bytes, when they existed and were under the caller's basis limit.
    public let before: Data?
}

/// `ctx.fs` for the project, served from the native workspace. Text decoding, line endings and
/// edit matching stay in the Worker adapter, which copies dsh-fs-local; this layer owns path
/// confinement, versions and the only write path (the store's CAS with drafts under a lease).
public final class NativeFileService {
    public let store: WorkspaceStore
    let mount: Mount

    public init(store: WorkspaceStore, mount: String) {
        self.store = store
        self.mount = Mount(processRoot: Array(mount.utf8), directory: store.files.root)
    }

    public var mountPoint: String { String(decoding: mount.processRoot, as: UTF8.self) }

    /// dsh-fs-local's target key: the real path, or for a missing path the real path of its nearest
    /// existing ancestor plus the missing names.
    public func realpath(_ processPath: String) throws -> String {
        switch try mount.resolve(processPath, followLeaf: true) {
        case .found(let components): return mount.processPath(components)
        case .missing(let existing, let missing):
            guard !missing.contains([0x2E, 0x2E]) else { throw ToolError("FS_NOT_FOUND", "parent traversal crosses a missing directory") }
            return mount.processPath(existing + missing)
        }
    }

    public func stat(_ processPath: String, follow: Bool) throws -> EntryInfo? {
        guard case .found(let components) = try mount.resolve(processPath, followLeaf: follow),
              let info = try mount.lstat(components) else { return nil }
        let type = Self.type(info)
        return EntryInfo(type: type, size: Int(info.st_size), version: type == .directory ? nil : try version(components),
                         mode: Int(info.st_mode & 0o777))
    }

    public func list(_ processPath: String) throws -> [ListedEntry] {
        guard case .found(let directory) = try mount.resolve(processPath, followLeaf: true),
              let info = try mount.lstat(directory) else { throw ToolError("FS_NOT_FOUND") }
        guard Self.type(info) == .directory else { throw ToolError("FS_NOT_DIRECTORY") }
        var entries: [ListedEntry] = []
        for name in try mount.names(directory).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            if directory.isEmpty && name == WorkspaceFiles.identity { continue }
            if name.starts(with: WorkspaceFiles.temporaryPrefix) { continue }
            let child = mount.processPath(directory + [name])
            var target = child, info: EntryInfo?
            do {
                target = try realpath(child)
                info = try stat(child, follow: true)
            } catch let error as ToolError where error.code == "FS_SANDBOX_DENIED" || error.code == "FS_IO_ERROR" {
                // A link that leaves the workspace (or loops) is listed but never followed.
                target = child; info = nil
            }
            entries.append(ListedEntry(name: String(decoding: name, as: UTF8.self), type: info?.type ?? .other, target: target,
                                       version: info?.version, size: info?.type == .file ? info?.size : nil))
        }
        return entries
    }

    public func read(_ processPath: String, limit: Int) throws -> (Data, String) {
        let components = try existing(processPath)
        let path = mount.relative(components)
        for _ in 0..<3 {
            switch try store.nativeRead(path, limit: limit) {
            case .read(let data, let version): return (data, version)
            case .absent: throw ToolError("FS_NOT_FOUND")
            case .leaseBusy: throw ToolError("WORKSPACE_LEASE_BUSY", "a Linux command holds the workspace")
            case .retry: continue
            case .refused(let reason): throw Self.refusal(reason)
            }
        }
        throw ToolError("FS_IO_ERROR", "the file kept changing while it was read")
    }

    public func readRange(_ processPath: String, offset: Int, length: Int) throws -> Data {
        let components = try existing(processPath)
        try path(components)
        return try mount.readRange(components, offset: offset, length: length)
    }

    public func write(_ processPath: String, _ data: Data, expected: WriteExpectation?, beforeLimit: Int) throws -> WriteOutcome {
        let target = try realpath(processPath)
        guard let components = mount.components(target) else { throw ToolError("FS_SANDBOX_DENIED") }
        let path = try self.path(components)
        let current: String?
        var before: Data?
        if store.lease != nil {
            current = store.version(path)
        } else {
            switch try store.nativeVersion(path) {
            case .entry(let token): current = token
            case .absent: current = nil
            case .directory: throw ToolError("FS_NOT_REGULAR_FILE")
            case .leaseBusy: current = store.version(path)
            case .refused(let reason): throw Self.refusal(reason)
            }
        }
        if let current, !current.contains(":F:") { throw ToolError("FS_NOT_REGULAR_FILE") }
        switch expected {
        case .replaceIfVersion(let version):
            guard current != nil else { throw ToolError("FS_STALE_VERSION", "file no longer exists") }
            guard current == version else { throw ToolError("FS_STALE_VERSION", "file changed since it was read") }
        case .createIfAbsent:
            guard current == nil else { throw ToolError("FS_NOT_OBSERVED") }
        case nil: break
        }
        if let current, store.lease == nil, beforeLimit > 0, case .read(let previous, let read) = try store.nativeRead(path, limit: beforeLimit - 1),
           read == current {
            before = previous
        }
        switch try store.nativeWrite(path, data, base: current) {
        case .written(let version): return WriteOutcome(operation: current == nil ? .create : .update, version: version, before: before)
        case .draftHeld(let id): throw ToolError("WORKSPACE_DRAFT_HELD", "a Linux command holds the workspace; draft \(id) is applied when it finishes")
        case .conflict(let draft, _): throw ToolError("FS_STALE_VERSION", "file changed since it was read; draft \(draft) keeps the new bytes")
        case .refused(let reason): throw Self.refusal(reason)
        case .failed(let message): throw ToolError("FS_IO_ERROR", message)
        }
    }

    // MARK: Helpers

    static func type(_ info: stat) -> EntryType {
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    static func refusal(_ reason: String) -> ToolError {
        switch reason {
        case "PATH_RESERVED": return ToolError("FS_PERMISSION_DENIED", "reserved by the workspace store")
        case "PATH_REFUSED": return ToolError("FS_SANDBOX_DENIED")
        case "NOT_REGULAR": return ToolError("FS_NOT_REGULAR_FILE")
        case "READ_TOO_LARGE": return ToolError("FS_TOO_LARGE")
        default: return ToolError("FS_IO_ERROR", reason)
        }
    }

    /// Components of a path that exists after following every symlink.
    func existing(_ processPath: String) throws -> [[UInt8]] {
        switch try mount.resolve(processPath, followLeaf: true) {
        case .found(let components): return components
        case .missing(let existing, let missing):
            // A reserved store name is refused whether or not it exists right now.
            if !missing.contains([0x2E, 0x2E]) { try path(existing + missing) }
            throw ToolError("FS_NOT_FOUND")
        }
    }

    @discardableResult
    func path(_ components: [[UInt8]]) throws -> RelativePath {
        let path = mount.relative(components)
        do { try path.validate() } catch WorkspaceError.pathRefused(let reason) {
            throw components.isEmpty ? ToolError("FS_NOT_REGULAR_FILE") : Self.refusal(reason)
        }
        return path
    }

    /// The store's token; while a Linux command holds the lease, the last known one.
    func version(_ components: [[UInt8]]) throws -> String? {
        let path = try self.path(components)
        switch try store.nativeVersion(path) {
        case .entry(let token): return token
        case .leaseBusy: return store.version(path)
        case .directory, .absent: return nil
        case .refused(let reason): throw Self.refusal(reason)
        }
    }
}
