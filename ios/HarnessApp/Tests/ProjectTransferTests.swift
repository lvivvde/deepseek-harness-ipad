import Foundation
import XCTest
@testable import HarnessRuntime

final class ProjectTransferTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubProtocol.handler = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func transfer() -> ProjectTransfer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ProjectTransfer(token: "secret-token", session: URLSession(configuration: configuration))
    }

    func testTokenIsPerProcessHexAndReachesTheGuestCommandLine() throws {
        XCTAssertNotNil(ProjectTransfer.sessionToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        let configuration = RuntimeConfiguration(kernel: directory, initramfs: directory, systemDisk: directory,
                                                 userDisk: directory, memoryMiB: 2048)
        let arguments = configuration.qemuArguments(firmwareDirectory: directory, transferToken: "abc")
        XCTAssertTrue(arguments.contains { $0.hasSuffix(" harness.transfer=abc") })
        XCTAssertTrue(arguments.contains { $0.contains("hostfwd=tcp:127.0.0.1:28083-:3002") })
    }

    func testExportWritesArchiveAndSha256SumFile() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Harness-Transfer"), "secret-token")
            XCTAssertEqual(request.url?.path, "/projects/acceptance-s/archive")
            return (200, Data("tar-bytes".utf8))
        }
        let files = try await transfer().export("acceptance-s", into: directory, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(files.map(\.lastPathComponent).sorted().count, 2)
        XCTAssertEqual(try Data(contentsOf: files[0]), Data("tar-bytes".utf8))
        let line = try String(contentsOf: files[1], encoding: .utf8)
        XCTAssertTrue(line.hasSuffix("  \(files[0].lastPathComponent)\n"))
        XCTAssertNoThrow(try ProjectTransfer.verify(archive: files[0], checksumFile: files[1]))
    }

    func testFullBackupReportsARefusedPauseInsteadOfAConnectionError() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/userdata/archive")
            return (500, Data(#"{"error":"WRITERS_BUSY"}"#.utf8))
        }
        do {
            _ = try await transfer().exportUserData(into: directory)
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? ProjectTransferError, .writersBusy) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("HarnessBackup.tar").path))
    }

    func testExportPercentEncodesChineseAndSpaces() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "http://127.0.0.1:28083/projects/%E6%88%91%E7%9A%84%20app/archive")
            return (200, Data("tar".utf8))
        }
        let files = try await transfer().export("我的 app", into: directory, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(files[0].lastPathComponent.hasPrefix("我的 app-"))
    }

    func testTrashRestoreAndPurgeUseTheGuestRoutes() async throws {
        var calls: [String] = []
        StubProtocol.handler = { request in
            calls.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/trash"):
                return (200, Data(#"{"items":[{"id":"1791095339992-acd6a38b","name":"我的 项目","deletedAt":1791095339992}]}"#.utf8))
            case ("POST", _): return (200, Data(#"{"name":"我的 项目-2"}"#.utf8))
            default: return (200, Data(#"{}"#.utf8))
            }
        }
        try await transfer().trash("我的 项目")
        let items = try await transfer().trashItems()
        XCTAssertEqual(items.first?.name, "我的 项目")
        XCTAssertNil(items.first?.bytes)
        let restored = try await transfer().restore(items[0])
        XCTAssertEqual(restored, "我的 项目-2")
        try await transfer().purge(items[0])
        try await transfer().purge(nil)
        XCTAssertEqual(calls, ["DELETE /projects/我的 项目", "GET /trash", "POST /trash/1791095339992-acd6a38b/restore",
                               "DELETE /trash/1791095339992-acd6a38b", "DELETE /trash"])
        StubProtocol.handler = { _ in (404, Data(#"{"error":"TRASH_NOT_FOUND"}"#.utf8)) }
        do {
            try await transfer().purge(items[0])
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? ProjectTransferError, .notFound) }
    }

    func testImportRefusesMismatchedChecksumBeforeUploading() async throws {
        let archive = directory.appendingPathComponent("p.tar")
        let checksum = directory.appendingPathComponent("p.tar.sha256")
        try Data("archive".utf8).write(to: archive)
        try Data((String(repeating: "0", count: 64) + "  p.tar\n").utf8).write(to: checksum)
        StubProtocol.handler = { _ in XCTFail("must not upload"); return (500, Data()) }
        do {
            _ = try await transfer().importArchive(archive, checksum: checksum)
            XCTFail("expected mismatch")
        } catch { XCTAssertEqual(error as? ProjectTransferError, .checksumMismatch) }
    }

    func testFullRestoreRequiresChecksumBeforeSendingAnyUserData() async throws {
        let archive = directory.appendingPathComponent("backup.tar")
        let checksum = directory.appendingPathComponent("backup.tar.sha256")
        try Data("data".utf8).write(to: archive)
        try Data(String(repeating: "0", count: 64).utf8).write(to: checksum)
        StubProtocol.handler = { _ in XCTFail("invalid backup must never upload"); return (500, Data()) }
        do {
            try await transfer().restoreUserData(archive, checksum: checksum)
            XCTFail("expected checksum mismatch")
        } catch { XCTAssertEqual(error as? ProjectTransferError, .checksumMismatch) }
        try Data("\(try ProjectTransfer.sha256(of: archive))  backup.tar\n".utf8).write(to: checksum)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/userdata/restore")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Harness-Transfer"), "secret-token")
            return (200, Data(#"{"restored":true}"#.utf8))
        }
        try await transfer().restoreUserData(archive, checksum: checksum)
    }

    func testImportReturnsGuestProjectNameAndMapsErrors() async throws {
        let archive = directory.appendingPathComponent("p.tar")
        try Data("archive".utf8).write(to: archive)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (201, Data(#"{"name":"demo-2","path":"/root/projects/demo-2"}"#.utf8))
        }
        let name = try await transfer().importArchive(archive, checksum: nil)
        XCTAssertEqual(name, "demo-2")
        StubProtocol.handler = { _ in (422, Data(#"{"error":"ARCHIVE_LAYOUT"}"#.utf8)) }
        do {
            _ = try await transfer().importArchive(archive, checksum: nil)
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? ProjectTransferError, .invalidArchive) }
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
