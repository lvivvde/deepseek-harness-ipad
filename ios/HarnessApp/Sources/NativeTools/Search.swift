import Darwin
import Foundation
import NativeWorkspace

public struct ProcessOutput: Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

/// The two ripgrep invocations dsh-tool-fs-search makes (`--files` for glob, `--json` for grep),
/// answered from the native workspace so search needs no rg binary and no Linux. Walk order,
/// ignore rules, hidden files, binary handling and output follow rg 15 as packaged with the
/// official tools; the regex dialect is translated by `RustRegex`. Declared differences: files
/// are searched one at a time in path order (rg's order is unspecified), a file with a NUL
/// anywhere is skipped (rg may report matches that precede a NUL past its first 64 KiB read),
/// global git excludes are not read, and paths outside the workspace are refused.
public final class NativeSearch {
    let mount: Mount
    let busy: () -> Bool

    public init(workspace directory: String, mount: String, busy: @escaping () -> Bool) {
        self.mount = Mount(processRoot: Array(mount.utf8), directory: directory)
        self.busy = busy
    }

    struct Options {
        var files = false, json = false, noIgnore = false, hidden = false, sortModified = false
        var regexp: String?
        var globs: [String] = []
        var paths: [String] = []
    }

    struct Failure: Error { let message: String }

    public func run(_ arguments: [String], cwd: String) -> ProcessOutput {
        do {
            let options = try Self.parse(arguments)
            guard !busy() else { throw Failure(message: "WORKSPACE_LEASE_BUSY: a Linux command holds the workspace") }
            guard case .found(let cwdComponents) = try mount.resolve(cwd, followLeaf: true) else {
                throw Failure(message: "\(cwd): IO error for operation on \(cwd): No such file or directory (os error 2)")
            }
            var run = Run(mount: mount, options: options, cwd: cwdComponents)
            run.overrides = try IgnoreRules(base: cwdComponents, lines: options.globs, strict: true)
            if let pattern = options.regexp { run.regex = try Self.compile(pattern) }
            return run.execute()
        } catch let failure as Failure {
            return ProcessOutput(exitCode: 2, stderr: Data("rg: \(failure.message)\n".utf8))
        } catch let invalid as IgnoreGlob.Invalid {
            return ProcessOutput(exitCode: 2, stderr: Data("rg: error parsing glob '\(invalid.glob)': \(invalid.message)\n".utf8))
        } catch let invalid as RustRegex.ParseError where invalid.message == RustRegex.newlineMessage {
            return ProcessOutput(exitCode: 2, stderr: Data("rg: \(invalid.message)\n".utf8))
        } catch let invalid as RustRegex.ParseError {
            return ProcessOutput(exitCode: 2, stderr: Data("rg: regex parse error:\n    \(pattern(in: arguments))\nerror: \(invalid.message)\n".utf8))
        } catch let error as ToolError {
            return ProcessOutput(exitCode: 2, stderr: Data("rg: \(error)\n".utf8))
        } catch {
            return ProcessOutput(exitCode: 2, stderr: Data("rg: \(error)\n".utf8))
        }
    }

    private func pattern(in arguments: [String]) -> String {
        arguments.first { $0.hasPrefix("--regexp=") }.map { String($0.dropFirst("--regexp=".count)) } ?? ""
    }

    static func compile(_ pattern: String) throws -> NSRegularExpression {
        let translated = try RustRegex.translate(pattern)
        do { return try NSRegularExpression(pattern: translated, options: [.useUnixLineSeparators]) } catch {
            throw RustRegex.ParseError(message: "the pattern could not be compiled")
        }
    }

