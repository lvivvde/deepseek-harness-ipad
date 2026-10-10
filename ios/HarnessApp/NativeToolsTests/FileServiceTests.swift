import Darwin
import Foundation
import XCTest
import NativeWorkspace
@testable import NativeTools

final class FileServiceTests: XCTestCase {
    static let mount = "/dsh/workspace/演示"
    var root = "", workspace = "", outside = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "native-tools-tests-" + UUID().uuidString
        workspace = root + "/workspace"; outside = root + "/outside"
        for directory in [workspace + "/src/子目录", outside] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try put("src/子目录/说明.md", "第一行\n第二行\n")
        try put("notes.txt", "notes")
        try "secret".write(toFile: outside + "/secret.txt", atomically: false, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func put(_ path: String, _ text: String) throws { try text.write(toFile: workspace + "/" + path, atomically: false, encoding: .utf8) }
    func link(_ path: String, _ target: String) throws { try FileManager.default.createSymbolicLink(atPath: workspace + "/" + path, withDestinationPath: target) }
    func disk(_ path: String) -> String? { try? String(contentsOfFile: workspace + "/" + path, encoding: .utf8) }
    func service() throws -> (NativeFileService, WorkspaceStore) {
        let store = try WorkspaceStore(workspace: workspace, state: root + "/state")
        return (NativeFileService(store: store, mount: Self.mount), store)
    }
    func at(_ relative: String) -> String { relative.isEmpty ? Self.mount : Self.mount + "/" + relative }
    func code(_ body: () throws -> Any?) -> String? {
        do { _ = try body(); return nil } catch let error as ToolError { return error.code } catch { return "\(error)" }
    }

    func testRealpathFollowsInWorkspaceLinksAndRefusesEscapes() throws {
        let (fs, _) = try service()
        try link("rel", "src/子目录")
        try link("abs", at("src"))
        try link("up", "../outside/secret.txt")
        try link("etc", "/etc")
        try link("loop", "loop")
        XCTAssertEqual(try fs.realpath(at("rel/说明.md")), at("src/子目录/说明.md"))
        XCTAssertEqual(try fs.realpath(at("abs/子目录")), at("src/子目录"))
        XCTAssertEqual(try fs.realpath(at("src/./子目录/../子目录")), at("src/子目录"))
        XCTAssertEqual(try fs.realpath(at("")), at(""))
        // A missing leaf resolves through its nearest existing ancestor, as dsh-fs-local does.
        XCTAssertEqual(try fs.realpath(at("rel/new/file.txt")), at("src/子目录/new/file.txt"))
        XCTAssertEqual(code { try fs.realpath(at("missing/../notes.txt")) }, "FS_NOT_FOUND")
        XCTAssertEqual(code { try fs.realpath(at("notes.txt/child")) }, "FS_NOT_FOUND")
        XCTAssertEqual(code { try fs.realpath(at("up")) }, "FS_SANDBOX_DENIED")
        XCTAssertEqual(code { try fs.realpath(at("etc/hosts")) }, "FS_SANDBOX_DENIED")
        XCTAssertEqual(code { try fs.realpath(at("../other")) }, "FS_SANDBOX_DENIED")
        XCTAssertEqual(code { try fs.realpath("/dsh/workspace/other/file") }, "FS_SANDBOX_DENIED")
        XCTAssertEqual(code { try fs.realpath(at("loop")) }, "FS_IO_ERROR")
    }

    func testStatFollowsLinksAndLstatReportsTheLinkItself() throws {
        let (fs, _) = try service()
        try link("doc", "src/子目录/说明.md")
        try link("dangling", "nowhere")
        let followed = try XCTUnwrap(try fs.stat(at("doc"), follow: true))
        XCTAssertEqual(followed.type, .file)
        XCTAssertEqual(followed.size, Data("第一行\n第二行\n".utf8).count)
        XCTAssertEqual(followed.version, try fs.stat(at("src/子目录/说明.md"), follow: true)?.version)
        XCTAssertEqual(try fs.stat(at("doc"), follow: false)?.type, .symlink)
        XCTAssertEqual(try fs.stat(at("src"), follow: true)?.type, .directory)
        XCTAssertEqual(try fs.stat(at(""), follow: true)?.type, .directory)
        XCTAssertNil(try fs.stat(at("dangling"), follow: true))
        XCTAssertEqual(try fs.stat(at("dangling"), follow: false)?.type, .symlink)
        XCTAssertNil(try fs.stat(at("missing"), follow: true))
        XCTAssertEqual(mkfifo(workspace + "/pipe", 0o644), 0)
        XCTAssertEqual(try fs.stat(at("pipe"), follow: true)?.type, .other)
    }

    func testListSortsChildrenResolvesTargetsAndHidesStoreEntries() throws {
        let (fs, _) = try service()
        try link("doc", "src/子目录/说明.md")
        try put(".dsh-identity", "id")
        try put(".dsh-tmp-left", "tmp")
        try put(".plan500-identity", "guest id")
        try put(".dsh-mount-check", "nonce")
        let entries = try fs.list(at(""))
        XCTAssertEqual(entries.map(\.name), ["doc", "notes.txt", "src"])
        XCTAssertEqual(entries.map(\.type), [.file, .file, .directory])
        XCTAssertEqual(entries[0].target, at("src/子目录/说明.md"))
        XCTAssertNotNil(entries[1].version)
        XCTAssertEqual(entries[1].size, 5)
        XCTAssertNil(entries[2].size)
        XCTAssertEqual(code { try fs.list(at("notes.txt")) }, "FS_NOT_DIRECTORY")
        XCTAssertEqual(code { try fs.list(at("missing")) }, "FS_NOT_FOUND")
    }

    func testReadReturnsBytesWithTheStatVersionAndFixedCodes() throws {
        let (fs, store) = try service()
        let (data, version) = try fs.read(at("src/子目录/说明.md"), limit: 1 << 20)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "第一行\n第二行\n")
        XCTAssertEqual(version, try fs.stat(at("src/子目录/说明.md"), follow: true)?.version)
        XCTAssertEqual(try fs.readRange(at("notes.txt"), offset: 1, length: 3), Data("ote".utf8))
        XCTAssertEqual(try fs.readRange(at("notes.txt"), offset: 9, length: 3), Data())
        XCTAssertEqual(code { try fs.read(at("notes.txt"), limit: 4) }, "FS_TOO_LARGE")
        XCTAssertEqual(code { try fs.read(at("src"), limit: 10) }, "FS_NOT_REGULAR_FILE")
        XCTAssertEqual(code { try fs.read(at("missing"), limit: 10) }, "FS_NOT_FOUND")
        XCTAssertEqual(code { try fs.read(at(".dsh-identity"), limit: 10) }, "FS_PERMISSION_DENIED")
        try put(".dsh-mount-check", "nonce")
        XCTAssertEqual(code { try fs.read(at(".dsh-mount-check"), limit: 10) }, "FS_PERMISSION_DENIED")
        guard case .granted = try store.acquireLease("linux") else { return XCTFail("lease") }
        XCTAssertEqual(code { try fs.read(at("notes.txt"), limit: 10) }, "WORKSPACE_LEASE_BUSY")
        XCTAssertEqual(try fs.stat(at("notes.txt"), follow: true)?.type, .file)
    }

