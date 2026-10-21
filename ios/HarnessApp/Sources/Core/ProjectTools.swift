import Foundation
import HarnessHost
import NativeTools
import NativeWorkspace

/// The official file, search and change tools over one project's native workspace. Every call holds
/// the gateway's store lock, so tool work is serialized with native writes and the Linux lease.
final class ProjectTools: @unchecked Sendable {
    let gateway: ProjectGateway
    private var files: NativeFileService!
    private var paths: NativePathSpace!
    private var search: NativeSearch!
    private var git: NativeGitHost!

    init(gateway: ProjectGateway, workspace: String, mount: String, scratch: String,
         gitScripts: [(name: String, source: String)]) throws {
        self.gateway = gateway
        try gateway.withStore { store in
            files = NativeFileService(store: store, mount: mount)
            paths = try NativePathSpace(files: files, scratch: scratch) { store.lease != nil }
            search = NativeSearch(workspace: workspace, mount: mount) { store.lease != nil }
            git = try NativeGitHost(paths: paths, scripts: gitScripts, ceiling: "/dsh/workspace")
        }
    }

    // MARK: ctx.fs

    func file(_ method: String, _ args: [String: Any]) throws -> Any {
        try gateway.withStore { _ in try fileLocked(method, args) }
    }

    private func fileLocked(_ method: String, _ args: [String: Any]) throws -> Any {
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
        default: throw ToolError("FS_IO_ERROR", "unknown fs method " + method)
        }
    }

    // MARK: Node fs routes

    func path(_ method: String, _ args: [String: Any]) throws -> Any {
        try gateway.withStore { _ in try pathLocked(method, args) }
    }

    private func pathLocked(_ method: String, _ args: [String: Any]) throws -> Any {
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

    /// The two executables the official tools spawn natively: rg (fs-search) and git reads
    /// (workspace-changes). Anything else is not a native process.
    func spawn(_ args: [String: Any]) -> [String: Any] {
        let argv = args["argv"] as? [String] ?? []
        let cwd = args["cwd"] as? String ?? ""
        let output: ProcessOutput = gateway.withStore { _ in
            switch args["tool"] as? String {
            case "rg": return search.run(Array(argv.dropFirst()), cwd: cwd)
            case "git":
                let env = (args["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
                return git.run(argv, cwd: cwd, env: env, stdin: Data(base64Encoded: args["stdin"] as? String ?? "") ?? Data())
            default: return ProcessOutput(exitCode: 127, stderr: Data("spawn refused\n".utf8))
            }
        }
        return ["exitCode": Int(output.exitCode), "stdout": output.stdout.base64EncodedString(),
                "stderr": output.stderr.base64EncodedString()]
    }

    // MARK: Images

    /// The `sharp` stub's three native steps; bytes travel as base64. Needs no project.
    static func image(_ method: String, _ args: [String: Any]) throws -> Any {
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
        default: throw ToolError("INVALID_IMAGE", "image " + method)
        }
    }

    static func describe(_ info: PathStat) -> [String: Any] { info.dictionary.merging(["type": info.type.rawValue]) { $1 } }
}
