import Darwin
import Foundation
import XCTest
@testable import Plan500Gateway

final class FakeTransport: GuestTransport {
    var handler: (String, [String: Any]?) throws -> [String: Any] = { route, _ in
        route == "/bind" || route == "/notify" ? ["generation": 0] : [:]
    }
    private(set) var calls: [(String, [String: Any]?)] = []
    func rpc(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
        calls.append((route, body)); return try handler(route, body)
    }
}

final class GatewayTests: XCTestCase {
    var root = "", workspace = "", state = ""
    let fake = FakeTransport()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "plan500-gateway-tests-" + UUID().uuidString
        workspace = root + "/workspace"; state = root + "/state"
        try FileManager.default.createDirectory(atPath: workspace + "/src", withIntermediateDirectories: true)
        try write("notes.md", "base-notes"); try write("src/app.js", "base-app")
        try write(".plan500-identity", "identity")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func write(_ path: String, _ text: String) throws { try text.write(toFile: workspace + "/" + path, atomically: false, encoding: .utf8) }
    func read(_ path: String) throws -> String { try String(contentsOfFile: workspace + "/" + path, encoding: .utf8) }
    func gateway() throws -> Gateway { try Gateway(workspace: workspace, state: state, identity: "identity", transport: fake) }
    func status(_ result: [String: Any]) -> String? { result["status"] as? String }

    func testNativeFilesWorkBeforeLinuxIsAttached() throws {
        let g = try gateway()
        fake.handler = { _, _ in XCTFail("native files must not wait for Linux"); throw TransportError.unreachable("cold") }
        let before = try g.nativeRead(RelativePath("notes.md"))
        XCTAssertEqual(before["text"] as? String, "base-notes")
        let saved = try g.nativeWrite(RelativePath("notes.md"), Data("原生修改".utf8), base: before["version"] as? String)
        XCTAssertEqual(status(saved), "WRITTEN")
        XCTAssertEqual(try g.nativeRead(RelativePath("notes.md"))["text"] as? String, "原生修改")
    }

    func testVersionCASRefusesStaleBaseAndCreateOverExisting() throws {
        let g = try gateway()
        let v0 = g.version(RelativePath("notes.md"))
        XCTAssertNil(g.s.versions[RelativePath(".plan500-identity")])
        XCTAssertEqual(status(try g.nativeWrite(RelativePath("notes.md"), Data("A".utf8), base: v0)), "WRITTEN")
        let stale = try g.nativeWrite(RelativePath("notes.md"), Data("B".utf8), base: v0)
        XCTAssertEqual(stale["reason"] as? String, "VERSION")
        XCTAssertEqual(status(try g.nativeWrite(RelativePath("notes.md"), Data("C".utf8), base: nil)), "CONFLICT")
        XCTAssertEqual(try read("notes.md"), "A")
        XCTAssertEqual(status(try g.nativeWrite(RelativePath("new/deep/file"), Data("n".utf8), base: nil)), "WRITTEN")
        XCTAssertEqual(try read("new/deep/file"), "n")
        XCTAssertEqual(g.s.log.map(\.origin), ["native", "native"])
    }

    func testConflictKeepsDraftAcrossGatewayRestart() throws {
        let g = try gateway(), path = RelativePath("notes.md")
        let old = g.version(path)
        _ = try g.nativeWrite(path, Data("first".utf8), base: old)
        let result = try g.nativeWrite(path, Data("keep-my-draft".utf8), base: old)
        let identifier = try XCTUnwrap(result["draft"] as? String)
        let restarted = try gateway()
        XCTAssertEqual(restarted.snapshot().0.drafts.last?.status, "CONFLICT")
        XCTAssertEqual(try restarted.readDraft(identifier)["text"] as? String, "keep-my-draft")
        XCTAssertEqual(try restarted.nativeRead(path)["text"] as? String, "first")
    }

    func testExistingModeIsKeptAcrossNativeWrite() throws {
        chmod(workspace + "/notes.md", 0o755)
        let g = try gateway()
        _ = try g.nativeWrite(RelativePath("notes.md"), Data("x".utf8), base: g.version(RelativePath("notes.md")))
        var status = stat(); stat(workspace + "/notes.md", &status)
        XCTAssertEqual(status.st_mode & 0o777, 0o755)
    }