    func testWriteFollowsTheDshFsIntentContract() throws {
        let (fs, _) = try service()
        let created = try fs.write(at("新建/文件.txt"), Data("一".utf8), expected: .createIfAbsent, beforeLimit: 1 << 20)
        XCTAssertEqual(created.operation, .create)
        XCTAssertNil(created.before)
        XCTAssertEqual(disk("新建/文件.txt"), "一")
        XCTAssertEqual(code { try fs.write(at("新建/文件.txt"), Data(), expected: .createIfAbsent, beforeLimit: 10) }, "FS_NOT_OBSERVED")
        XCTAssertEqual(code { try fs.write(at("新建/文件.txt"), Data(), expected: .replaceIfVersion("1:F:x"), beforeLimit: 10) },
                       "FS_STALE_VERSION")
        XCTAssertEqual(code { try fs.write(at("gone.txt"), Data(), expected: .replaceIfVersion(created.version), beforeLimit: 10) },
                       "FS_STALE_VERSION")
        let updated = try fs.write(at("新建/文件.txt"), Data("二".utf8), expected: .replaceIfVersion(created.version), beforeLimit: 1 << 20)
        XCTAssertEqual(updated.operation, .update)
        XCTAssertEqual(updated.before, Data("一".utf8))
        XCTAssertEqual(updated.version, try fs.stat(at("新建/文件.txt"), follow: true)?.version)
        let unconditional = try fs.write(at("notes.txt"), Data("n2".utf8), expected: nil, beforeLimit: 1)
        XCTAssertNil(unconditional.before, "a basis at or above the limit is not returned")
        XCTAssertEqual(code { try fs.write(at("src"), Data(), expected: nil, beforeLimit: 10) }, "FS_NOT_REGULAR_FILE")
        XCTAssertEqual(code { try fs.write(at(".dsh-identity"), Data(), expected: nil, beforeLimit: 10) }, "FS_PERMISSION_DENIED")
        XCTAssertEqual(code { try fs.write(at("../escape"), Data(), expected: nil, beforeLimit: 10) }, "FS_SANDBOX_DENIED")
    }

    func testWriteThroughALinkUpdatesTheTargetAndKeepsTheLink() throws {
        let (fs, _) = try service()
        try link("doc", "src/子目录/说明.md")
        let version = try XCTUnwrap(try fs.stat(at("doc"), follow: true)?.version)
        _ = try fs.write(at("doc"), Data("改".utf8), expected: .replaceIfVersion(version), beforeLimit: 1 << 20)
        XCTAssertEqual(disk("src/子目录/说明.md"), "改")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: workspace + "/doc"), "src/子目录/说明.md")
        try link("out", "../outside/secret.txt")
        XCTAssertEqual(code { try fs.write(at("out"), Data("x".utf8), expected: nil, beforeLimit: 10) }, "FS_SANDBOX_DENIED")
        XCTAssertEqual(try String(contentsOfFile: outside + "/secret.txt", encoding: .utf8), "secret")
    }

    func testWriteDuringALinuxLeaseIsHeldAsADraftAndLandsOnRelease() throws {
        let (fs, store) = try service()
        let version = try XCTUnwrap(try fs.stat(at("notes.txt"), follow: true)?.version)
        guard case .granted(let lease) = try store.acquireLease("linux") else { return XCTFail("lease") }
        XCTAssertEqual(try fs.stat(at("notes.txt"), follow: true)?.version, version, "last known version while Linux writes")
        XCTAssertEqual(code { try fs.write(at("notes.txt"), Data("草稿".utf8), expected: .replaceIfVersion(version), beforeLimit: 10) },
                       "WORKSPACE_DRAFT_HELD")
        XCTAssertEqual(disk("notes.txt"), "notes")
        XCTAssertEqual(code { try fs.write(at("notes.txt"), Data(), expected: .createIfAbsent, beforeLimit: 10) }, "FS_NOT_OBSERVED")
        let released = try XCTUnwrap(try store.releaseLease(fence: lease.fence, reason: .completed))
        XCTAssertEqual(released.drafts.map(\.status), [.applied])
        XCTAssertEqual(disk("notes.txt"), "草稿")
    }
}
