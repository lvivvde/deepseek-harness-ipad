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