    func testExternalHostWriteIsAConflictNotOverwritten() throws {
        let g = try gateway()
        let base = g.version(RelativePath("notes.md"))
        try write("notes.md", "files-app-edit")
        let result = try g.nativeWrite(RelativePath("notes.md"), Data("mine".utf8), base: base)
        XCTAssertEqual(result["reason"] as? String, "EXTERNAL_CHANGE")
        XCTAssertEqual(try read("notes.md"), "files-app-edit")
        XCTAssertEqual(g.s.log.last?.origin, "external")
        XCTAssertEqual(result["current"] as? String, g.version(RelativePath("notes.md")))
    }

    func testDraftsDuringLeaseRebaseIntoAppliedAndConflict() throws {
        let g = try gateway()
        let vApp = g.version(RelativePath("src/app.js")), vNotes = g.version(RelativePath("notes.md"))
        var held: [[String: Any]] = []
        fake.handler = { route, body in
            if route == "/execute" {
                XCTAssertEqual((body?["lease"] as? [String: Any])?["fence"] as? Int, 1)
                try self.write("src/app.js", "guest-change")
                held.append(try g.nativeWrite(RelativePath("src/app.js"), Data("native-app".utf8), base: vApp))
                held.append(try g.nativeWrite(RelativePath("notes.md"), Data("native-notes".utf8), base: vNotes))
                return ["code": 0, "writerQuiescent": true]
            }
            return ["generation": 0]
        }
        let released = try g.runLeased("op", argv: ["/bin/true"], timeout: 1000)
        XCTAssertEqual(held.map { $0["status"] as? String }, ["DRAFT_HELD", "DRAFT_HELD"])
        XCTAssertEqual(status(released), "RELEASED")
        XCTAssertEqual(released["changed"] as? [String], ["src/app.js"])
        let drafts = Dictionary(uniqueKeysWithValues: (released["drafts"] as! [[String: Any]]).map { ($0["path"] as! String, $0["status"] as! String) })
        XCTAssertEqual(drafts, ["src/app.js": "CONFLICT", "notes.md": "APPLIED"])
        XCTAssertEqual(try read("src/app.js"), "guest-change")
        XCTAssertEqual(try read("notes.md"), "native-notes")
        XCTAssertNil(g.s.lease)
        XCTAssertEqual(g.s.log.map(\.origin), ["linux", "native"])
    }

    func testBusyLeaseAndRefusalReleaseWithoutGeneration() throws {
        let g = try gateway()
        fake.handler = { route, _ in
            if route == "/execute" {
                XCTAssertEqual(self.status(try g.runLeased("second", argv: [], timeout: 1)), "LEASE_BUSY")
                throw TransportError.refused(status: 409, error: "LEASE_STALE")
            }
            return [:]
        }
        let released = try g.runLeased("first", argv: [], timeout: 1)
        XCTAssertEqual(released["reason"] as? String, "REFUSED")
        XCTAssertEqual(released["refusal"] as? String, "LEASE_STALE")
        XCTAssertEqual(g.s.generation, 0)
        XCTAssertNil(g.s.lease)
    }

    func testUnquiescentOrLostWriterKeepsLeaseUntilRevokeOrVMExit() throws {
        let g = try gateway()
        fake.handler = { route, _ in
            if route == "/execute" { try self.write("partial", "p"); return ["writerQuiescent": false] }
            if route == "/revoke" { return ["revoked": false, "started": true] }
            return [:]
        }
        XCTAssertEqual(status(try g.runLeased("op", argv: [], timeout: 1)), "WRITER_UNKNOWN")
        XCTAssertEqual(g.s.lease?.state, "WRITER_UNKNOWN")
        XCTAssertEqual(status(try g.nativeWrite(RelativePath("notes.md"), Data("d".utf8), base: g.version(RelativePath("notes.md")))), "DRAFT_HELD")
        XCTAssertEqual(try g.reconcile(vmExited: false)["reason"] as? String, "WRITER_RUNNING")
        fake.handler = { _, _ in throw TransportError.unreachable("down") }
        XCTAssertEqual(try g.reconcile(vmExited: false)["reason"] as? String, "UNREACHABLE")
        XCTAssertNotNil(g.s.lease)
        let released = try g.reconcile(vmExited: true)
        XCTAssertEqual(released["reason"] as? String, "GUEST_TERMINATED")
        XCTAssertEqual(g.s.epoch, 2)
        XCTAssertEqual(released["changed"] as? [String], ["partial"])
        XCTAssertEqual(try read("notes.md"), "d")
    }

