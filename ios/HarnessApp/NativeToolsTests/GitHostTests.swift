import CryptoKit
import Darwin
import Foundation
import XCTest
import NativeWorkspace
@testable import NativeTools

/// Native git in JavaScriptCore over `NativePathSpace`, against /usr/bin/git on the same tree.
final class GitHostTests: XCTestCase {
    static let mount = "/dsh/workspace/演示"
    static let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../runtime/prototypes/plan500-ipad/web").standardized
    var root = "", workspace = "", scratch = ""
    var busy = false

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no /usr/bin/git")
        root = try realpath(NSTemporaryDirectory()) + "/native-git-host-" + UUID().uuidString
        workspace = root + "/workspace"; scratch = root + "/scratch"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        // APFS makes `git init` choose ignorecase; native git refuses such repositories (tested below).
        try git(["config", "core.ignorecase", "false"]); try git(["config", "core.precomposeunicode", "false"])
        try put("README.md", Data("# 演示\r\nline two\r\n".utf8))
        try put("src/中文/文件.md", Data("第一行\n第二行\n".utf8))
        try put("bin.dat", Data([0, 1, 2, 0xff, 0xfe, 0]))
        try put(".gitignore", Data("*.log\nbuild/\n".utf8))
        try put("tool.sh", Data("#!/bin/sh\necho hi\n".utf8), mode: 0o755)
        try FileManager.default.createSymbolicLink(atPath: workspace + "/link", withDestinationPath: "src/中文/文件.md")
        try git(["add", "-A"]); try git(["commit", "-q", "-m", "base"])
        // Uncommitted work: an edit, a large file, an ignored file, a rename and a deletion.
        try put("src/中文/文件.md", Data("第一行\n改过的第二行\n第三行\n".utf8))
        try put("large.txt", Data((0..<200_000).map { "row \($0)\n" }.joined().utf8))
        try put("debug.log", Data("ignored\n".utf8))
        try FileManager.default.moveItem(atPath: workspace + "/tool.sh", toPath: workspace + "/scripts-tool.sh")
        try FileManager.default.removeItem(atPath: workspace + "/bin.dat")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func realpath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw ToolError("realpath") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func put(_ path: String, _ data: Data, mode: Int = 0o644) throws {
        let full = workspace + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
        chmod(full, mode_t(mode))
    }

