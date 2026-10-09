import Foundation
import XCTest
import UserDataMigration

final class SessionMigrationTests: MigrationTestCase {
    /// Expected values from the official `dsh-session-persistence-jsonl` functions (run under node).
    func testPathRulesMatchOfficialStore() {
        XCTAssertEqual(SessionPaths.projectKey("/root/projects/demo"), "--root-projects-demo--")
        XCTAssertEqual(SessionPaths.projectKey("/dsh/workspace/演示"), "--dsh-workspace-~6F14~793A--")
        XCTAssertEqual(SessionPaths.projectKey("/"), "--root--")
        XCTAssertEqual(SessionPaths.projectKey("//a::b\\c~d"), "--a-b-c~007Ed--")
        XCTAssertEqual(SessionPaths.projectKey("/x/😀 y"), "--x-~D83D~DE00~0020y--")
        XCTAssertEqual(SessionPaths.encodeSegment("s-1"), "s-1")
        XCTAssertEqual(SessionPaths.encodeSegment("会话 1"), "~4F1A~8BDD~00201")
        XCTAssertEqual(SessionPaths.encodeSegment(".."), "~002E~002E")
        XCTAssertEqual(SessionPaths.encodeSegment("a~b"), "a~007Eb")
        XCTAssertEqual(SessionPaths.projectKey("/" + String(repeating: "a", count: 300)).count, 255)
        XCTAssertEqual(SessionPaths.generation("session.v4.jsonl.zstd")?.version, 4)
        XCTAssertEqual(SessionPaths.generation("session.jsonl")?.version, 0)
        XCTAssertNil(SessionPaths.generation("session.v04.jsonl"))
        XCTAssertNil(SessionPaths.generation("session.v0.jsonl"))
        XCTAssertNil(SessionPaths.generation("Session.v4.jsonl"))
    }

    func testCompressedSessionsAreDecodedAndRekeyed() throws {
        try write(try sessionsArchive(compressed: true))
        let report = try XCTUnwrap(report(try migrator().run()))
        let newKey = SessionPaths.projectKey("/dsh/workspace/演示/src")
        let directory = "home/sessions/\(newKey)/s-1/"
        let log = try XCTUnwrap(text(directory + "session.v4.jsonl"))
        let lines = log.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(parsed["cwd"] as? String, "/dsh/workspace/演示/src")
        XCTAssertEqual(parsed["id"] as? String, "s-1")
        XCTAssertEqual(parsed["version"] as? Int, 4)
        XCTAssertEqual(parsed["isSeeded"] as? Bool, false)
        XCTAssertEqual("\n" + lines[1], body, "only the header changes")
        XCTAssertEqual(text(directory + "artifact.bin"), "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/" + directory + "session.v4.jsonl.zstd"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/home/sessions/" + SessionPaths.projectKey("/root/projects/演示/src")))
        XCTAssertEqual(text("home/sessions/_no-cwd/~4F1A~8BDD/session.v4.jsonl"), header(id: "会话", cwd: nil) + body)
        XCTAssertEqual(text("home/sessions/--tmp--/s-2/session.v3.jsonl"), header(id: "s-2", cwd: "/tmp") + body,
                       "older generations and other cwds stay for the official store")
        XCTAssertEqual(report.sessions, 3)
        XCTAssertEqual(report.sessionsDecompressed, 1)
        XCTAssertEqual(report.sessionsMoved, 1)
        XCTAssertEqual(report.sessionsOutsideProjects, 2)
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: target + "/home/sessions").filter { $0.contains(".zstd") || $0.contains(".migration-") }
        XCTAssertEqual(leftovers, [])
    }

    func testPlainSessionsAreRekeyedToo() throws {
        try write(try sessionsArchive(compressed: false))
        let report = try XCTUnwrap(report(try migrator().run()))
        XCTAssertEqual(report.sessionsDecompressed, 0)
        XCTAssertEqual(report.sessionsMoved, 1)
    }

    func testCompressedSessionsWithoutDecoderLeaveTargetUntouched() throws {
        try write(try sessionsArchive(compressed: true))
        assertFails(.sessionDecoderUnavailable) { $0.codec = nil }
    }

