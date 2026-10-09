import Darwin
import Foundation
import NativeWorkspace

/// An `lstat` as Node reports it: the full mode, and times as nanosecond decimal strings so they
/// survive JSON and JavaScript numbers.
public struct PathStat: Equatable {
    public let mode: Int
    public let size: Int
    public let dev: Int
    public let ino: UInt64
    public let uid: Int
    public let gid: Int
    public let nlink: Int
    public let mtimeNs: String
    public let ctimeNs: String

    public var type: EntryType {
        switch mode & Int(S_IFMT) {
        case Int(S_IFREG): return .file
        case Int(S_IFDIR): return .directory
        case Int(S_IFLNK): return .symlink
        default: return .other
        }
    }

    public var dictionary: [String: Any] {
        ["mode": mode, "size": size, "dev": dev, "ino": Double(ino), "uid": uid, "gid": gid, "nlink": nlink,
         "mtimeNs": mtimeNs, "ctimeNs": ctimeNs,
         "mtimeMs": (Double(mtimeNs) ?? 0) / 1e6, "ctimeMs": (Double(ctimeNs) ?? 0) / 1e6]
    }

    init(_ info: stat) {
        func ns(_ time: timespec) -> String { String(Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)) }
        mode = Int(info.st_mode); size = Int(info.st_size); dev = Int(UInt32(bitPattern: info.st_dev)); ino = info.st_ino
        uid = Int(info.st_uid); gid = Int(info.st_gid); nlink = Int(info.st_nlink)
        mtimeNs = ns(info.st_mtimespec); ctimeNs = ns(info.st_ctimespec)
    }

    static func directory() -> PathStat {
        var info = stat(); info.st_mode = S_IFDIR | 0o555; info.st_nlink = 2
        return PathStat(info)
    }
}

/// The Worker's file namespace for git and the Node fs routes, with Node's errno codes
/// (`ToolError.code` is `ENOENT`, `EROFS`, …):
/// - the project mount, read-only, through `Mount` (symlinks resolved inside the workspace, store
///   names hidden);
/// - `/dsh/tmp/dsh-workspace-changes-*`, a native scratch directory the snapshot plugin may write;
/// - the directories above them, empty and read-only.
/// Writing anywhere but the scratch is `EROFS` (`VFS_WORKSPACE_WRITE_REFUSED`): project files
/// change only through `NativeFileService.write`.
public final class NativePathSpace {
    public static let scratchParent = "/dsh/tmp"
    public static let scratchPrefix = "dsh-workspace-changes-"
    public static let writeRefused = "VFS_WORKSPACE_WRITE_REFUSED"
    public static let leaseBusy = "WORKSPACE_LEASE_BUSY"

    let mount: Mount
    let mountComponents: [[UInt8]]
    let scratchComponents: [[UInt8]]
    public let scratchDirectory: String
    let busy: () -> Bool

    /// `busy` is true while a Linux command holds the write lease; project reads then fail with
    /// `EBUSY` rather than see a half-written tree.
    public init(files: NativeFileService, scratch: String, busy: @escaping () -> Bool) throws {
        mount = files.mount
        mountComponents = Self.split(files.mountPoint)
        scratchComponents = Self.split(Self.scratchParent)
        scratchDirectory = scratch
        self.busy = busy
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }

    // MARK: Reads

    public func lstat(_ path: String) throws -> PathStat {
        switch try locate(path) {
        case .virtual: return .directory()
        case .scratch(let real): return try Self.posixLstat(real)
        case .workspace(let requested):
            guard case .found(let components) = try workspace({ try mount.resolve(requested, followLeaf: false) }),
                  !hidden(components), let info = try workspace({ try mount.lstat(components) }) else { throw Self.error(ENOENT) }
            return PathStat(info)
        }
    }

    public func stat(_ path: String) throws -> PathStat { try lstat(realpath(path)) }