    /// Only the flags the official tools pass are accepted; anything else is a refusal, never a
    /// silently different search.
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(), rest = arguments[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            switch argument {
            case "--": options.paths = Array(rest); rest = []
            case "--no-config": break
            case "--files": options.files = true
            case "--json": options.json = true
            case "--no-ignore": options.noIgnore = true
            case "--hidden": options.hidden = true
            case "--sort=modified": options.sortModified = true
            case _ where argument.hasPrefix("--regexp="): options.regexp = String(argument.dropFirst("--regexp=".count))
            case _ where argument.hasPrefix("--glob="): options.globs.append(String(argument.dropFirst("--glob=".count)))
            default: throw Failure(message: "the native search does not support the argument \(argument)")
            }
        }
        guard options.paths.count <= 1 else { throw Failure(message: "the native search takes at most one path") }
        guard options.files != (options.regexp != nil), options.files || options.json else {
            throw Failure(message: "the native search runs only --files or --json --regexp")
        }
        return options
    }
}

/// Ignore files of one directory, in the `ignore` crate's precedence order.
struct DirectoryIgnores {
    var custom: IgnoreRules?
    var ignore: IgnoreRules?
    var git: IgnoreRules?
    var exclude: IgnoreRules?
    var hasGit = false
}

struct Run {
    let mount: Mount
    let options: Options
    let cwd: [[UInt8]]
    var overrides: IgnoreRules?
    var regex: NSRegularExpression?
    var stdout = Data()
    var errors: [String] = []
    var matched = false
    var listed: [(path: [UInt8], modified: timespec)] = []

    typealias Options = NativeSearch.Options

    init(mount: Mount, options: Options, cwd: [[UInt8]]) {
        self.mount = mount; self.options = options; self.cwd = cwd
    }

    mutating func execute() -> ProcessOutput {
        if let path = options.paths.first { search(root: path) } else { search(root: nil) }
        if options.files {
            for entry in listed.enumerated().sorted(by: { a, b in
                let x = a.element.modified, y = b.element.modified
                return (x.tv_sec, x.tv_nsec, a.offset) < (y.tv_sec, y.tv_nsec, b.offset)
            }) {
                stdout.append(contentsOf: entry.element.path); stdout.append(0x0A)
            }
            matched = !listed.isEmpty
        }
        let stderr = Data(errors.map { "rg: \($0)\n" }.joined().utf8)
        return ProcessOutput(exitCode: errors.isEmpty ? (matched ? 0 : 1) : 2, stdout: stdout, stderr: stderr)
    }

    mutating func search(root argument: String?) {
        let processPath: String
        var prefix: [UInt8] = []
        if let argument {
            processPath = argument.hasPrefix("/") ? argument : mount.processPath(cwd) + "/" + argument
            prefix = Array(argument.utf8)
            while prefix.count > 1 && prefix.last == 0x2F { prefix.removeLast() }
        } else {
            processPath = mount.processPath(cwd)
        }
        let label = argument ?? "."
        do {
            guard case .found(let components) = try mount.resolve(processPath, followLeaf: true),
                  let info = try mount.lstat(components) else {
                errors.append("\(label): IO error for operation on \(label): No such file or directory (os error 2)"); return
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                var stack: [DirectoryIgnores] = []
                if !options.noIgnore {
                    for depth in 0...components.count {
                        let directory = try mount.openDirectory(components.prefix(depth))
                        defer { close(directory) }
                        stack.append(Self.ignores(directory, base: Array(components.prefix(depth))))
                    }
                }
                let directory = try mount.openDirectory(components)
                defer { close(directory) }
                try walk(directory, components: components, display: prefix, stack: stack)
            case S_IFREG:
                // An explicit file is searched whatever the ignore rules and globs say, except the
                // store's own files, which do not exist for the tools.
                do { try mount.relative(components).validate() } catch {
                    errors.append("\(label): IO error for operation on \(label): No such file or directory (os error 2)"); return
                }
                let parent = try mount.openDirectory(components.dropLast())
                defer { close(parent) }
                visit(parent, name: components.last!, display: argument == nil ? components.last! : prefix, info: info, explicit: true)
            default:
                break
            }
        } catch let error as ToolError {
            errors.append("\(label): \(error)")
        } catch {
            errors.append("\(label): \(error)")
        }
    }