    func testDamagedSessionsAreRefused() throws {
        let key = SessionPaths.projectKey("/root/projects/a")
        let cases: [(String, (inout TarWriter) -> Void)] = [
            ("id does not match its directory", { $0.file(".dsh/sessions/\(key)/s-9/session.v4.jsonl", self.header(id: "s-1", cwd: "/root/projects/a")) }),
            ("cwd does not match its project", { $0.file(".dsh/sessions/\(key)/s-1/session.v4.jsonl", self.header(id: "s-1", cwd: "/root/projects/b")) }),
            ("not a header", { $0.file(".dsh/sessions/\(key)/s-1/session.v4.jsonl", "{\"type\":\"user\"}\n") }),
            ("corrupt zstd", { $0.file(".dsh/sessions/\(key)/s-1/session.v4.jsonl.zstd", "not zstd") }),
            ("both encodings", {
                $0.file(".dsh/sessions/\(key)/s-1/session.v4.jsonl", self.header(id: "s-1", cwd: "/root/projects/a"))
                $0.add(".dsh/sessions/\(key)/s-1/session.v4.jsonl.zstd", .file, mode: 0o644,
                       body: try! self.zstd(self.header(id: "s-1", cwd: "/root/projects/a")))
            })
        ]
        for (label, build) in cases {
            var tar = TarWriter.base()
            build(&tar)
            try write(tar)
            XCTAssertThrowsError(try migrator().run(), label) { XCTAssertEqual($0 as? MigrationError, .sessionInvalid, label) }
            assertUntouched()
        }
    }

    func testTamperedStageFailsVerification() throws {
        var tar = TarWriter.base()
        tar.file("projects/a.txt", "original")
        try write(tar)
        let data = root + "/data"
        assertFails(.verifyFailed) { options in
            options.fault = { stage in
                guard stage == .verify, let name = try FileManager.default.contentsOfDirectory(atPath: data)
                    .first(where: { $0.hasPrefix(UserDataMigrator.stagePrefix) }) else { return }
                try "tampered".write(toFile: data + "/" + name + "/projects/a.txt", atomically: false, encoding: .utf8)
            }
        }
        assertFails(.verifyFailed) { options in
            options.fault = { stage in
                guard stage == .verify, let name = try FileManager.default.contentsOfDirectory(atPath: data)
                    .first(where: { $0.hasPrefix(UserDataMigrator.stagePrefix) }) else { return }
                try "extra".write(toFile: data + "/" + name + "/projects/extra.txt", atomically: false, encoding: .utf8)
            }
        }
    }
}

/// A project session (zstd or plain), a session without cwd and one outside `/root/projects`.
extension MigrationTestCase {
    func header(id: String, cwd: String?) -> String {
        var fields: [String: Any] = ["type": "session", "version": 4, "id": id, "createdAt": "2026-09-01T00:00:00.000Z",
                                     "isSeeded": false, "delegationDepth": 0]
        if let cwd { fields["cwd"] = cwd }
        return String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    var body: String { "\n{\"type\":\"user\",\"text\":\"你好 /root/projects/演示 不改\"}\n{\"type\":\"assistant\",\"text\":\"ok\"}\n" }

    func zstd(_ text: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
        process.arguments = ["-q", "-c"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    func sessionsArchive(compressed: Bool) throws -> TarWriter {
        var tar = TarWriter.base()
        tar.directory("projects/演示")
        let log = header(id: "s-1", cwd: "/root/projects/演示/src") + body
        let oldSubKey = SessionPaths.projectKey("/root/projects/演示/src")
        tar.directory(".dsh/sessions/\(oldSubKey)/s-1")
        if compressed {
            tar.add(".dsh/sessions/\(oldSubKey)/s-1/session.v4.jsonl.zstd", .file, mode: 0o644, body: try zstd(log))
        } else {
            tar.file(".dsh/sessions/\(oldSubKey)/s-1/session.v4.jsonl", log)
        }
        tar.file(".dsh/sessions/\(oldSubKey)/s-1/artifact.bin", "kept")
        tar.directory(".dsh/sessions/_no-cwd/~4F1A~8BDD")
        tar.file(".dsh/sessions/_no-cwd/~4F1A~8BDD/session.v4.jsonl", header(id: "会话", cwd: nil) + body)
        tar.directory(".dsh/sessions/--tmp--/s-2")
        tar.file(".dsh/sessions/--tmp--/s-2/session.v3.jsonl", header(id: "s-2", cwd: "/tmp") + body)
        return tar
    }
}