    public func realpath(_ path: String) throws -> String {
        switch try locate(path) {
        case .virtual(let components): return Self.join(components)
        case .scratch: _ = try lstat(path); return Self.join(Self.split(path))
        case .workspace(let requested):
            guard case .found(let components) = try workspace({ try mount.resolve(requested, followLeaf: true) }),
                  !hidden(components) else { throw Self.error(ENOENT) }
            return mount.processPath(components)
        }
    }

    public func readlink(_ path: String) throws -> String {
        guard case .workspace(let requested) = try locate(path) else { throw Self.error(EINVAL) }
        guard case .found(let components) = try workspace({ try mount.resolve(requested, followLeaf: false) }), !hidden(components),
              let info = try workspace({ try mount.lstat(components) }) else { throw Self.error(ENOENT) }
        guard info.st_mode & S_IFMT == S_IFLNK else { throw Self.error(EINVAL) }
        return String(decoding: try workspace({ try mount.readlink(components) }), as: UTF8.self)
    }

    /// Up to `length` bytes at `offset` of a regular file, following symlinks.
    public func read(_ path: String, offset: Int, length: Int) throws -> Data {
        switch try locate(path) {
        case .virtual: throw Self.error(EISDIR)
        case .scratch(let real):
            let descriptor = open(real, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.error(errno) }
            defer { close(descriptor) }
            var info = Darwin.stat()
            guard fstat(descriptor, &info) == 0 else { throw Self.error(errno) }
            if info.st_mode & S_IFMT == S_IFDIR { throw Self.error(EISDIR) }
            return try Self.pread(descriptor, offset: offset, length: length)
        case .workspace:
            let real = try realpath(path)
            guard let components = mount.components(real) else { throw Self.error(ENOENT) }
            guard let info = try workspace({ try mount.lstat(components) }) else { throw Self.error(ENOENT) }
            if info.st_mode & S_IFMT == S_IFDIR { throw Self.error(EISDIR) }
            return try workspace({ try mount.readRange(components, offset: offset, length: length) })
        }
    }

    public func readFile(_ path: String, limit: Int = 1 << 30) throws -> Data {
        let size = try stat(path).size
        guard size <= limit else { throw ToolError("EFBIG", "file is larger than \(limit) bytes") }
        // A file that grew since the stat is read to its new end, still under the limit.
        var data = try read(path, offset: 0, length: size)
        while data.count >= size, data.count < limit {
            let more = try read(path, offset: data.count, length: min(1 << 20, limit - data.count))
            if more.isEmpty { break }
            data.append(more)
        }
        return data
    }

    public struct DirectoryEntry: Equatable {
        public let name: String
        public let type: EntryType
    }

    /// Names in byte order, with the entry type as `lstat` sees it.
    public func readdir(_ path: String) throws -> [DirectoryEntry] {
        let target = try realpath(path)
        let info = try lstat(target)
        guard info.type == .directory else { throw Self.error(ENOTDIR) }
        var names: [[UInt8]]
        switch try locate(target) {
        case .virtual(let components): names = virtualChildren(components)
        case .scratch(let real):
            names = try FileManager.default.contentsOfDirectory(atPath: real).map { Array($0.utf8) }
        case .workspace:
            guard let components = mount.components(target) else { throw Self.error(ENOENT) }
            names = try workspace({ try mount.names(components) }).filter { !hidden(components + [$0]) }
        }
        return try names.sorted { $0.lexicographicallyPrecedes($1) }.compactMap { name in
            let child = target == "/" ? "/" + String(decoding: name, as: UTF8.self) : target + "/" + String(decoding: name, as: UTF8.self)
            do { return DirectoryEntry(name: String(decoding: name, as: UTF8.self), type: try lstat(child).type) }
            catch let error as ToolError where error.code == "ENOENT" { return nil }
        }
    }

    // MARK: Scratch writes

