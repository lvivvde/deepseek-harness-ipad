import Foundation
import XCTest
@testable import ModelGateway

final class ModelGatewayTests: XCTestCase {
    private let official = ModelGateway.officialURL.absoluteString
    private let realKey = "sk-gate4-test-only-0000"
    private var servers: [FaultServer] = []
    private var gateways: [ModelGateway] = []

    override func tearDown() {
        servers.forEach { $0.stop() }; servers = []
        gateways.forEach { $0.invalidate() }; gateways = []
    }

    private func server(_ script: @escaping @Sendable (FaultConnection) -> Void) throws -> FaultServer {
        let server = try FaultServer(script); servers.append(server); return server
    }

    private func gateway(_ target: URL, idle: TimeInterval = 30, key: String? = nil) -> ModelGateway {
        let value = key ?? realKey
        let gateway = ModelGateway(target: target, idleTimeout: idle) { value }
        gateways.append(gateway)
        return gateway
    }

    private let workerHeaders = [
        "Content-Type": "application/json", "Accept": "text/event-stream", "anthropic-version": "2023-06-01",
        "user-agent": "dsh/1", "x-deepseek-harness-session-id": "s1", "x-deepseek-harness-user-id": "u1",
        "x-api-key": "plan500-native-placeholder", "authorization": "Bearer placeholder", "cookie": "a=b",
    ]

    private func drain(_ gateway: ModelGateway, _ id: String) throws -> Data {
        var data = Data()
        while case .chunk(let part) = try gateway.read(id) { data.append(part) }
        return data
    }

    private func failure(_ body: () throws -> Void) -> ModelFailure? {
        do { try body(); return nil } catch let error as ModelFailure { return error } catch { return nil }
    }

    func testRefusesEveryUrlButTheOfficialEndpointWithoutSending() throws {
        let server = try server { $0.respond(status: 200, body: "{}") }
        let gateway = gateway(server.url)
        for url in [official + "?x=1", "http://api.deepseek.com/anthropic/v1/messages",
                    "https://api.deepseek.com/anthropic/v1/models", "https://example.com/anthropic/v1/messages",
                    "https://api.deepseek.com.evil/anthropic/v1/messages"] {
            XCTAssertEqual(failure { _ = try gateway.open(id: url, url: url, headers: [:], body: Data()) }, .endpointRefused)
        }
        XCTAssertEqual(server.requests.count, 0)
    }

