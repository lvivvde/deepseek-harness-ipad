import Foundation
import XCTest
@testable import NativeTools

/// Behaviour the packaged-rg equivalence suite cannot show: the workspace boundary, the store's
/// reserved names, the lease and the argument allowlist. Output equivalence is
/// scripts/gate3/search-equivalence.py.
final class SearchTests: XCTestCase {
    static let mount = "/dsh/workspace/演示"
    var root = "", workspace = "", busy = false

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "native-search-tests-" + UUID().uuidString
        workspace = root + "/workspace"
        for directory in [workspace + "/src/子目录", root + "/outside"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try put("src/子目录/说明.md", "第一行 foo\n")
        try put(".dsh-identity", "foo identity\n")
        try put(".dsh-tmp-1234", "foo temporary\n")
        try put("src/.dsh-tmp-5678", "foo nested temporary\n")
        try "foo outside\n".write(toFile: root + "/outside/secret.txt", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: workspace + "/escape", withDestinationPath: "../outside")
        try FileManager.default.createSymbolicLink(atPath: workspace + "/escape.txt", withDestinationPath: "../outside/secret.txt")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func put(_ path: String, _ text: String) throws { try text.write(toFile: workspace + "/" + path, atomically: false, encoding: .utf8) }

    func rg(_ arguments: [String], cwd: String = mount) -> (code: Int32, out: String, err: String) {
        let search = NativeSearch(workspace: workspace, mount: Self.mount, busy: { [unowned self] in busy })
        let output = search.run(["--no-config"] + arguments, cwd: cwd)
        return (output.exitCode, String(decoding: output.stdout, as: UTF8.self), String(decoding: output.stderr, as: UTF8.self))
    }

    func testWalksTheWorkspaceButNeverTheStoreFiles() {
        let files = rg(["--files", "--hidden", "--no-ignore", "--sort=modified"])
        XCTAssertEqual(files.code, 0)
        XCTAssertEqual(files.out, "src/子目录/说明.md\n")
        let grep = rg(["--json", "--regexp=foo"])
        XCTAssertEqual(grep.code, 0)
        XCTAssertTrue(grep.out.contains("\"text\":\"src/子目录/说明.md\""))
        XCTAssertFalse(grep.out.contains("identity") || grep.out.contains("temporary") || grep.out.contains("outside"))
    }

    func testAnExplicitStoreFileIsRefused() {
        for path in [".dsh-identity", ".dsh-tmp-1234", "src/.dsh-tmp-5678", Self.mount + "/.dsh-identity"] {
            let result = rg(["--json", "--regexp=foo", "--", path])
            XCTAssertEqual(result.code, 2, path)
            XCTAssertEqual(result.out, "", path)
        }
    }

    func testNothingOutsideTheWorkspaceIsSearched() {
        for path in ["escape", "escape.txt", "../outside", root + "/outside", "/etc/hosts", "/dsh/workspace/other"] {
            let result = rg(["--json", "--regexp=foo", "--", path])
            XCTAssertEqual(result.code, 2, path)
            XCTAssertFalse(result.out.contains("outside"), path)
        }
        XCTAssertEqual(rg(["--files"], cwd: "/dsh/workspace").code, 2)
        XCTAssertEqual(rg(["--files"], cwd: Self.mount + "/escape").code, 2)
    }

    func testALinuxLeaseFailsTheSearchInsteadOfReadingAMovingTree() {
        busy = true
        let result = rg(["--json", "--regexp=foo"])
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.out, "")
        XCTAssertTrue(result.err.contains("WORKSPACE_LEASE_BUSY"))
    }

    func testOnlyTheOfficialArgumentShapesAreAccepted() {
        for arguments in [["--files", "--follow"], ["--json", "--regexp=foo", "--pre=cat"], ["--files", "--", "a", "b"],
                          ["--json"], ["--files", "--json", "--regexp=foo"], ["--json", "--regexp=foo", "-uuu"]] {
            let result = rg(arguments)
            XCTAssertEqual(result.code, 2, "\(arguments)")
            XCTAssertEqual(result.out, "", "\(arguments)")
        }
    }

    func testDeclaredDialectDifferencesFailInsteadOfSearchingDifferently() {
        for pattern in ["(?U)a+", "(?R)a", "[a~~b]"] {
            XCTAssertThrowsError(try RustRegex.translate(pattern), pattern)
        }
        XCTAssertEqual(try RustRegex.translate("a*+"), "(?:a*)+")
        XCTAssertEqual(try RustRegex.translate("(?P<n>x)"), "(?<n>x)")
    }
}