    public func mkdtemp(_ prefix: String) throws -> String {
        let parent = (prefix as NSString).deletingLastPathComponent
        let leaf = (prefix as NSString).lastPathComponent
        let real: String
        if Self.split(parent) == scratchComponents && leaf.hasPrefix(Self.scratchPrefix) {
            real = scratchDirectory + "/" + leaf
        } else {
            guard case .scratch(let directory) = try locate(parent) else { throw refusedOrMissing(parent) }
            real = directory + "/" + leaf
        }
        var template = Array((real + "XXXXXX").utf8CString)
        guard template.withUnsafeMutableBufferPointer({ Darwin.mkdtemp($0.baseAddress!) }) != nil else { throw Self.error(errno) }
        let made = String(cString: template)
        return parent + "/" + (made as NSString).lastPathComponent
    }

    public func mkdir(_ path: String, recursive: Bool) throws {
        switch try locate(path) {
        case .scratch(let real):
            if recursive {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory) {
                    if isDirectory.boolValue { return }
                    throw Self.error(EEXIST)
                }
                do { try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true) }
                catch { throw Self.error(ENOTDIR) }
            } else if Darwin.mkdir(real, 0o700) != 0 { throw Self.error(errno) }
        case .virtual where recursive: return
        case .workspace where recursive:
            // Node's mkdir -p of an existing directory changes nothing; creating one would be a second write path.
            let info: PathStat
            do { info = try stat(path) } catch let error as ToolError where error.code == "ENOENT" { throw refusedOrMissing(path) }
            if info.type != .directory { throw Self.error(EEXIST) }
        default: throw refusedOrMissing(path)
        }
    }

    public func writeFile(_ path: String, _ data: Data, exclusive: Bool) throws {
        guard case .scratch(let real) = try locate(path) else { throw refusedOrMissing(path) }
        let descriptor = open(real, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW | (exclusive ? O_EXCL : 0), 0o600)
        guard descriptor >= 0 else { throw Self.error(errno) }
        defer { close(descriptor) }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { write(descriptor, $0.baseAddress! + written, data.count - written) }
            if count < 0 { if errno == EINTR { continue }; throw Self.error(errno) }
            written += count
        }
    }

    public func rename(_ from: String, to: String) throws {
        guard case .scratch(let source) = try locate(from) else { throw refusedOrMissing(from) }
        guard case .scratch(let target) = try locate(to) else { throw refusedOrMissing(to) }
        guard Darwin.rename(source, target) == 0 else { throw Self.error(errno) }
    }

    public func unlink(_ path: String) throws {
        guard case .scratch(let real) = try locate(path) else { throw refusedOrMissing(path) }
        guard Darwin.unlink(real) == 0 else { throw Self.error(errno) }
    }

    public func rm(_ path: String, recursive: Bool, force: Bool) throws {
        guard case .scratch(let real) = try locate(path) else {
            if force, (try? lstat(path)) == nil { return }
            throw refusedOrMissing(path)
        }
        var info = Darwin.stat()
        guard Darwin.lstat(real, &info) == 0 else { if force && errno == ENOENT { return }; throw Self.error(errno) }
        if info.st_mode & S_IFMT == S_IFDIR && !recursive { throw ToolError("ERR_FS_EISDIR", "is a directory") }
        do { try FileManager.default.removeItem(atPath: real) } catch { throw Self.error(EIO) }
    }

    // MARK: Locations

    enum Location {
        case virtual([[UInt8]])
        case workspace(String)
        case scratch(String)
    }

    /// Lexically normalised, as `path.resolve` would leave it; the workspace part keeps its real
    /// symlink resolution in `Mount`.
    func locate(_ path: String) throws -> Location {
        guard path.hasPrefix("/") else { throw ToolError("EINVAL", "path is not absolute") }
        let components = Self.split(path)
        if components.starts(with: mountComponents) {
            return .workspace(Self.join(components))
        }
        if components.count > scratchComponents.count, components.starts(with: scratchComponents),
           components[scratchComponents.count].starts(with: Array(Self.scratchPrefix.utf8)) {
            let rest = components.dropFirst(scratchComponents.count).map { String(decoding: $0, as: UTF8.self) }
            return .scratch(scratchDirectory + "/" + rest.joined(separator: "/"))
        }
        if mountComponents.starts(with: components) || scratchComponents.starts(with: components) { return .virtual(components) }
        throw Self.error(ENOENT)
    }

    func virtualChildren(_ components: [[UInt8]]) -> [[UInt8]] {
        var names: [[UInt8]] = []
        for path in [mountComponents, scratchComponents] where path.count > components.count && path.starts(with: components) {
            if !names.contains(path[components.count]) { names.append(path[components.count]) }
        }
        if components == scratchComponents {
            names += ((try? FileManager.default.contentsOfDirectory(atPath: scratchDirectory)) ?? [])
                .filter { $0.hasPrefix(Self.scratchPrefix) }.map { Array($0.utf8) }
        }
        return names
    }

    func hidden(_ components: [[UInt8]]) -> Bool {
        if components.first == WorkspaceFiles.identity { return true }
        return components.contains { $0.starts(with: WorkspaceFiles.temporaryPrefix) }
    }

    /// Runs a `Mount` step after the lease check, mapping its file codes onto errno names.
    func workspace<T>(_ body: () throws -> T) throws -> T {
        guard !busy() else { throw ToolError("EBUSY", Self.leaseBusy) }
        do { return try body() } catch let error as ToolError {
            switch error.code {
            case "FS_NOT_FOUND": throw ToolError(error.detail.contains("not a directory") ? "ENOTDIR" : "ENOENT", error.detail)
            case "FS_SANDBOX_DENIED": throw ToolError("ENOENT", "symlink leaves the workspace")
            case "FS_PERMISSION_DENIED": throw ToolError("EACCES", error.detail)
            case "FS_NOT_REGULAR_FILE": throw ToolError("EISDIR", error.detail)
            case "FS_IO_ERROR" where error.detail.contains("symbolic links"): throw ToolError("ELOOP", error.detail)
            default: throw ToolError("EIO", error.description)
            }
        }
    }

    func refusedOrMissing(_ path: String) -> ToolError {
        switch try? locate(path) {
        case .workspace, .virtual: return ToolError("EROFS", Self.writeRefused)
        default: return Self.error(ENOENT)
        }
    }

    static func split(_ path: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for part in Array(path.utf8).split(separator: 0x2F, omittingEmptySubsequences: true) {
            if part.elementsEqual([0x2E]) { continue }
            if part.elementsEqual([0x2E, 0x2E]) { if !out.isEmpty { out.removeLast() }; continue }
            out.append(Array(part))
        }
        return out
    }

    static func join(_ components: [[UInt8]]) -> String {
        "/" + components.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
    }

    static func posixLstat(_ real: String) throws -> PathStat {
        var info = Darwin.stat()
        guard Darwin.lstat(real, &info) == 0 else { throw error(errno) }
        return PathStat(info)
    }

    static func pread(_ descriptor: Int32, offset: Int, length: Int) throws -> Data {
        var data = Data(count: length), filled = 0
        while filled < length {
            let count = data.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress! + filled, length - filled, off_t(offset + filled)) }
            if count < 0 { if errno == EINTR { continue }; throw error(errno) }
            if count == 0 { break }
            filled += count
        }
        return data.prefix(filled)
    }

    static func error(_ code: Int32) -> ToolError {
        let names: [Int32: String] = [ENOENT: "ENOENT", ENOTDIR: "ENOTDIR", EEXIST: "EEXIST", EISDIR: "EISDIR",
                                      ENOTEMPTY: "ENOTEMPTY", EACCES: "EACCES", EPERM: "EPERM", ELOOP: "ELOOP",
                                      EINVAL: "EINVAL", EROFS: "EROFS", EBUSY: "EBUSY"]
        return ToolError(names[code] ?? "EIO", String(cString: strerror(code)))
    }
}