    @discardableResult
    func git(_ args: [String], env: [String: String] = [:], stdin: Data = Data()) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workspace)
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
                               "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
                               "GIT_COMMITTER_EMAIL": "t@example.invalid", "LC_ALL": "C"].merging(env) { $1 }
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(stdin); try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile(), err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    func host() throws -> (NativeGitHost, NativePathSpace) {
        let store = try WorkspaceStore(workspace: workspace, state: root + "/state")
        let paths = try NativePathSpace(files: NativeFileService(store: store, mount: Self.mount), scratch: scratch) { [unowned self] in busy }
        let scripts = try ["native-git-objects.js", "native-git-match.js", "native-git-xdiff.js", "native-git.js"].map {
            ($0, try String(contentsOf: Self.web.appendingPathComponent($0), encoding: .utf8))
        }
        return (try NativeGitHost(paths: paths, scripts: scripts, ceiling: "/dsh/workspace"), paths)
    }

    /// Path, mode, size and SHA-256 of every entry under `.git`.
    func gitTree() throws -> [String] {
        let base = workspace + "/.git"
        var out: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: base)!
        while let name = enumerator.nextObject() as? String {
            var info = stat()
            lstat(base + "/" + name, &info)
            let digest = info.st_mode & S_IFMT == S_IFREG
                ? SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: base + "/" + name))).map { String(format: "%02x", $0) }.joined() : ""
            out.append("\(name) \(info.st_mode) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(digest)")
        }
        return out.sorted()
    }

    /// The workspace-changes snapshot sequence, natively and with system git, on the same tree.
    func testSnapshotSequenceMatchesSystemGitAndNeverWritesTheRepository() throws {
        let (native, paths) = try host()
        var before = try gitTree()
        let scratchDir = try paths.mkdtemp("/dsh/tmp/dsh-workspace-changes-")
        XCTAssertTrue(scratchDir.hasPrefix("/dsh/tmp/dsh-workspace-changes-"))
        let real = scratch + "/" + (scratchDir as NSString).lastPathComponent
        try paths.mkdir(scratchDir + "/objects", recursive: true)
        try paths.mkdir(scratchDir + "/system/objects", recursive: true)
        try paths.writeFile(scratchDir + "/index", try paths.readFile(Self.mount + "/.git/index"), exclusive: true)
        try FileManager.default.copyItem(atPath: workspace + "/.git/index", toPath: real + "/system/index")
        let base = ["GIT_CONFIG_COUNT": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        let nativeEnv = base.merging(["GIT_INDEX_FILE": scratchDir + "/index", "GIT_OBJECT_DIRECTORY": scratchDir + "/objects",
                                      "GIT_ALTERNATE_OBJECT_DIRECTORIES": Self.mount + "/.git/objects"]) { $1 }
        let systemEnv = base.merging(["GIT_INDEX_FILE": real + "/system/index", "GIT_OBJECT_DIRECTORY": real + "/system/objects",
                                      "GIT_ALTERNATE_OBJECT_DIRECTORIES": workspace + "/.git/objects"]) { $1 }
        func both(_ args: [String], stdin: Data = Data(), file: StaticString = #filePath, line: UInt = #line) throws -> Data {
            let mine = native.run(["/usr/bin/git"] + args, cwd: Self.mount, env: nativeEnv, stdin: stdin)
            XCTAssertEqual(try gitTree(), before, "native \(args) changed .git", file: file, line: line)
            // System git freshens the mtimes of alternate objects it re-adds; only native runs are checked.
            let theirs = try git(args, env: systemEnv, stdin: stdin)
            before = try gitTree()
            XCTAssertEqual(mine.exitCode, theirs.exitCode, "\(args) stderr: \(String(decoding: mine.stderr, as: UTF8.self))", file: file, line: line)
            XCTAssertEqual(mine.stdout, theirs.stdout, "\(args)", file: file, line: line)
            return mine.stdout
        }
        // Discovery runs without the scratch variables, as GitRunner does.
        let top = native.run(["git", "rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-path", "objects"], cwd: Self.mount + "/src", env: base)
        XCTAssertEqual(top.exitCode, 0, String(decoding: top.stderr, as: UTF8.self))
        XCTAssertEqual(String(decoding: top.stdout, as: UTF8.self),
                       "\(Self.mount)\n\(Self.mount)/.git\n../.git/objects\n")
        _ = try both(["add", "--all", "--ignore-errors", "--", ".", ":(exclude)debug.log", ":(exclude).dsh-identity"])
        let tree = String(decoding: try both(["write-tree"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(tree.count, 40)
        let head = String(decoding: try git(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try both(["ls-tree", "-z", "-l", tree, "--", "src/中文/文件.md"])
        _ = try both(["diff-tree", "-r", "-M", "-z", "--numstat", head, tree])
        _ = try both(["ls-files", "-z", "--stage"])
        _ = try both(["check-ignore", "-z", "--stdin"], stdin: Data("debug.log\0build/x\0README.md\0".utf8))
        let blob = String(decoding: try git(["rev-parse", "\(tree):large.txt"], env: systemEnv).stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let large = try both(["cat-file", "blob", blob])
        XCTAssertEqual(large.count, try Data(contentsOf: URL(fileURLWithPath: workspace + "/large.txt")).count)
        // Commands outside the read-only set fail closed.
        let commit = native.run(["git", "commit", "-m", "x"], cwd: Self.mount, env: nativeEnv)
        XCTAssertEqual(commit.exitCode, 128)
        XCTAssertTrue(String(decoding: commit.stderr, as: UTF8.self).contains("native git: unsupported"))
        XCTAssertEqual(try gitTree(), before, "native git changed .git")
    }

    func testIgnorecaseRepositoriesFailClosed() throws {
        let (native, _) = try host()
        try git(["config", "core.ignorecase", "true"])
        let result = native.run(["git", "ls-files", "-z", "--stage"], cwd: Self.mount, env: [:])
        XCTAssertEqual(result.exitCode, 128)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "fatal: native git: unsupported: config core.ignorecase=true\n")
    }

    func testAnIndexInsideTheRepositoryIsRefusedAndLeavesItUnchanged() throws {
        let (native, _) = try host()
        let before = try gitTree()
        let result = native.run(["git", "add", "--all", "--ignore-errors"], cwd: Self.mount,
                                env: ["GIT_INDEX_FILE": Self.mount + "/.git/index", "GIT_OBJECT_DIRECTORY": Self.mount + "/.git/objects"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(try gitTree(), before)
    }

    func testPathSpaceIsReadOnlyOutsideTheScratchAndBusyUnderTheLease() throws {
        let (_, paths) = try host()
        func code(_ body: () throws -> Any?) -> String? {
            do { _ = try body(); return nil } catch let error as ToolError { return error.code } catch { return "\(error)" }
        }
        XCTAssertEqual(code { try paths.writeFile(Self.mount + "/new.txt", Data("x".utf8), exclusive: true) }, "EROFS")
        XCTAssertEqual(code { try paths.mkdir(Self.mount + "/dir", recursive: true) }, "EROFS")
        // Node's mkdir -p of a directory that already exists changes nothing, so it is allowed; a file is not.
        XCTAssertNil(code { try paths.mkdir(Self.mount, recursive: true) })
        XCTAssertNil(code { try paths.mkdir(Self.mount + "/src/中文", recursive: true) })
        XCTAssertEqual(code { try paths.mkdir(Self.mount + "/src", recursive: false) }, "EROFS")
        XCTAssertEqual(code { try paths.mkdir(Self.mount + "/README.md", recursive: true) }, "EEXIST")
        XCTAssertEqual(code { try paths.unlink(Self.mount + "/README.md") }, "EROFS")
        XCTAssertEqual(code { try paths.rm(Self.mount + "/src", recursive: true, force: true) }, "EROFS")
        XCTAssertEqual(code { try paths.writeFile("/dsh/home/x", Data(), exclusive: false) }, "ENOENT")
        XCTAssertEqual(code { try paths.lstat("/etc/hosts") }, "ENOENT")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/new.txt"))
        XCTAssertEqual(try paths.readdir("/dsh").map(\.name), ["tmp", "workspace"])
        XCTAssertEqual(try paths.readdir(Self.mount + "/src").map(\.name), ["中文"])
        XCTAssertEqual(try paths.readlink(Self.mount + "/link"), "src/中文/文件.md")
        XCTAssertEqual(try paths.realpath(Self.mount + "/link"), Self.mount + "/src/中文/文件.md")
        XCTAssertEqual(try paths.lstat(Self.mount + "/link").type, .symlink)
        XCTAssertEqual(try paths.stat(Self.mount + "/link").type, .file)
        // The store's own names are not part of the Worker's view.
        try put(".dsh-tmp-partial", Data("x".utf8))
        if !FileManager.default.fileExists(atPath: workspace + "/.dsh-identity") { try put(".dsh-identity", Data("id".utf8)) }
        XCTAssertFalse(try paths.readdir(Self.mount).map(\.name).contains { $0.hasPrefix(".dsh-") })
        XCTAssertEqual(code { try paths.lstat(Self.mount + "/.dsh-identity") }, "ENOENT")
        XCTAssertEqual(code { try paths.readFile(Self.mount + "/.dsh-tmp-partial") }, "ENOENT")
        busy = true
        XCTAssertEqual(code { try paths.readFile(Self.mount + "/README.md") }, "EBUSY")
    }

    func testTextCodecMatchesWhatwgReplacementAndFatalModes() throws {
        let (native, _) = try host()
        let context = native.context
        let probe = context.evaluateScript("""
        const lossy = new TextDecoder("utf-8");
        const fatal = new TextDecoder("utf-8", {fatal: true});
        let threw = false; try { fatal.decode(new Uint8Array([0xe4, 0xb8])); } catch (e) { threw = e instanceof TypeError; }
        JSON.stringify({
          round: lossy.decode(new TextEncoder().encode("中文 😀 a")),
          bad: lossy.decode(new Uint8Array([0x61, 0xf0, 0x9f, 0x98, 0x62, 0xed, 0xa0, 0x80, 0xc0])),
          bom: lossy.decode(new Uint8Array([0xef, 0xbb, 0xbf, 0x41])),
          sub: lossy.decode(new TextEncoder().encode("xx中").subarray(2)),
          threw })
        """)!.toString()!
        let parsed = try JSONSerialization.jsonObject(with: Data(probe.utf8)) as! [String: Any]
        XCTAssertEqual(parsed["round"] as? String, "中文 😀 a")
        XCTAssertEqual(parsed["bad"] as? String, "a\u{FFFD}b\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}")
        XCTAssertEqual(parsed["bom"] as? String, "A")
        XCTAssertEqual(parsed["sub"] as? String, "中")
        XCTAssertEqual(parsed["threw"] as? Bool, true)
    }
}
