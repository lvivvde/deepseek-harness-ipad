import Darwin
import Foundation

/// Loopback HTTP/1.1 server whose every connection runs a scripted fault. One thread per connection.
final class FaultServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    let port: UInt16
    private let listener: Int32
    private let script: @Sendable (FaultConnection) -> Void
    private let lock = NSLock()
    private var captured: [Request] = []
    private var stopped = false

    init(_ script: @escaping @Sendable (FaultConnection) -> Void) throws {
        self.script = script
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/anthropic/v1/messages")! }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return captured }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        shutdown(listener, SHUT_RDWR); close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { lock.lock(); let done = stopped; lock.unlock(); if done { return }; continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in
                guard let request = FaultConnection.readRequest(client) else { close(client); return }
                lock.lock(); captured.append(request); lock.unlock()
                let connection = FaultConnection(fd: client, request: request)
                script(connection)
                connection.close()
            }
        }
    }
}

final class FaultConnection: @unchecked Sendable {
    let request: FaultServer.Request
    private let fd: Int32
    private var closed = false

    init(fd: Int32, request: FaultServer.Request) { self.fd = fd; self.request = request }

    static func readRequest(_ fd: Int32) -> FaultServer.Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }
        let end = data.range(of: Data("\r\n\r\n".utf8))!
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[end.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < length {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            body.append(buffer, count: count)
        }
        return .init(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    @discardableResult
    func send(_ text: String) -> Bool { send(Data(text.utf8)) }

    @discardableResult
    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if sent <= 0 { return false }
                offset += sent
            }
            return true
        }
    }

    /// Head for a chunked event stream; follow with `chunk` and `end`.
    func streamHead(status: Int = 200, headers: [String: String] = [:]) {
        var text = "HTTP/1.1 \(status) X\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        send(text + "\r\n")
    }

    @discardableResult
    func chunk(_ text: String) -> Bool { send(String(Data(text.utf8).count, radix: 16) + "\r\n" + text + "\r\n") }

    func end() { send("0\r\n\r\n") }

    func respond(status: Int, headers: [String: String] = [:], body: String) {
        var text = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        send(text + "\r\n" + body)
    }

    /// True once the client closed its side, which is how a cancelled HTTP request looks on the wire.
    func waitForPeerClose(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 50)
            if ready > 0 {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count <= 0 { return true }
            }
        }
        return false
    }

    /// Abrupt reset, so the client sees a lost connection rather than a clean end.
    func reset() {
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