    mutating func walk(_ directory: Int32, components: [[UInt8]], display: [UInt8], stack: [DirectoryIgnores]) throws {
        for name in try names(directory).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            if components.isEmpty && name == WorkspaceFiles.identity { continue }
            if name.starts(with: WorkspaceFiles.temporaryPrefix) { continue }
            var info = stat()
            guard withCName(name, { fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { continue }
            let child = components + [name]
            let childDisplay = display.isEmpty ? name : display + (display.last == 0x2F ? [] : [0x2F]) + name
            if ignored(child, display: childDisplay, name: name, isDirectory: type == S_IFDIR, stack: stack) { continue }
            if type == S_IFDIR {
                let next = withCName(name) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard next >= 0 else { continue }
                defer { close(next) }
                let nested = options.noIgnore ? stack : stack + [Self.ignores(next, base: child)]
                try walk(next, components: child, display: childDisplay, stack: nested)
            } else {
                visit(directory, name: name, display: childDisplay, info: info, explicit: false)
            }
        }
    }

    func names(_ directory: Int32) throws -> [[UInt8]] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else { throw ToolError("FS_IO_ERROR", "fdopendir: \(errno)") }
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

    /// The `ignore` crate's decision for one walked entry: overrides first, then ignore files,
    /// then hidden names.
    func ignored(_ path: [[UInt8]], display: [UInt8], name: [UInt8], isDirectory: Bool, stack: [DirectoryIgnores]) -> Bool {
        if let overrides, !overrides.isEmpty {
            var result: IgnoreMatch
            if path.starts(with: cwd) {
                result = overrides.match(path, isDirectory: isDirectory)
            } else {
                var text = String(decoding: display, as: UTF8.self)
                while text.hasPrefix("./") { text.removeFirst(2) }
                result = overrides.match(text: text, isDirectory: isDirectory)
            }
            // Override globs are whitelists unless negated, the reverse of an ignore file.
            switch result {
            case .ignore: return false
            case .whitelist: return true
            case .none: if overrides.hasOverrideWhitelist && !isDirectory { return true }
            }
        }
        var whitelisted = false
        if !options.noIgnore {
            switch Self.matchIgnores(path, isDirectory: isDirectory, stack: stack) {
            case .ignore: return true
            case .whitelist: whitelisted = true
            case .none: break
            }
        }
        return !whitelisted && !options.hidden && name.first == 0x2E
    }

    static func matchIgnores(_ path: [[UInt8]], isDirectory: Bool, stack: [DirectoryIgnores]) -> IgnoreMatch {
        let anyGit = stack.contains { $0.hasGit }
        var custom = IgnoreMatch.none, ignore = IgnoreMatch.none, git = IgnoreMatch.none, exclude = IgnoreMatch.none
        var sawGit = false
        for level in stack.reversed() {
            if custom == .none, let rules = level.custom { custom = rules.match(path, isDirectory: isDirectory) }
            if ignore == .none, let rules = level.ignore { ignore = rules.match(path, isDirectory: isDirectory) }
            if anyGit && !sawGit && git == .none, let rules = level.git { git = rules.match(path, isDirectory: isDirectory) }
            if anyGit && !sawGit && exclude == .none, let rules = level.exclude { exclude = rules.match(path, isDirectory: isDirectory) }
            sawGit = sawGit || level.hasGit
        }
        return [custom, ignore, git, exclude].first { $0 != .none } ?? .none
    }

    static func ignores(_ directory: Int32, base: [[UInt8]]) -> DirectoryIgnores {
        func rules(_ name: String, in parent: Int32 = directory) -> IgnoreRules? {
            guard let data = readSmall(parent, Array(name.utf8)) else { return nil }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
            return try? IgnoreRules(base: base, lines: lines, strict: false)
        }
        var result = DirectoryIgnores(custom: rules(".rgignore"), ignore: rules(".ignore"), git: rules(".gitignore"))
        var info = stat()
        result.hasGit = withCName(Array(".git".utf8)) { fstatat(directory, $0, &info, 0) } == 0
        if result.hasGit && info.st_mode & S_IFMT == S_IFDIR {
            let info = withCName(Array(".git/info".utf8)) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if info >= 0 { defer { close(info) }; result.exclude = rules("exclude", in: info) }
        }
        return result
    }

    static func readSmall(_ directory: Int32, _ name: [UInt8], limit: Int = 8 << 20) -> Data? {
        let descriptor = withCName(name) { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return readAll(descriptor, limit: limit)
    }

    static func readAll(_ descriptor: Int32, limit: Int) -> Data? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit else { return nil }
        var data = Data(count: Int(info.st_size)), filled = 0
        while filled < data.count {
            let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + filled, $0.count - filled) }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            filled += count
        }
        return data.prefix(filled)
    }

    mutating func visit(_ directory: Int32, name: [UInt8], display: [UInt8], info: stat, explicit: Bool) {
        if options.files {
            listed.append((display, info.st_mtimespec))
            return
        }
        guard let regex else { return }
        let descriptor = withCName(name) { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else {
            errors.append("\(String(decoding: display, as: UTF8.self)): Permission denied (os error \(errno))"); return
        }
        defer { close(descriptor) }
        guard let data = Self.readAll(descriptor, limit: Int.max) else { return }
        for record in Grep.matches(in: data, explicit: explicit, regex: regex) {
            matched = true
            stdout.append(Grep.record(path: display, record))
            stdout.append(0x0A)
        }
    }
}

