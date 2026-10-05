import Darwin
import Foundation
import XCTest
@testable import Plan500Gateway

/// A real loopback listener with backlog one; no mocked transport. The accept loop pauses
/// after each accept, like a busy TCG main loop, and connections remain independently usable.
private final class AgentServer {
    let listener: Int32
    let port: UInt16
    let done = DispatchGroup()
    let lock = NSLock()
    var executed = 0
    let slowStarted = DispatchSemaphore(value: 0)
    let cancelArrived = DispatchSemaphore(value: 0)
    var malformedGate = false

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        guard bound == 0, listen(listener, 1) == 0 else { close(listener); throw TransportError.unreachable("TEST_LISTEN") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &size)
        } }
        port = UInt16(bigEndian: address.sin_port)
        done.enter()
        DispatchQueue.global().async { [self] in
            defer { done.leave() }
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var enabled: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                done.enter()
                DispatchQueue.global().async { [self] in defer { close(client); done.leave() }; serve(client) }
                usleep(50_000)
            }
        }
    }

    func closeServer() {
        shutdown(listener, SHUT_RDWR); close(listener)
        _ = done.wait(timeout: .now() + 6)
    }

    func request(_ fd: Int32) -> String? {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while data.count < 200_000 {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count <= 0 { return nil }
            data.append(contentsOf: bytes.prefix(count))
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count >= data.distance(from: data.startIndex, to: end.upperBound) + length { return head }
            }
        }
        return nil
    }

    func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if count <= 0 { return }
                offset += count
            }
        }
    }

    func serve(_ fd: Int32) {
        guard let proof = request(fd), proof.hasPrefix("GET /plan500-gate "), !proof.contains("Authorization:") else { return }
        let payload = Data("{\"error\":\"AUTH_REFUSED\"}".utf8)
        send(fd, Data("HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\n\r\n\(String(payload.count, radix: 16))\r\n".utf8))
        // Deliberately split the proof's body and final chunk; it must all be drained.
        send(fd, payload.prefix(7)); usleep(1000); send(fd, payload.dropFirst(7))
        send(fd, Data(malformedGate ? "\r\n!\r\n".utf8 : "\r\n0\r\n\r\n".utf8))
        guard let call = request(fd), call.contains("Authorization: Bearer test-token") else { return }
        let route = call.split(separator: " ")[1]
        if route == "/execute" { lock.lock(); executed += 1; lock.unlock(); return } // lost side-effect reply
        if route == "/slow" { slowStarted.signal(); _ = cancelArrived.wait(timeout: .now() + 3) }
        if route == "/cancel" { cancelArrived.signal() }
        if route == "/refuse" {
            let data = Data("{\"error\":\"LEASE_STALE\"}".utf8)
            send(fd, Data("HTTP/1.1 409 Conflict\r\nContent-Length: \(data.count)\r\n\r\n".utf8) + data); return
        }
        let answer = Data("{\"ok\":true,\"text\":\"中文\"}".utf8)
        send(fd, Data("HTTP/1.1 200 OK\r\nContent-Length: \(answer.count)\r\n\r\n".utf8) + answer)
    }
}

final class GatedTransportTests: XCTestCase {
    func testConcurrentConnectionsWithBacklogOneAndSplitProof() throws {
        let server = try AgentServer(); defer { server.closeServer() }
        let transport = GatedTransport(port: server.port, token: "test-token", timeout: 5)
        let lock = NSLock(); var passed = 0, errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                let result = try transport.rpc("/ready", nil)
                lock.lock(); if result["text"] as? String == "中文" { passed += 1 }; lock.unlock()
            } catch { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
        }
        XCTAssertEqual(passed, 12); XCTAssertEqual(errors, [])
    }

    func testGateDoesNotSerializeSlowRequestsAndCancellation() throws {
        let server = try AgentServer(); defer { server.closeServer() }
        let transport = GatedTransport(port: server.port, token: "test-token", timeout: 5)
        let complete = expectation(description: "slow request completed")
        DispatchQueue.global().async {
            do { XCTAssertEqual(try transport.rpc("/slow", [:])["ok"] as? Bool, true) }
            catch { XCTFail(String(describing: error)) }
            complete.fulfill()
        }
        XCTAssertEqual(server.slowStarted.wait(timeout: .now() + 2), .success)
        let start = Date()
        XCTAssertEqual(try transport.rpc("/cancel", [:])["ok"] as? Bool, true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        wait(for: [complete], timeout: 3)
    }

    func testLostExecuteIsNotRetriedAndGatewayKeepsLease() throws {
        let server = try AgentServer(); defer { server.closeServer() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        let transport = GatedTransport(port: server.port, token: "test-token", timeout: 2)
        let gateway = try Gateway(workspace: root.appendingPathComponent("workspace").path,
                                  state: root.appendingPathComponent("state").path, identity: "test", transport: transport)
        XCTAssertEqual(try gateway.runLeased("one", argv: ["/bin/sh", "-c", "true"], timeout: 1000)["status"] as? String, "WRITER_UNKNOWN")
        XCTAssertEqual(gateway.snapshot().0.lease?.state, "WRITER_UNKNOWN")
        server.lock.lock(); let count = server.executed; server.lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testFramedRefusalAndMalformedProof() throws {
        let server = try AgentServer(); defer { server.closeServer() }
        let transport = GatedTransport(port: server.port, token: "test-token", timeout: 2)
        XCTAssertThrowsError(try transport.rpc("/refuse", [:])) { error in
            guard case TransportError.refused(let status, let reason) = error else { return XCTFail("wrong refusal: \(error)") }
            XCTAssertEqual(status, 409); XCTAssertEqual(reason, "LEASE_STALE")
        }
        server.malformedGate = true
        XCTAssertThrowsError(try transport.rpc("/execute", [:]))
        server.lock.lock(); let count = server.executed; server.lock.unlock()
        XCTAssertEqual(count, 0)
    }
}
