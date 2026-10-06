import Foundation

typealias Bytes = [UInt8]

extension Array where Element == Bytes {
    var joinedPath: Bytes { Bytes(self.joined(separator: [0x2F])) }
    var display: String { String(decoding: joinedPath, as: UTF8.self) }
}

/// One node the migrated tree must contain, in target layout (relative to the target root).
struct Planned: Equatable {
    enum Kind: Equatable {
        case file(sha256: String, size: Int)
        case directory
        case symlink(Bytes)
        /// A second name for an earlier planned file (target components of that file).
        case hardlink([Bytes])
    }
    let path: [Bytes]
    let kind: Kind
    let mode: UInt32
}

/// What happens to one archive entry.
enum Step: Equatable {
    case create(Planned)
    case layoutVersion
    case credential(String)
    case cache
    case special(String)
}

/// The rules for which old-backup entries are accepted and where they land. They mirror the old app's
/// restore filter (`runtime/guest/backup.cjs`) so nothing the old app would refuse is migrated, with two
/// deliberate differences: special files are skipped and reported rather than failing the backup, and
/// credentials are never carried over.
///
/// Layout: `projects/…` stays `projects/…`; `.dsh/…` (the old official home) becomes `home/…`, the new
/// `DSH_HOME`; every other name in the old `/root` goes under `linux-home/…` for the Linux plugin.
enum Rules {
    static let excludedNames: Set<Bytes> = [Bytes("node_modules".utf8), Bytes(".cache".utf8), Bytes(".git-credentials".utf8)]

    /// Old `/root`-relative paths whose content is a credential. A directory listed here drops its subtree.
    static let credentials: [[Bytes]] = [
        [".dsh", ".credentials.yaml"], [".netrc"], [".npmrc"], [".pypirc"], [".ssh"], [".gnupg"],
        [".docker", "config.json"], [".config", "gh", "hosts.yml"]
    ].map { $0.map { Bytes($0.utf8) } }

    static let cache: [Bytes] = [".dsh", "storages", "session_projcache"].map { Bytes($0.utf8) }

    static func validName(_ name: Bytes) -> Bool {
        !name.isEmpty && name != [0x2E] && name != [0x2E, 0x2E] && !name.contains { $0 < 0x20 || $0 == 0x2F }
            && String(validatingUTF8CString: name) != nil
    }

    static func reserved(_ first: Bytes) -> Bool {
        let name = String(decoding: first, as: UTF8.self)
        return name == ".harness-restore.json" || name == ".harness-restore.tmp" || name.hasPrefix(".restore-")
            || name.hasPrefix(".harness-write-probe-")
    }

    /// Splits and validates an archive path; trailing slashes (directory entries) are dropped.
    static func components(_ raw: Bytes) throws -> [Bytes] {
        var path = raw[...]
        while path.last == 0x2F { path = path.dropLast() }
        let parts = path.split(separator: 0x2F, omittingEmptySubsequences: false).map(Bytes.init)
        guard !parts.isEmpty, parts.allSatisfy(validName) else { throw MigrationError.archiveUnsafe("NAME") }
        guard !reserved(parts[0]), !path.starts(with: Bytes(".trash/.purging-".utf8)) else { throw MigrationError.archiveUnsafe("RESERVED") }
        guard !parts.contains(where: excludedNames.contains) else { throw MigrationError.archiveUnsafe("EXCLUDED_NAME") }
        return parts
    }

    /// POSIX normalisation of a relative link; nil when it is absolute or climbs above the archive root.
    static func normalized(_ link: Bytes, from directory: [Bytes]) -> [Bytes]? {
        guard !link.isEmpty, link.first != 0x2F else { return nil }
        var stack = directory
        for part in link.split(separator: 0x2F, omittingEmptySubsequences: true).map(Bytes.init) {
            if part == [0x2E] { continue }
            if part == [0x2E, 0x2E] {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else { stack.append(part) }
        }
        return stack
    }

    static func isCredential(_ parts: [Bytes]) -> Bool {
        credentials.contains { parts.count >= $0.count && Array(parts.prefix($0.count)) == $0 }
    }

    /// Target components for an old `/root`-relative path.
    static func mapped(_ parts: [Bytes]) -> [Bytes] {
        switch String(decoding: parts[0], as: UTF8.self) {
        case "projects": return parts
        case ".dsh": return [Bytes("home".utf8)] + parts.dropFirst()
        default: return [Bytes("linux-home".utf8)] + parts
        }
    }

    /// Key under which two names land on the same file on a case- or normalisation-insensitive volume.
    static func foldKey(_ parts: [Bytes]) -> String {
        parts.map { (String(decoding: $0, as: UTF8.self) as NSString).decomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil) }.joined(separator: "/")
    }

    /// Owner bits are kept usable: the app is not root, and the old guest was.
    static func effectiveMode(_ mode: UInt32, directory: Bool) -> UInt32 {
        (mode & 0o777) | (directory ? 0o700 : 0o600)
    }
}

private extension String {
    init?(validatingUTF8CString bytes: Bytes) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        self = text
    }
}

/// The full plan of one archive, built in a read-only pass before anything is written.
struct Plan {
    var steps: [Step] = []
    var manifest: [Bytes: Planned] = [:]
    /// Creation order (parents before children, implicit parents included).
    var order: [Bytes] = []
    var folded: [String: Bytes] = [:]
    var conflicts: Set<String> = []
    var layoutVersion: Bytes?
    var implicit: Set<Bytes> = []
    var requiredBytes: Int64 = 0

    /// Adds one node and any parent it implies. A name planned twice, or a non-directory used as a
    /// parent, is unsafe; an explicit directory entry may follow its implicit creation.
    mutating func add(_ node: Planned) throws {
        for depth in stride(from: 1, to: node.path.count, by: 1) {
            let parent = Array(node.path.prefix(depth))
            if let existing = manifest[parent.joinedPath] {
                guard existing.kind == .directory else { throw MigrationError.archiveUnsafe("PARENT_NOT_DIRECTORY") }
            } else {
                register(Planned(path: parent, kind: .directory, mode: 0o755))
                implicit.insert(parent.joinedPath)
            }
        }
        let key = node.path.joinedPath
        if manifest[key] != nil {
            guard implicit.contains(key), node.kind == .directory else { throw MigrationError.archiveUnsafe("DUPLICATE") }
            manifest[key] = node
            implicit.remove(key)
            return
        }
        register(node)
    }

    private mutating func register(_ node: Planned) {
        let key = node.path.joinedPath
        let fold = Rules.foldKey(node.path)
        if let other = folded[fold], other != key {
            conflicts.insert([String(decoding: other, as: UTF8.self), node.path.display].sorted().joined(separator: " <> "))
        }
        folded[fold] = key
        manifest[key] = node
        order.append(key)
        if case .file(_, let size) = node.kind { requiredBytes += Int64((size + 4095) / 4096 * 4096) }
        requiredBytes += 4096
    }
}