enum Grep {
    struct Match: Equatable {
        let lineNumber: Int
        let offset: Int
        /// The line with its terminator, as rg prints it.
        let line: [UInt8]
    }

    /// Matching lines of one file. Implicit files with a NUL are binary and skipped; an explicit
    /// file has NULs read as line terminators, as rg's convert mode does.
    static func matches(in raw: Data, explicit: Bool, regex: NSRegularExpression) -> [Match] {
        var bytes = decode(raw)
        if bytes.contains(0) {
            guard explicit else { return [] }
            bytes = bytes.map { $0 == 0 ? 0x0A : $0 }
        }
        var found: [Match] = []
        var start = 0, number = 0
        // One UTF-16 copy of a valid file; each line is matched as a region of it.
        let whole = NSString(bytes: bytes, length: bytes.count, encoding: String.Encoding.utf8.rawValue).map { $0 as String }
        var unit = 0
        while start < bytes.count {
            number += 1
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
            let line = Array(bytes[start..<end])
            let isMatch: Bool
            if let whole {
                let length = String(decoding: line, as: UTF8.self).utf16.count
                isMatch = regex.firstMatch(in: whole, options: [], range: NSRange(location: unit, length: length)) != nil
                unit += length + 1
            } else {
                let lossy = String(decoding: line, as: UTF8.self)
                isMatch = regex.firstMatch(in: lossy, options: [], range: NSRange(lossy.startIndex..., in: lossy)) != nil
            }
            if isMatch {
                found.append(Match(lineNumber: number, offset: start, line: end < bytes.count ? line + [0x0A] : line))
            }
            start = end + 1
        }
        return found
    }

    /// rg's BOM sniffing: UTF-8 BOMs are dropped and UTF-16 is transcoded to UTF-8.
    static func decode(_ raw: Data) -> [UInt8] {
        let bytes = [UInt8](raw)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return Array(bytes.dropFirst(3)) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let little = bytes[0] == 0xFF
            var units: [UInt16] = []
            var index = 2
            while index + 1 < bytes.count {
                units.append(little ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                index += 2
            }
            return Array(String(decoding: units, as: UTF16.self).utf8)
        }
        return bytes
    }

    static func record(path: [UInt8], _ match: Match) -> Data {
        func field(_ bytes: [UInt8]) -> [String: String] {
            if let text = String(bytes: bytes, encoding: .utf8) { return ["text": text] }
            return ["bytes": Data(bytes).base64EncodedString()]
        }
        let object: [String: Any] = [
            "type": "match",
            "data": ["path": field(path), "lines": field(match.line), "line_number": match.lineNumber,
                     "absolute_offset": match.offset, "submatches": [] as [Any]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }
}
