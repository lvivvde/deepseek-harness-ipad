// Research-only #39 gate 5: native reads of the project the Linux Git transactions change.
// Native never writes the repository: the review copies the index into its own scratch, and the
// `.git` digest before and after each review is part of every answer.
import Darwin
import Foundation
import NativeTools
import NativeWorkspace

final class Gate5Review: @unchecked Sendable {
    /// The project directory under the gateway workspace (Linux sees it as /workspace/gate5).
    static let directory = "gate5"
    static let mount = "/dsh/workspace/gate5"
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    let workspace: URL
    let root: URL
    let web: URL
    let busy: () -> Bool
    private let lock = NSLock()

    /// `workspace` is the project; `root` holds this side's own state and scratch, never the project.
    /// `busy` is true while a Linux command holds the write lease.
    init(workspace: URL, root: URL, web: URL, busy: @escaping () -> Bool) {
        self.workspace = workspace; self.root = root; self.web = web; self.busy = busy
    }

    var gitDirectory: String { workspace.appendingPathComponent(".git").path }

    func handle(_ body: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        do {
            switch body["call"] as? String {
            case "review": return ["value": try review()]
            case "git-digest": return ["value": try Gate3Tools.treeDigest(gitDirectory)]
            case "diff-tree": return ["value": try diffTree(body["from"] as? String, body["to"] as? String)]
            default: throw ToolError("GATE5_REFUSED", "call")
            }
        } catch let error as ToolError {
            return ["failure": ["code": error.code, "detail": error.detail]]
        }
    }

    // MARK: Review

    /// A fresh native git over the project, with its own store and scratch under `root`.
    private func nativeGit() throws -> (NativeGitHost, NativePathSpace) {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try WorkspaceStore(workspace: workspace.path, state: root.appendingPathComponent("state").path)
        let paths = try NativePathSpace(files: NativeFileService(store: store, mount: Self.mount),
                                        scratch: root.appendingPathComponent("scratch").path, busy: busy)
        let scripts = try Gate3Tools.gitScripts.map { ($0, try String(contentsOf: web.appendingPathComponent($0), encoding: .utf8)) }
        return (try NativeGitHost(paths: paths, scripts: scripts, ceiling: "/dsh/workspace"), paths)
    }

