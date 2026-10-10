import Foundation
import XCTest
import HarnessCandidate
import HarnessHost
import LinuxPlugin

/// The candidate's single native authority, seen through the operations the Worker bridge sends.
/// Linux runs on a fake machine whose guest reads the 9P share it was booted with.
final class CandidateHostTests: XCTestCase {
    final class FakeMachine: GuestMachine, GuestRPC, @unchecked Sendable {
        let lock = NSLock()
        var share: String?
        var boots = 0, stops = 0
        var executed: [[String: Any]] = []
        /// What the mount check reads; nil reads the real sentinel through the share.
        var mountCheckAnswer: String?
        var exitOnStop = true
        var onExit: ((Int32?) -> Void)?
        private var ended = false

        var rpc: GuestRPC { self }
        var exited: Bool { lock.lock(); defer { lock.unlock() }; return ended }

        func boot(workspace: String) throws {
            lock.lock(); defer { lock.unlock() }
            boots += 1; share = workspace
        }

        func stop() {
            lock.lock(); stops += 1; let first = !ended; ended = true; lock.unlock()
            if first && exitOnStop { onExit?(9) }
        }

        func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            guard let share, !ended else { throw GuestRPCError.unreachable("down") }
            let identity = (try? String(contentsOfFile: share + "/.plan500-identity", encoding: .utf8)) ?? ""
            switch route {
            case "/ready":
                return ["protocol": 1, "projectId": identity, "mount": "9p", "workspaceReadOnly": true, "cgroupKill": true]
            case "/bind": return ["bound": true]
            case "/execute":
                let request = body ?? [:]
                executed.append(request)
                guard request["projectId"] as? String == identity else { throw GuestRPCError.refused("PROJECT_REFUSED") }
                let argv = request["argv"] as? [String] ?? []
                if argv.last == "cat /workspace/.dsh-mount-check" {
                    let text = mountCheckAnswer ?? ((try? String(contentsOfFile: share + "/.dsh-mount-check", encoding: .utf8)) ?? "")
                    return ["code": 0, "stdout": text, "stderr": "", "writerQuiescent": true]
                }
                return ["code": 0, "stdout": "ran " + (argv.last ?? ""), "stderr": "", "writerQuiescent": !(argv.last ?? "").hasPrefix("detach")]
            case "/revoke": return ["revoked": true]
            default: return [:]
            }
        }
    }

    var root = ""
    var machine: FakeMachine!

    override func setUpWithError() throws {
        root = try realpath(NSTemporaryDirectory()) + "/candidate-host-" + UUID().uuidString
        machine = FakeMachine()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func realpath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw CandidateError("REALPATH") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func host() throws -> CandidateHost {
        try CandidateHost(registry: ProjectRegistry(root: root), machine: machine, availability: .available,
                          gitScripts: Self.gitScripts(), pollInterval: 0.01)
    }

    static func gitScripts() throws -> [(name: String, source: String)] {
        let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../runtime/prototypes/plan500-ipad/web").standardized
        return try CandidateHost.gitScriptNames.map { ($0, try String(contentsOf: web.appendingPathComponent($0), encoding: .utf8)) }
    }

    func open(_ host: CandidateHost, _ name: String, plugin: Bool) -> [String: Any] {
        let created = host.handle(["operation": "project-create", "name": name, "pluginEnabled": plugin])
        let id = (created["project"] as? [String: Any])?["id"] as? String ?? ""
        return host.handle(["operation": "project-open", "id": id])
    }

    func id(_ opened: [String: Any]) -> String { (opened["project"] as? [String: Any])?["id"] as? String ?? "" }

    func execute(_ host: CandidateHost, _ id: String, cwd: String, _ command: String = "pwd") -> [String: Any] {
        host.handle(["operation": "execute", "operationId": id, "command": command, "cwd": cwd, "timeoutMs": 5000, "trigger": "shell"])
    }

    func testANativeProjectReadsAndWritesTheRealWorkspace() throws {
        let host = try host()
        let opened = open(host, "演示", plugin: false)
        XCTAssertEqual((opened["project"] as? [String: Any])?["phase"] as? String, "DISABLED")
        let data = Data("你好\n".utf8).base64EncodedString()
        let written = host.handle(["operation": "fs", "method": "write",
                                   "args": ["path": "/dsh/workspace/演示/a.txt", "data": data, "expected": ["kind": "createIfAbsent"]]])
        XCTAssertEqual((written["value"] as? [String: Any])?["operation"] as? String, "create", "\(written)")
        let registry = try ProjectRegistry(root: root)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertEqual(FileManager.default.contents(atPath: registry.workspace(project) + "/a.txt"), Data("你好\n".utf8))
        let read = host.handle(["operation": "path", "method": "readFile", "args": ["path": "/dsh/workspace/演示/a.txt"]])
        XCTAssertEqual(read["value"] as? String, data)
        let search = host.handle(["operation": "spawn", "args": ["tool": "rg", "argv": ["rg", "--files"], "cwd": "/dsh/workspace/演示"]])
        let stdout = ((search["value"] as? [String: Any])?["stdout"] as? String).flatMap { Data(base64Encoded: $0) }
        XCTAssertEqual(stdout.map { String(decoding: $0, as: UTF8.self) }, "a.txt\n")
    }

    func testToolFailuresAndRefusalsKeepTheirCodes() throws {
        let host = try host()
        _ = open(host, "a", plugin: false)
        let missing = host.handle(["operation": "fs", "method": "read", "args": ["path": "/dsh/workspace/a/none"]])
        XCTAssertEqual((missing["failure"] as? [String: Any])?["code"] as? String, "FS_NOT_FOUND")
        let other = host.handle(["operation": "fs", "method": "read", "args": ["path": "/dsh/workspace/closed/x"]])
        XCTAssertEqual((other["failure"] as? [String: Any])?["code"] as? String, "FS_NOT_FOUND")
        XCTAssertEqual(host.handle(["operation": "nope"])["error"] as? String, "OPERATION_REFUSED")
        XCTAssertEqual(host.handle(["operation": "project-create", "name": "a", "pluginEnabled": false])["error"] as? String,
                       "PROJECT_NAME_TAKEN")
        XCTAssertEqual(host.handle(["operation": "project-open", "id": UUID().uuidString])["error"] as? String, "PROJECT_UNKNOWN")
    }

    func testShellOnANativeProjectIsRefusedWithoutStartingLinux() throws {
        let host = try host()
        _ = open(host, "notes", plugin: false)
        let answer = execute(host, "op-1", cwd: "/dsh/workspace/notes")
        XCTAssertEqual(answer["status"] as? String, "REFUSED")
        XCTAssertEqual(answer["reason"] as? String, LinuxPlugin.notEnabledCode)
        XCTAssertEqual(machine.boots, 0)
    }

    func testShellRunsInThePluginProjectsGuestDirectory() throws {
        let host = try host()
        let opened = open(host, "演示", plugin: true)
        let project = id(opened)
        let answer = execute(host, "op-1", cwd: "/dsh/workspace/演示/src/深", "ls")
        XCTAssertEqual(answer["status"] as? String, "COMPLETED", "\(answer)")
        XCTAssertEqual(answer["exitCode"] as? Int, 0)
        XCTAssertEqual(answer["stdout"] as? String, "ran ls")
        let request = try XCTUnwrap(machine.executed.last)
        XCTAssertEqual(request["cwd"] as? String, "/workspace/src/深")
        XCTAssertEqual(request["argv"] as? [String], ["/bin/sh", "-c", "ls"])
        XCTAssertEqual(request["projectId"] as? String, project)
        XCTAssertNotNil(request["lease"])
        XCTAssertEqual(machine.boots, 1)
        let workspace = try XCTUnwrap(machine.share)
        XCTAssertEqual(try String(contentsOfFile: workspace + "/.plan500-identity", encoding: .utf8), project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/.dsh-mount-check"))
        XCTAssertEqual(projectEntry(host, project)?["phase"] as? String, "READY")
        // A cwd outside every open project never reaches the guest.
        let outside = execute(host, "op-2", cwd: "/dsh/home")
        XCTAssertEqual(outside["reason"] as? String, "CWD_REFUSED")
        XCTAssertEqual(machine.executed.count, 2, "the mount check and op-1 only")
    }

    func testAnUnknownWriterIsShownAndReleasedOnlyWhenAsked() throws {
        let host = try host()
        let project = id(open(host, "p", plugin: true))
        XCTAssertEqual(execute(host, "op-1", cwd: "/dsh/workspace/p", "detach sleep 9")["status"] as? String, "WRITER_UNKNOWN")
        XCTAssertEqual(projectEntry(host, project)?["writerUnknown"] as? Bool, true)
        XCTAssertEqual(execute(host, "op-2", cwd: "/dsh/workspace/p")["status"] as? String, "REFUSED", "the lease stays held")
        XCTAssertEqual(host.handle(["operation": "writer-release", "id": project])["status"] as? String, "RELEASED")
        XCTAssertEqual(projectEntry(host, project)?["writerUnknown"] as? Bool, false)
        XCTAssertEqual(execute(host, "op-3", cwd: "/dsh/workspace/p")["status"] as? String, "COMPLETED")
    }

    func testTheDeclarationShowsWhereTheCandidateFallsShortOfTheFormalScope() throws {
        let host = try host()
        let project = id(open(host, "p", plugin: true))
        XCTAssertEqual(execute(host, "op-1", cwd: "/dsh/workspace/p")["status"] as? String, "COMPLETED")
        let declaration = try XCTUnwrap(projectEntry(host, project)?["capabilities"] as? [String: Any])
        let items = Dictionary(uniqueKeysWithValues: (declaration["items"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0) })
        XCTAssertEqual(items["shell"]?["available"] as? Bool, true)
        XCTAssertNil(items["shell"]?["reason"] as? String)
        XCTAssertEqual(items["hook.command"]?["available"] as? Bool, false)
        XCTAssertEqual(items["hook.command"]?["reason"] as? String, "CANDIDATE_NOT_WIRED")
        XCTAssertEqual(items["git.write"]?["reason"] as? String, "SHELL_ONLY")
        XCTAssertEqual(items["subprocess"]?["reason"] as? String, "BASH_C_ONLY")
        XCTAssertEqual(items["terminal"]?["path"] as? String, "unsupported")
        XCTAssertEqual(items["terminal"]?["reason"] as? String, "TERMINAL_UNSUPPORTED")
        let workspace = try XCTUnwrap(machine.share)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: workspace + "/.plan500-identity")[.posixPermissions] as? Int, 0o644)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace).filter { $0.hasPrefix(".dsh-tmp-") }, [])
    }

    func testOnlyTheFirstPluginProjectBindsLinux() throws {
        let host = try host()
        _ = open(host, "first", plugin: true)
        XCTAssertEqual(execute(host, "op-1", cwd: "/dsh/workspace/first")["status"] as? String, "COMPLETED")
        _ = open(host, "second", plugin: true)
        let answer = execute(host, "op-2", cwd: "/dsh/workspace/second")
        XCTAssertEqual(answer["reason"] as? String, LinuxPlugin.boundToOtherProjectCode)
        XCTAssertEqual(machine.boots, 1)
    }

    func testAFailedMountCheckFailsPreparationAndStopsTheVM() throws {
        machine.mountCheckAnswer = "someone-elses-share"
        let host = try host()
        let project = id(open(host, "p", plugin: true))
        let answer = execute(host, "op-1", cwd: "/dsh/workspace/p")
        XCTAssertEqual(answer["reason"] as? String, LinuxPlugin.prepareFailedCode)
        XCTAssertEqual(machine.stops, 1)
        XCTAssertEqual(projectEntry(host, project)?["phase"] as? String, "FAILED")
        let diagnostic = host.handle(["operation": "status"])["diagnostic"] as? [String: Any]
        XCTAssertEqual(diagnostic?["code"] as? String, LinuxPlugin.prepareFailedCode)
        XCTAssertEqual(diagnostic?["cause"] as? String, MountCheck.failure, "the stop's own exit does not replace the cause")
    }

    func testAVMExitAfterReadyFailsLinuxForTheRestOfTheProcess() throws {
        let host = try host()
        let project = id(open(host, "p", plugin: true))
        XCTAssertEqual(execute(host, "op-1", cwd: "/dsh/workspace/p")["status"] as? String, "COMPLETED")
        machine.exitOnStop = false
        machine.stop()
        machine.onExit?(1)
        XCTAssertEqual(execute(host, "op-2", cwd: "/dsh/workspace/p")["reason"] as? String, LinuxPlugin.vmExitedCode)
        XCTAssertEqual(projectEntry(host, project)?["phase"] as? String, "FAILED")
    }

    func testShutdownStopsTheVMWithoutRecordingAFailure() throws {
        let host = try host()
        _ = open(host, "p", plugin: true)
        XCTAssertEqual(execute(host, "op-1", cwd: "/dsh/workspace/p")["status"] as? String, "COMPLETED")
        host.shutdown()
        XCTAssertEqual(machine.stops, 1)
        XCTAssertNil(host.handle(["operation": "status"])["diagnostic"] as? [String: Any], "quitting is not a Linux failure")
    }

    func testACancelBeforeTheCommandArrivesStopsItBeforeDispatch() throws {
        let host = try host()
        _ = open(host, "p", plugin: true)
        XCTAssertEqual(host.handle(["operation": "cancel", "operationId": "op-1"])["status"] as? String, "CANCELLED_BEFORE_DISPATCH")
        XCTAssertEqual(execute(host, "op-1", cwd: "/dsh/workspace/p")["status"] as? String, "CANCELLED_BEFORE_DISPATCH")
        XCTAssertFalse(machine.executed.contains { $0["id"] as? String == "op-1" })
    }

    func testTheCheckpointHoldsOnlyTheWorkerHome() throws {
        let host = try host()
        XCTAssertTrue(host.handle(["operation": "restore"])["snapshot"] is NSNull)
        let leaking: [String: Any] = ["formatVersion": 1, "files": [["path": "/dsh/workspace/p/a.txt", "data": ""]], "directories": []]
        XCTAssertEqual(host.handle(["operation": "checkpoint", "snapshot": leaking])["error"] as? String, "HOME_ONLY_CHECKPOINT")
        let home: [String: Any] = ["formatVersion": 1, "files": [["path": "/dsh/home/.config/a", "data": "eA=="]],
                                   "directories": [["path": "/dsh/home/.config"]]]
        XCTAssertEqual(host.handle(["operation": "checkpoint", "snapshot": home])["durable"] as? Bool, true)
        let restored = try self.host().handle(["operation": "restore"])["snapshot"] as? [String: Any]
        XCTAssertEqual((restored?["files"] as? [[String: Any]])?.first?["path"] as? String, "/dsh/home/.config/a")
        let attributes = try FileManager.default.attributesOfItem(atPath: root + "/worker-home.json")
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTheCheckpointNeverHoldsTheWorkerCredentials() throws {
        let host = try host()
        for path in ["/dsh/home/.credentials.yaml", "/dsh/home/.credentials.yaml.tmp"] {
            let snapshot: [String: Any] = ["formatVersion": 1, "files": [["path": path, "data": "eA=="]], "directories": []]
            XCTAssertEqual(host.handle(["operation": "checkpoint", "snapshot": snapshot])["error"] as? String, "CREDENTIALS_NOT_CHECKPOINTED")
        }
        XCTAssertTrue(host.handle(["operation": "restore"])["snapshot"] is NSNull)
    }

    func projectEntry(_ host: CandidateHost, _ id: String) -> [String: Any]? {
        (host.handle(["operation": "projects"])["projects"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }
}
