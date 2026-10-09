// Research-only #39 gate 3: the official file, search and change tools over the native workspace.
// The Worker reaches the project only through these calls; nothing here writes a VFS copy.
import CryptoKit
import Darwin
import Foundation
import NativeTools
import NativeWorkspace

/// One synthetic project for the gate 3 checks: the store, the file service, the read-only path
/// space git and the Node fs routes see, native search and native git. Every call is serialised.
final class Gate3Tools: @unchecked Sendable {
    static let mount = "/dsh/workspace/gate3"
    static let gitScripts = ["native-git-objects.js", "native-git-match.js", "native-git-xdiff.js", "native-git.js"]
    /// Worker assets the gate needs besides the page: native git and the fixture.
    static let assets = gitScripts + ["gate3-fixture.json"]

    let root: URL
    let web: URL
    private let lock = NSRecursiveLock()
    private var store: WorkspaceStore!
    private var files: NativeFileService!
    private var paths: NativePathSpace!
    private var search: NativeSearch!
    private var git: NativeGitHost!
    private var held: NativeWorkspace.Lease?

    init(root: URL, web: URL) {
        self.root = root; self.web = web
    }

    var workspace: URL { root.appendingPathComponent("workspace") }

    func handle(_ body: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let call = body["call"] as? String else { throw ToolError("GATE3_REFUSED", "no call") }
        if call == "seed" { return try seed() }
        if call == "asset" {
            guard let name = body["name"] as? String, Self.assets.contains(name) else { throw ToolError("GATE3_REFUSED", "asset") }
            return ["text": try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)]
        }
        guard store != nil else { throw ToolError("GATE3_REFUSED", "not seeded") }
        let args = body["args"] as? [String: Any] ?? [:]
        do {
            switch call {
            case "fs": return ["value": try fileCall(body["method"] as? String ?? "", args)]
            case "path": return ["value": try pathCall(body["method"] as? String ?? "", args)]
            case "spawn": return spawn(args)
            case "lease-hold":
                guard held == nil, case .granted(let lease) = try store.acquireLease("gate3-hold") else { throw ToolError("GATE3_REFUSED", "lease") }
                held = lease; return ["value": ["fence": lease.fence]]
            case "lease-release":
                guard let lease = held else { throw ToolError("GATE3_REFUSED", "no lease") }
                _ = try store.releaseLease(fence: lease.fence, reason: .completed); held = nil
                return ["value": true]
            case "git-tree": return ["value": try gitTree()]
            case "disk": return ["value": try disk(args["path"] as? String ?? "")]
            case "image": return ["value": try imageCall(body["method"] as? String ?? "", args)]
            default: throw ToolError("GATE3_REFUSED", call)
            }
        } catch let error as ToolError {
            // The page rejects any reply carrying `error`; a tool refusal is a value the Worker maps.
            return ["failure": ["code": error.code, "detail": error.detail]]
        }
    }

    // MARK: Seed

    /// Recreates the project from the fixture manifest the Mac generated with system git.
    func seed() throws -> [String: Any] {
        if let lease = held { _ = try? store.releaseLease(fence: lease.fence, reason: .completed); held = nil }
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: web.appendingPathComponent("gate3-fixture.json"))) as? [String: Any]
        guard manifest?["version"] as? Int == 1, let entries = manifest?["entries"] as? [[String: Any]] else {
            throw ToolError("GATE3_REFUSED", "fixture")
        }
        for entry in entries {
            guard let path = entry["path"] as? String, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw ToolError("GATE3_REFUSED", "fixture path")
            }
            let target = workspace.appendingPathComponent(path).path
            switch entry["type"] as? String {
            case "dir": try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            case "file":
                guard let data = Data(base64Encoded: entry["data"] as? String ?? "") else { throw ToolError("GATE3_REFUSED", "fixture data") }
                try data.write(to: URL(fileURLWithPath: target))
            case "symlink":
                try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: entry["target"] as? String ?? "")
            default: throw ToolError("GATE3_REFUSED", "fixture type")
            }
            if let mode = entry["mode"] as? Int, entry["type"] as? String != "symlink" { chmod(target, mode_t(mode)) }
        }
        store = try WorkspaceStore(workspace: workspace.path, state: root.appendingPathComponent("state").path)
        files = NativeFileService(store: store, mount: Self.mount)
        let store = store!
        paths = try NativePathSpace(files: files, scratch: root.appendingPathComponent("scratch").path) { store.lease != nil }
        search = NativeSearch(workspace: workspace.path, mount: Self.mount) { store.lease != nil }
        let scripts = try Self.gitScripts.map { ($0, try String(contentsOf: web.appendingPathComponent($0), encoding: .utf8)) }
        git = try NativeGitHost(paths: paths, scripts: scripts, ceiling: "/dsh/workspace")
        return ["mount": Self.mount, "entries": entries.count, "gitTree": try gitTree()]
    }

    // MARK: ctx.fs

    func fileCall(_ method: String, _ args: [String: Any]) throws -> Any {
        let path = args["path"] as? String ?? ""
        switch method {
        case "realpath": return try files.realpath(path)
        case "stat":
            guard let info = try files.stat(path, follow: args["follow"] as? Bool ?? true) else { return NSNull() }
            return ["type": info.type.rawValue, "size": info.size, "version": info.version as Any? ?? NSNull(), "mode": info.mode]
        case "list":
            return try files.list(path).map { entry -> [String: Any] in
                var out: [String: Any] = ["name": entry.name, "type": entry.type.rawValue, "target": entry.target]
                if let version = entry.version { out["version"] = version }
                if let size = entry.size { out["size"] = size }
                return out
            }
        case "read":
            let (data, version) = try files.read(path, limit: args["limit"] as? Int ?? Int.max)
            return ["data": data.base64EncodedString(), "version": version]
        case "readRange":
            return try files.readRange(path, offset: args["offset"] as? Int ?? 0, length: args["length"] as? Int ?? 0).base64EncodedString()
        case "write":
            guard let data = Data(base64Encoded: args["data"] as? String ?? "") else { throw ToolError("FS_IO_ERROR", "data") }
            var expected: WriteExpectation?
            if let kind = args["expected"] as? [String: Any] {
                switch kind["kind"] as? String {
                case "createIfAbsent": expected = .createIfAbsent
                case "replaceIfVersion": expected = .replaceIfVersion(kind["version"] as? String ?? "")
                default: throw ToolError("FS_IO_ERROR", "expectation")
                }
            }
            let outcome = try files.write(path, data, expected: expected, beforeLimit: args["beforeLimit"] as? Int ?? 0)
            return ["operation": outcome.operation.rawValue, "version": outcome.version,
                    "before": outcome.before?.base64EncodedString() as Any? ?? NSNull()]
        default: throw ToolError("FS_IO_ERROR", "unknown fs method \(method)")
        }
    }

    // MARK: Node fs routes

    func pathCall(_ method: String, _ args: [String: Any]) throws -> Any {
        let path = args["path"] as? String ?? ""
        switch method {
        case "lstat": return Self.describe(try paths.lstat(path))
        case "stat": return Self.describe(try paths.stat(path))
        case "realpath": return try paths.realpath(path)
        case "readlink": return try paths.readlink(path)
        case "readFile": return try paths.readFile(path).base64EncodedString()
        case "read":
            return try paths.read(path, offset: args["offset"] as? Int ?? 0, length: args["length"] as? Int ?? 0).base64EncodedString()
        case "readdir": return try paths.readdir(path).map { ["name": $0.name, "type": $0.type.rawValue] }
        case "mkdtemp": return try paths.mkdtemp(path)
        case "mkdir": try paths.mkdir(path, recursive: args["recursive"] as? Bool ?? false); return NSNull()
        case "writeFile":
            guard let data = Data(base64Encoded: args["data"] as? String ?? "") else { throw ToolError("EINVAL", "data") }
            try paths.writeFile(path, data, exclusive: args["exclusive"] as? Bool ?? false); return NSNull()
        case "copyFile":
            // The snapshot copies the repository index into its scratch; the source may be anywhere readable.
            try paths.writeFile(args["to"] as? String ?? "", try paths.readFile(path), exclusive: args["exclusive"] as? Bool ?? false)
            return NSNull()
        case "rename": try paths.rename(path, to: args["to"] as? String ?? ""); return NSNull()
        case "unlink": try paths.unlink(path); return NSNull()
        case "rm": try paths.rm(path, recursive: args["recursive"] as? Bool ?? false, force: args["force"] as? Bool ?? false); return NSNull()
        default: throw ToolError("ENOSYS", method)
        }
    }

    // MARK: Processes

    /// The two executables the official tools spawn: rg (fs-search) and git (workspace-changes).
    func spawn(_ args: [String: Any]) -> [String: Any] {
        let argv = args["argv"] as? [String] ?? []
        let cwd = args["cwd"] as? String ?? Self.mount
        let output: ProcessOutput
        switch args["tool"] as? String {
        case "rg": output = search.run(Array(argv.dropFirst()), cwd: cwd)
        case "git":
            let env = (args["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            output = git.run(argv, cwd: cwd, env: env, stdin: Data(base64Encoded: args["stdin"] as? String ?? "") ?? Data())
        default: output = ProcessOutput(exitCode: 127, stderr: Data("spawn refused\n".utf8))
        }
        return ["value": ["exitCode": Int(output.exitCode), "stdout": output.stdout.base64EncodedString(),
                          "stderr": output.stderr.base64EncodedString()]]
    }

    // MARK: Evidence

    /// SHA-256 over path, mode, size, mtime and content of every entry under the real `.git`.
    func gitTree() throws -> String {
        let base = workspace.appendingPathComponent(".git").path
        var lines: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: base)
        while let name = enumerator?.nextObject() as? String {
            var info = stat()
            guard lstat(base + "/" + name, &info) == 0 else { continue }
            var line = "\(name) \(info.st_mode) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            if info.st_mode & S_IFMT == S_IFREG {
                line += " " + Self.hex(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: base + "/" + name))))
            }
            lines.append(line)
        }
        return Self.hex(SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)))
    }

    /// What is on disk for one workspace path, read directly (not through the tools).
    func disk(_ relative: String) throws -> Any {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw ToolError("GATE3_REFUSED", "disk path") }
        let url = workspace.appendingPathComponent(relative)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return NSNull() }
        guard info.st_mode & S_IFMT == S_IFREG else { return ["mode": Int(info.st_mode)] }
        return ["mode": Int(info.st_mode), "data": try Data(contentsOf: url).base64EncodedString()]
    }

    /// The `sharp` stub's three native steps; bytes travel as base64.
    func imageCall(_ method: String, _ args: [String: Any]) throws -> Any {
        guard let data = Data(base64Encoded: args["data"] as? String ?? "") else { throw ToolError("INVALID_IMAGE", "Unsupported or malformed image data.") }
        let codec = NativeImageCodec()
        switch method {
        case "metadata":
            let meta = try codec.metadata(data)
            var value: [String: Any] = ["format": meta.format, "width": meta.width, "height": meta.height, "pages": meta.pages,
                                        "depth": meta.depth, "space": meta.space, "hasAlpha": meta.hasAlpha,
                                        "hasProfile": meta.hasProfile, "exif": meta.exif]
            if let orientation = meta.orientation { value["orientation"] = orientation }
            return value
        case "decode": try codec.decode(data); return true
        case "encode":
            let encoded = try codec.encode(data, options: .init(
                rotate: args["rotate"] as? Bool ?? false, width: args["width"] as? Int, height: args["height"] as? Int,
                withoutEnlargement: args["withoutEnlargement"] as? Bool ?? false, format: args["format"] as? String ?? "",
                quality: args["quality"] as? Int ?? 80))
            return ["data": encoded.data.base64EncodedString(), "width": encoded.width, "height": encoded.height]
        default: throw ToolError("GATE3_REFUSED", "image " + method)
        }
    }

    static func describe(_ info: PathStat) -> [String: Any] { info.dictionary.merging(["type": info.type.rawValue]) { $1 } }

    static func hex<D: Digest>(_ digest: D) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