    /// The change set of the work tree against HEAD, read only through the native git subset:
    /// `rev-parse`, a scratch copy of the index, `add --all --ignore-errors`, `write-tree`,
    /// `rev-parse -q --verify HEAD` and `diff-tree -r -M -z --numstat`.
    func review() throws -> [String: Any] {
        // Explicit results instead of a read of a tree Linux is changing.
        if busy() { throw ToolError(NativePathSpace.leaseBusy, "a Linux command holds the workspace") }
        if FileManager.default.fileExists(atPath: gitDirectory + "/index.lock") {
            throw ToolError("GIT_INDEX_LOCKED", "a Git process holds the index")
        }
        let indexBefore = try? Data(contentsOf: URL(fileURLWithPath: gitDirectory + "/index"))
        let before = try Gate3Tools.treeDigest(gitDirectory)
        let (git, paths) = try nativeGit()
        func run(_ argv: [String], _ env: [String: String] = [:], allow: Set<Int32> = [0]) throws -> (Int32, Data) {
            let output = git.run(argv, cwd: Self.mount, env: env)
            guard allow.contains(output.exitCode) else {
                let text = String(decoding: output.stderr, as: UTF8.self)
                throw ToolError(text.contains("EBUSY") ? NativePathSpace.leaseBusy : "GIT_FAILED", argv[0] + ": " + text)
            }
            return (output.exitCode, output.stdout)
        }

        let located = String(decoding: try run(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-path", "objects"]).1,
                             as: UTF8.self).split(separator: "\n").map(String.init)
        guard located.count == 3 else { throw ToolError("GIT_FAILED", "rev-parse") }
        let objects = located[2].hasPrefix("/") ? located[2] : located[0] + "/" + located[2]
        let scratch = try paths.mkdtemp(NativePathSpace.scratchParent + "/" + NativePathSpace.scratchPrefix)
        try paths.mkdir(scratch + "/objects", recursive: false)
        if (try? paths.lstat(located[1] + "/index")) != nil {
            try paths.writeFile(scratch + "/index", try paths.readFile(located[1] + "/index"), exclusive: true)
        }
        let env = ["GIT_INDEX_FILE": scratch + "/index", "GIT_OBJECT_DIRECTORY": scratch + "/objects",
                   "GIT_ALTERNATE_OBJECT_DIRECTORIES": objects]
        _ = try run(["add", "--all", "--ignore-errors"], env)
        let tree = String(decoding: try run(["write-tree"], env).1, as: UTF8.self).trimmingCharacters(in: .newlines)
        let verified = try run(["rev-parse", "-q", "--verify", "HEAD"], allow: [0, 1])
        let head = verified.0 == 0 ? String(decoding: verified.1, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
        let numstat = try run(["diff-tree", "-r", "-M", "-z", "--numstat", head ?? Self.emptyTree, tree], env).1

        let after = try Gate3Tools.treeDigest(gitDirectory)
        let indexAfter = try? Data(contentsOf: URL(fileURLWithPath: gitDirectory + "/index"))
        return ["head": head as Any? ?? NSNull(), "tree": tree, "numstat": String(decoding: numstat, as: UTF8.self),
                "gitDigestBefore": before, "gitDigestAfter": after, "indexUnchanged": indexBefore == indexAfter,
                "index": indexBefore.map { indexStat($0) } ?? NSNull()]
    }

    /// `diff-tree -r -M -z --numstat <from> <to>` of two commits, read natively; the `.git` digest must not move.
    func diffTree(_ from: String?, _ to: String?) throws -> [String: Any] {
        let oid = { (value: String?) in value?.utf8.count == 40 && value!.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard oid(from), oid(to), let from, let to else { throw ToolError("GATE5_REFUSED", "oid") }
        if busy() { throw ToolError(NativePathSpace.leaseBusy, "a Linux command holds the workspace") }
        let before = try Gate3Tools.treeDigest(gitDirectory)
        let git = try nativeGit().0
        let output = git.run(["diff-tree", "-r", "-M", "-z", "--numstat", from, to], cwd: Self.mount, env: [:])
        guard output.exitCode == 0 else { throw ToolError("GIT_FAILED", String(decoding: output.stderr, as: UTF8.self)) }
        return ["numstat": String(decoding: output.stdout, as: UTF8.self), "gitDigestBefore": before,
                "gitDigestAfter": try Gate3Tools.treeDigest(gitDirectory)]
    }

    // MARK: Index stat cache

    /// Entries of an index (v2 or v3) whose cached stat differs from what native lstat sees now.
    /// Linux wrote them over 9P, so device, inode or times usually differ; none may become a change.
    func indexStat(_ data: Data) -> [String: Any] {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("DIRC".utf8), [2, 3].contains(u32(4)) else {
            return ["parsed": false]
        }
        let count = Int(u32(8))
        var at = 12, differing = 0, fields: [String: Int] = [:]
        for _ in 0..<count {
            guard at + 62 <= bytes.count else { return ["parsed": false] }
            let flags = Int(bytes[at + 60]) << 8 | Int(bytes[at + 61])
            let extended = flags & 0x4000 != 0
            let nameStart = at + 62 + (extended ? 2 : 0)
            guard let end = bytes[nameStart...].firstIndex(of: 0) else { return ["parsed": false] }
            let path = String(decoding: bytes[nameStart..<end], as: UTF8.self)
            var info = stat()
            if lstat(workspace.appendingPathComponent(path).path, &info) == 0 {
                let checks: [(String, Bool)] = [
                    ("ctime", u32(at) != UInt32(truncatingIfNeeded: info.st_ctimespec.tv_sec)
                        || u32(at + 4) != UInt32(truncatingIfNeeded: info.st_ctimespec.tv_nsec)),
                    ("mtime", u32(at + 8) != UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec)
                        || u32(at + 12) != UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec)),
                    ("dev", u32(at + 16) != UInt32(truncatingIfNeeded: info.st_dev)),
                    ("ino", u32(at + 20) != UInt32(truncatingIfNeeded: info.st_ino)),
                    ("uid", u32(at + 28) != info.st_uid),
                    ("gid", u32(at + 32) != info.st_gid),
                ]
                let differs = checks.filter(\.1).map(\.0)
                if !differs.isEmpty { differing += 1 }
                for name in differs { fields[name, default: 0] += 1 }
            }
            // Entries are padded with NULs to a multiple of 8 bytes.
            at += (end + 1 - at + 7) / 8 * 8
        }
        return ["parsed": true, "entries": count, "statDiffering": differing, "fields": fields]
    }
}