    func testRealKeyIsAddedOnlyInSwiftAndWorkerCredentialsAreDropped() throws {
        let server = try server { connection in
            connection.streamHead(); connection.chunk("data: {}\n\n"); connection.end()
        }
        let gateway = gateway(server.url)
        let body = Data(#"{"model":"deepseek-flash","stream":true,"中文":"路径"}"#.utf8)
        let head = try gateway.open(id: "a", url: official, headers: workerHeaders, body: body)
        XCTAssertEqual(head.status, 200)
        _ = try drain(gateway, "a")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, body)
        XCTAssertEqual(request.headers["x-api-key"], realKey)
        XCTAssertNil(request.headers["authorization"])
        XCTAssertNil(request.headers["cookie"])
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.headers["accept"], "text/event-stream")
        XCTAssertEqual(request.headers["user-agent"], "dsh/1")
        XCTAssertEqual(request.headers["x-deepseek-harness-session-id"], "s1")
        XCTAssertEqual(request.headers["x-deepseek-harness-user-id"], "u1")
    }

    func testMissingOrUnsafeKeyIsRefusedWithoutSending() throws {
        let server = try server { $0.respond(status: 200, body: "{}") }
        for key in ["", "bad\r\nx-injected: 1"] {
            let gateway = gateway(server.url, key: key)
            XCTAssertEqual(failure { _ = try gateway.open(id: "k", url: official, headers: [:], body: Data()) }, .keyMissing)
        }
        XCTAssertEqual(server.requests.count, 0)
    }

    func testChunksArriveBeforeTheResponseEnds() throws {
        let lastSent = Locked<Date?>(nil)
        let server = try server { connection in
            connection.streamHead()
            for index in 0..<3 {
                if index > 0 { Thread.sleep(forTimeInterval: 0.4) }
                if index == 2 { lastSent.set(Date()) }
                connection.chunk("event: ping\ndata: {\"n\":\(index)}\n\n")
            }
            connection.end()
        }
        let gateway = gateway(server.url)
        _ = try gateway.open(id: "s", url: official, headers: workerHeaders, body: Data("{}".utf8))
        guard case .chunk(let first) = try gateway.read("s") else { return XCTFail("no first chunk") }
        let firstAt = Date()
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("\"n\":0"))
        let rest = try drain(gateway, "s")
        let sentAt = try XCTUnwrap(lastSent.get())
        XCTAssertLessThan(firstAt, sentAt, "first chunk must be delivered before the server sent the last one")
        XCTAssertTrue(String(decoding: rest, as: UTF8.self).contains("\"n\":2"))
        let record = try XCTUnwrap(gateway.records.last)
        XCTAssertEqual(record.outcome, "END")
        XCTAssertEqual(record.status, 200)
        XCTAssertGreaterThanOrEqual(record.chunks, 2)
        XCTAssertGreaterThan(try XCTUnwrap(record.lastChunkMs) - (try XCTUnwrap(record.firstChunkMs)), 600)
    }

    func testCancelDuringStreamClosesTheHttpConnection() throws {
        let peerClosed = Locked(false)
        let server = try server { connection in
            connection.streamHead(); connection.chunk("data: {}\n\n")
            peerClosed.set(connection.waitForPeerClose(timeout: 5))
        }
        let gateway = gateway(server.url)
        _ = try gateway.open(id: "c", url: official, headers: [:], body: Data("{}".utf8))
        guard case .chunk = try gateway.read("c") else { return XCTFail("no chunk") }
        gateway.cancel("c")
        XCTAssertEqual(failure { _ = try gateway.read("c") }, .cancelled)
        XCTAssertTrue(waitUntil { peerClosed.get() }, "server never saw the client close")
        XCTAssertEqual(gateway.records.last?.outcome, ModelFailure.cancelled.rawValue)
    }

    func testCancelBeforeResponseHeadAbortsOpen() throws {
        let peerClosed = Locked(false)
        let server = try server { connection in peerClosed.set(connection.waitForPeerClose(timeout: 5)) }
        let gateway = gateway(server.url)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gateway.cancel("early") }
        XCTAssertEqual(failure { _ = try gateway.open(id: "early", url: official, headers: [:], body: Data("{}".utf8)) }, .cancelled)
        XCTAssertTrue(waitUntil { peerClosed.get() })
    }

    func testCancelThatArrivesBeforeOpenPreventsTheRequest() throws {
        let server = try server { $0.respond(status: 200, body: "{}") }
        let gateway = gateway(server.url)
        gateway.cancel("raced")
        XCTAssertEqual(failure { _ = try gateway.open(id: "raced", url: official, headers: [:], body: Data()) }, .cancelled)
        XCTAssertEqual(server.requests.count, 0)
    }

    func testErrorStatusesKeepBodyAndRetryHeadersForTheOfficialParser() throws {
        let cases: [(Int, String)] = [(401, "authentication_error"), (429, "rate_limit_error"), (503, "overloaded_error")]
        for (status, type) in cases {
            let body = #"{"type":"error","error":{"type":"\#(type)","message":"m"}}"#
            let server = try server { connection in
                connection.respond(status: status, headers: ["Retry-After": "2", "request-id": "req-\(status)"], body: body)
            }
            let gateway = gateway(server.url)
            let head = try gateway.open(id: "e", url: official, headers: [:], body: Data("{}".utf8))
            XCTAssertEqual(head.status, status)
            XCTAssertEqual(head.headers["retry-after"], "2")
            XCTAssertEqual(head.headers["request-id"], "req-\(status)")
            XCTAssertEqual(head.headers["content-type"], "application/json")
            XCTAssertEqual(String(decoding: try drain(gateway, "e"), as: UTF8.self), body)
            XCTAssertEqual(server.requests.count, 1, "gateway itself never retries")
        }
    }

    func testMidStreamDisconnectDeliversDataThenTransportFailure() throws {
        let server = try server { connection in
            connection.streamHead(); connection.chunk("data: {\"partial\":1}\n\n")
            Thread.sleep(forTimeInterval: 0.2); connection.reset()
        }
        let gateway = gateway(server.url)
        _ = try gateway.open(id: "d", url: official, headers: [:], body: Data("{}".utf8))
        guard case .chunk(let part) = try gateway.read("d") else { return XCTFail("no partial chunk") }
        XCTAssertTrue(String(decoding: part, as: UTF8.self).contains("partial"))
        let error = failure { _ = try drain(gateway, "d") }
        XCTAssertTrue([.disconnected, .transport].contains(error), "got \(String(describing: error))")
    }

    func testIdleStreamTimesOut() throws {
        let server = try server { connection in
            connection.streamHead(); connection.chunk("data: {}\n\n")
            _ = connection.waitForPeerClose(timeout: 5)
        }
        let gateway = gateway(server.url, idle: 0.6)
        _ = try gateway.open(id: "t", url: official, headers: [:], body: Data("{}".utf8))
        let started = Date()
        XCTAssertEqual(failure { _ = try drain(gateway, "t") }, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testClosedPortAndUnknownHostFailExplicitly() throws {
        let closed = try FaultServer { _ in }
        let port = closed.port; closed.stop()
        let refused = gateway(URL(string: "http://127.0.0.1:\(port)/anthropic/v1/messages")!)
        XCTAssertEqual(failure { _ = try refused.open(id: "r", url: official, headers: [:], body: Data()) }, .connect)
        let unknown = gateway(URL(string: "http://plan500-gate4.invalid/anthropic/v1/messages")!)
        XCTAssertEqual(failure { _ = try unknown.open(id: "n", url: official, headers: [:], body: Data()) }, .dns)
    }

    func testRedirectIsRefusedAndNeverFollowed() throws {
        let server = try server { connection in
            connection.respond(status: 307, headers: ["Location": "/elsewhere"], body: "")
        }
        let gateway = gateway(server.url)
        XCTAssertEqual(failure { _ = try gateway.open(id: "r", url: official, headers: [:], body: Data("{}".utf8)) }, .redirectRefused)
        XCTAssertEqual(server.requests.map(\.path), ["/anthropic/v1/messages"])
    }

    func testOfflineErrorsMapToFixedCodes() {
        XCTAssertEqual(ModelGateway.failure(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ModelGateway.failure(for: URLError(.dnsLookupFailed)), .dns)
        XCTAssertEqual(ModelGateway.failure(for: URLError(.networkConnectionLost)), .disconnected)
        XCTAssertEqual(ModelGateway.failure(for: URLError(.secureConnectionFailed)), .tls)
        XCTAssertEqual(ModelGateway.failure(for: URLError(.timedOut)), .timeout)
        XCTAssertEqual(ModelGateway.failure(for: CocoaError(.fileNoSuchFile)), .transport)
    }

    func testProductionGatewayTargetsOnlyTheOfficialEndpoint() {
        let gateway = ModelGateway { nil }
        gateways.append(gateway)
        XCTAssertEqual(gateway.target, ModelGateway.officialURL)
        XCTAssertEqual(ModelGateway.officialURL.absoluteString, "https://api.deepseek.com/anthropic/v1/messages")
    }

    func testRecordsNeverContainTheKeyOrBodies() throws {
        let server = try server { connection in connection.respond(status: 401, body: #"{"error":{"message":"bad key"}}"#) }
        let gateway = gateway(server.url)
        _ = try gateway.open(id: "x", url: official, headers: workerHeaders, body: Data(#"{"secret":"prompt"}"#.utf8))
        _ = try drain(gateway, "x")
        let text = String(decoding: try JSONEncoder().encode(gateway.records), as: UTF8.self)
        for leaked in [realKey, "placeholder", "prompt", "bad key"] { XCTAssertFalse(text.contains(leaked), leaked) }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return condition()
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: Value) { lock.lock(); value = next; lock.unlock() }
}
