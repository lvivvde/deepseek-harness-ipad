import CryptoKit
import Foundation
import XCTest
import HarnessCandidate

/// The old App's full backup brought into the candidate: projects become plugin-enabled candidate
/// projects, the old official home reaches the Worker at its next restore, and nothing repeats.
final class BackupImportTests: XCTestCase {
    var root = ""
    var inbox = ""
    var archive: String { inbox + "/HarnessBackup.tar" }
    var checksum: String { archive + ".sha256" }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "candidate-import-" + UUID().uuidString
        inbox = root + "-inbox"
        try FileManager.default.createDirectory(atPath: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for path in [root, inbox] {
            if let walker = FileManager.default.enumerator(atPath: path) {
                for case let child as String in walker { chmod(path + "/" + child, 0o755) }
            }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func host() throws -> CandidateHost {
        try CandidateHost(registry: ProjectRegistry(root: root), machine: CandidateHostTests.FakeMachine(), availability: .available,
                          gitScripts: CandidateHostTests.gitScripts(), pollInterval: 0.01)
    }

    let log = "{\"cwd\":\"/root/projects/demo\",\"id\":\"s-1\",\"type\":\"session\",\"version\":4}\n{\"type\":\"user\",\"text\":\"hi\"}\n"

    /// One old project with a file and a session, an official config and a credential.
    func writeBackup(project: String = "demo", projectMode: Int = 0o755) throws {
        var tar = Tar()
        tar.file(".harness-layout-version", "1\n")
        tar.directory("projects"); tar.directory("projects/" + project, mode: projectMode)
        tar.file("projects/\(project)/a.txt", "old bytes\n")
        tar.directory(".dsh"); tar.directory(".dsh/sessions"); tar.directory(".dsh/sessions/--root-projects-demo--")
        tar.directory(".dsh/sessions/--root-projects-demo--/s-1")
        tar.file(".dsh/sessions/--root-projects-demo--/s-1/session.v4.jsonl", log)
        tar.file(".dsh/config.yaml", "model: x\n")
        tar.file(".dsh/.credentials.yaml", "key: secret\n", mode: 0o600)
        let bytes = tar.finish()
        try bytes.write(to: URL(fileURLWithPath: archive))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try Data((digest + "  HarnessBackup.tar\n").utf8).write(to: URL(fileURLWithPath: checksum))
    }

    func homeFiles(_ restored: [String: Any]) -> [String: String] {
        let files = (restored["snapshot"] as? [String: Any])?["files"] as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for file in files {
            let bytes = Data(base64Encoded: file["base64"] as? String ?? "") ?? Data()
            out[file["path"] as? String ?? ""] = String(decoding: bytes, as: UTF8.self)
        }
        return out
    }

    func testABackupBecomesPluginProjectsAndTheOldHome() throws {
        try writeBackup()
        let host = try host()
        let imported = host.importBackup(archive: archive, checksum: checksum)
        XCTAssertNil(imported["error"], "\(imported)")
        XCTAssertEqual(imported["projects"] as? [String], ["demo"])
        XCTAssertEqual(imported["sessionsMoved"] as? Int, 1)
        XCTAssertEqual(imported["credentialsExcluded"] as? Int, 1)
        XCTAssertEqual(imported["alreadyImported"] as? Bool, false)

        let registry = try ProjectRegistry(root: root)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertEqual(project.name, "demo")
        XCTAssertTrue(project.pluginEnabled)
        XCTAssertEqual(try String(contentsOfFile: registry.workspace(project) + "/a.txt", encoding: .utf8), "old bytes\n")

        let home = homeFiles(host.handle(["operation": "restore"]))
        let session = try XCTUnwrap(home["/dsh/home/sessions/--dsh-workspace-demo--/s-1/session.v4.jsonl"], "\(home.keys)")
        XCTAssertTrue(session.contains("\"cwd\":\"/dsh/workspace/demo\""))
        XCTAssertEqual(home["/dsh/home/config.yaml"], "model: x\n")
        XCTAssertNil(home["/dsh/home/.credentials.yaml"])
        XCTAssertEqual(host.handle(["operation": "status"])["session"].flatMap { ($0 as? [String: Any])?["phase"] as? String }, "UNSAVED")

        let again = try self.host().importBackup(archive: archive, checksum: checksum)
        XCTAssertEqual(again["alreadyImported"] as? Bool, true)
        XCTAssertEqual(try ProjectRegistry(root: root).projects.count, 1)
    }

    /// The old project directory's own mode never reaches the workspace root: the guest's unleased
    /// reader must traverse it for the mount check.
    func testAPrivateOldProjectStillGetsAWorkspaceTheGuestCanTraverse() throws {
        try writeBackup(projectMode: 0o700)
        XCTAssertNil(try host().importBackup(archive: archive, checksum: checksum)["error"])
        let registry = try ProjectRegistry(root: root)
        let info = try FileManager.default.attributesOfItem(atPath: registry.workspace(try XCTUnwrap(registry.projects.first)))
        XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    /// Once the Worker saved a home holding the import, the import is never merged again, so a file
    /// the user deleted afterwards stays deleted.
    func testASavedHomeTakesTheImportOnlyOnce() throws {
        try writeBackup()
        let host = try host()
        XCTAssertNil(host.importBackup(archive: archive, checksum: checksum)["error"])
        let restored = host.handle(["operation": "restore"])
        let worker = restored["worker"] as? String ?? ""
        let began = host.handle(["operation": "checkpoint-begin", "worker": worker, "revision": 1])
        let empty: [String: Any] = ["formatVersion": 1, "directories": [], "files": []]
        let saved = host.handle(["operation": "checkpoint", "worker": worker, "revision": 1,
                                 "capture": began["capture"] as? String ?? "", "snapshot": empty])
        XCTAssertEqual(saved["durable"] as? Bool, true, "\(saved)")
        XCTAssertEqual(homeFiles(try self.host().handle(["operation": "restore"])), [:])
    }

    /// A crash after the workspace moved but before its record and `.adopted`: the next run finishes
    /// the same project instead of failing or making a second one.
    func testAnInterruptedImportFinishesTheSameProject() throws {
        try writeBackup()
        XCTAssertNil(try host().importBackup(archive: archive, checksum: checksum)["error"])
        let project = try XCTUnwrap(try ProjectRegistry(root: root).projects.first)
        let migration = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: root + "/migrations").first { !$0.hasPrefix(".") })
        try FileManager.default.removeItem(atPath: root + "/migrations/" + migration + "/.adopted")
        try FileManager.default.removeItem(atPath: root + "/projects/" + project.id + "/project.json")

        let resumed = try host().importBackup(archive: archive, checksum: checksum)
        XCTAssertNil(resumed["error"], "\(resumed)")
        XCTAssertEqual(resumed["alreadyImported"] as? Bool, false)
        let registry = try ProjectRegistry(root: root)
        XCTAssertEqual(registry.projects, [project])
        XCTAssertEqual(try String(contentsOfFile: registry.workspace(project) + "/a.txt", encoding: .utf8), "old bytes\n")
    }

    func testANameTheCandidateHoldsRefusesTheWholeImport() throws {
        try writeBackup()
        let host = try host()
        _ = host.handle(["operation": "project-create", "name": "demo", "pluginEnabled": false])
        XCTAssertEqual(host.importBackup(archive: archive, checksum: checksum)["error"] as? String, "PROJECT_NAME_TAKEN")
        let registry = try ProjectRegistry(root: root)
        XCTAssertEqual(registry.projects.map(\.pluginEnabled), [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/home-imports"))
    }

    func testARepeatedExportNumberedByFilesStillPairsAndImports() throws {
        try writeBackup()
        let numbered = inbox + "/HarnessBackup 2.tar", sidecar = inbox + "/HarnessBackup.tar 2.sha256"
        try FileManager.default.moveItem(atPath: archive, toPath: numbered)
        try FileManager.default.moveItem(atPath: checksum, toPath: sidecar)
        let urls = [sidecar, numbered].map { URL(fileURLWithPath: $0) }
        let picked = try XCTUnwrap(BackupImport.pick(urls), "one .tar and one .sha256 pair whatever Files named them")
        XCTAssertEqual(picked.archive.path, numbered)
        XCTAssertEqual(picked.checksum.path, sidecar)
        let reply = try host().importBackup(archive: picked.archive.path, checksum: picked.checksum.path)
        XCTAssertNil(reply["error"])
        XCTAssertEqual(reply["projects"] as? [String], ["demo"])
    }

    func testOnlyOneArchiveAndOneChecksumMakeAPair() {
        let url = { (name: String) in URL(fileURLWithPath: "/inbox/" + name) }
        XCTAssertNil(BackupImport.pick([url("HarnessBackup.tar")]))
        XCTAssertNil(BackupImport.pick([url("HarnessBackup.tar"), url("notes.txt")]))
        XCTAssertNil(BackupImport.pick([url("HarnessBackup.tar"), url("HarnessBackup 2.tar"), url("HarnessBackup.tar.sha256")]),
                     "two archives: which one the checksum belongs to is a guess")
        XCTAssertNil(BackupImport.pick([url("HarnessBackup.tar"), url("HarnessBackup.tar.sha256"), url("HarnessBackup.tar 2.sha256")]))
        XCTAssertNotNil(BackupImport.pick([url("Backup.TAR"), url("Backup.TAR.SHA256")]))
    }

    func testABadSidecarChangesNothing() throws {
        try writeBackup()
        try Data("nope\n".utf8).write(to: URL(fileURLWithPath: checksum))
        let host = try host()
        XCTAssertEqual(host.importBackup(archive: archive, checksum: checksum)["error"] as? String, "CHECKSUM_FILE_INVALID")
        XCTAssertEqual(try ProjectRegistry(root: root).projects, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/migrations/" + "nope"))
    }

    func testADamagedImportNeverBlocksTheHome() throws {
        let host = try host()
        try FileManager.default.createDirectory(atPath: root + "/home-imports", withIntermediateDirectories: true)
        try Data("{".utf8).write(to: URL(fileURLWithPath: root + "/home-imports/x.json"))
        let restored = host.handle(["operation": "restore"])
        XCTAssertNil(restored["error"], "\(restored)")
        XCTAssertEqual(restored["diagnosis"] as? String, "IMPORT_CORRUPT")
    }
}

/// Plain ustar entries with short ASCII names, the shape the old exporter writes for these paths.
private struct Tar {
    var data = Data()

    mutating func file(_ path: String, _ text: String, mode: Int = 0o644) { add(path, 0x30, mode, Data(text.utf8)) }
    mutating func directory(_ path: String, mode: Int = 0o755) { add(path + "/", 0x35, mode, Data()) }

    mutating func add(_ name: String, _ type: UInt8, _ mode: Int, _ body: Data) {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ offset: Int) { for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte } }
        func octal(_ value: Int, _ offset: Int, _ width: Int) {
            let digits = String(value, radix: 8)
            put(String(repeating: "0", count: width - 1 - digits.count) + digits, offset)
        }
        put(name, 0)
        octal(mode, 100, 8); octal(0, 108, 8); octal(0, 116, 8); octal(body.count, 124, 12); octal(1_700_000_000, 136, 12)
        header[156] = type
        put("ustar\0", 257); put("00", 263)
        for index in 148..<156 { header[index] = 0x20 }
        let sum = header.reduce(0) { $0 + Int($1) }
        let digits = String(sum, radix: 8)
        put(String(repeating: "0", count: 6 - digits.count) + digits + "\0 ", 148)
        data.append(contentsOf: header)
        data.append(body)
        if body.count % 512 != 0 { data.append(Data(count: 512 - body.count % 512)) }
    }

    mutating func finish() -> Data {
        data.append(Data(count: 1024))
        if data.count % 10240 != 0 { data.append(Data(count: 10240 - data.count % 10240)) }
        return data
    }
}