    func testRestartTreatsPersistedLeaseAsUnknownWriter() throws {
        var g = try gateway()
        let lease = try XCTUnwrap(try g.acquire("lost"))
        XCTAssertEqual(status(try g.nativeWrite(RelativePath("notes.md"), Data("held".utf8), base: g.version(RelativePath("notes.md")))), "DRAFT_HELD")
        g = try gateway()  // simulated crash: only the durable file survives
        XCTAssertEqual(g.s.lease?.state, "WRITER_UNKNOWN")
        XCTAssertEqual(g.s.drafts.map(\.status), ["HELD"])
        var revoked: [String: Any]?
        fake.handler = { route, body in
            if route == "/revoke" { revoked = body; return ["revoked": true, "started": false] }
            return [:]
        }
        let released = try g.reconcile(vmExited: false)
        XCTAssertEqual(revoked?["fence"] as? Int, lease.fence)
        XCTAssertEqual(released["started"] as? Bool, false)
        XCTAssertEqual(try read("notes.md"), "held")
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: state + "/gateway.json"))) as! [String: Any]
        XCTAssertTrue(persisted["lease"] is NSNull)
        XCTAssertEqual((persisted["drafts"] as! [[String: Any]]).map { $0["status"] as! String }, ["APPLIED"])
    }

    func testNotifyCatchesUpAfterDisconnect() throws {
        let g = try gateway()
        fake.handler = { _, _ in throw TransportError.unreachable("down") }
        _ = try g.nativeWrite(RelativePath("a"), Data("1".utf8), base: nil)
        _ = try g.nativeWrite(RelativePath("b"), Data("2".utf8), base: nil)
        var delivered: [Int] = []
        fake.handler = { route, body in
            if route == "/bind" { return ["generation": 0] }
            delivered = (body?["entries"] as! [[String: Any]]).map { $0["generation"] as! Int }
            return ["generation": delivered.last!]
        }
        _ = try g.attach()
        XCTAssertEqual(delivered, [1, 2])
        XCTAssertEqual(g.guestAck, 2)
    }

    func testPathsOutsideWorkspaceAndSymlinkedParentsAreRefused() throws {
        let outside = root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        symlink(outside, workspace + "/escape")
        let g = try gateway()
        for path in ["../x", "/etc/x", "a//b", "./a", "a/../b", "", "escape/x", ".plan500-identity", "src/.plan500-tmp-x"] {
            let result = try g.nativeWrite(RelativePath(path), Data("x".utf8), base: nil)
            XCTAssertEqual(status(result), "REFUSED", path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), [])
        // The symlink itself is an ordinary entry and may be replaced; that never writes through it.
        let link = g.version(RelativePath("escape"))
        XCTAssertEqual(status(try g.nativeWrite(RelativePath("escape"), Data("file".utf8), base: link)), "WRITTEN")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), [])
    }

    func testSpecialFilesAreFingerprintedWithoutOpening() throws {
        XCTAssertEqual(mkfifo(workspace + "/fifo", 0o644), 0)
        let started = Date()
        let found = try Workspace(root: workspace).scan()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(found[RelativePath("fifo")], "S:fifo:644")
        XCTAssertTrue(found[RelativePath("notes.md")]!.hasPrefix("F:"))
    }

    func testPathKeysAreByteExact() throws {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        XCTAssertEqual(nfc, nfd)  // Swift String equality is canonical equivalence...
        var strings: [String: Int] = [:]; strings[nfc] = 1; strings[nfd] = 2
        XCTAssertEqual(strings.count, 1)  // ...so String-keyed maps merge them.
        var keys: [RelativePath: Int] = [:]
        keys[RelativePath(nfc)] = 1; keys[RelativePath(nfd)] = 2
        XCTAssertEqual(keys.count, 2)
        // The scan returns the on-disk bytes, not a normalized spelling.
        try write(nfd, "d")
        let found = try Workspace(root: workspace).scan()
        XCTAssertNotNil(found[RelativePath(nfd)])
        XCTAssertNil(found[RelativePath(nfc)])
        // Round trip through the durable state keeps the bytes.
        let g = try gateway()
        let decoded = try JSONDecoder().decode(GatewayState.self, from: try JSONEncoder().encode(g.s))
        XCTAssertEqual(Set(decoded.versions.keys), Set(g.s.versions.keys))
        XCTAssertTrue(decoded.versions.keys.contains(RelativePath(nfd)))
        // Non-UTF-8 names encode losslessly.
        let raw = RelativePath(bytes: [0x66, 0xFF])
        XCTAssertEqual(try JSONDecoder().decode(RelativePath.self, from: try JSONEncoder().encode(raw)), raw)
    }
}
