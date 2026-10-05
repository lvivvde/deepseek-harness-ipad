import Darwin
import Foundation

/// Research transport for Darwin libslirp's backlog of one. Serialize only connect + a
/// complete unauthenticated 403 round trip; authenticated requests may then run concurrently.
/// No retry: a lost reply to a side effect must remain WRITER_UNKNOWN at the gateway.
public final class GatedTransport: GuestTransport {
    private let gate = NSLock()
    private let port: UInt16
    private let token: String
    private let timeout: Int

    public init(port: UInt16, token: String, timeout: Int = 30) {
        self.port = port; self.token = token; self.timeout = timeout
    }

    public func rpc(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
        guard route.hasPrefix("/"), !route.contains("\r"), !route.contains("\n"),
              !token.contains("\r"), !token.contains("\n") else { throw TransportError.unreachable("REQUEST_REFUSED") }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        guard data.count <= 131072 else { throw TransportError.unreachable("BODY_TOO_LARGE") }
        let stream: LoopbackHTTP
        gate.lock()
        do {
            stream = try LoopbackHTTP(port: port, timeout: route == "/ready" ? 2 : timeout)
            try stream.send(Data("GET /plan500-gate HTTP/1.1\r\nHost: guest\r\n\r\n".utf8))
            let proof = try stream.response()
            guard proof.0 == 403,
                  (try? JSONSerialization.jsonObject(with: proof.1) as? [String: String])?["error"] == "AUTH_REFUSED"
            else { throw TransportError.unreachable("GATE_UNEXPECTED") }
            gate.unlock()
        } catch { gate.unlock(); throw error }
        let method = body == nil ? "GET" : "POST"
        let head = "\(method) \(route) HTTP/1.1\r\nHost: guest\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        try stream.send(Data(head.utf8) + data)
        let (status, response) = try stream.response()
        let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        guard status == 200 else { throw TransportError.refused(status: status, error: object?["error"] as? String) }
        guard let object else { throw TransportError.unreachable("BAD_JSON") }
        return object
    }
}

/// Bounded HTTP/1.1 reader: consumes the whole proof body before reusing the connection.
/// Node's agent uses chunked encoding; tests also cover Content-Length and split frames.
final class LoopbackHTTP {
    private let fd: Int32
    private var buffer = Data()
    private let deadline: Date
    private let maximum = 4 * 1024 * 1024

    init(port: UInt16, timeout: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.unreachable("SOCKET_FAILED") }
        deadline = Date().addingTimeInterval(Double(timeout))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        // Nonblocking connect bounds even a full accept queue; restore blocking I/O afterwards.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { close(fd); throw TransportError.unreachable("CONNECT_FAILED") }
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&event, 1, Int32(timeout * 1000)) > 0,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                close(fd); throw TransportError.unreachable("CONNECT_FAILED")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
    }

    deinit { close(fd) }

    private func remaining() throws {
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else { throw TransportError.unreachable("TIMEOUT") }
        var limit = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try remaining()
                let count = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TransportError.unreachable("SEND_FAILED") }
                offset += count
            }
        }
    }

    private func receive() throws {
        try remaining()
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0 && errno == EINTR { return try receive() }
        guard count > 0 else { throw TransportError.unreachable("RESPONSE_LOST") }
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count <= maximum else { throw TransportError.unreachable("RESPONSE_TOO_LARGE") }
    }

    private func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= maximum else { throw TransportError.unreachable("FRAME_TOO_LARGE") }
        while buffer.count < count { try receive() }
        let part = Data(buffer.prefix(count)); buffer.removeFirst(count); return part
    }

    private func line() throws -> String {
        let delimiter = Data([13, 10])
        while buffer.range(of: delimiter) == nil {
            guard buffer.count < 16384 else { throw TransportError.unreachable("HEADER_TOO_LARGE") }
            try receive()
        }
        let end = buffer.range(of: delimiter)!.lowerBound
        let bytes = try take(buffer.distance(from: buffer.startIndex, to: end))
        _ = try take(2)
        guard let value = String(data: bytes, encoding: .utf8) else { throw TransportError.unreachable("BAD_HEADER") }
        return value
    }

    func response() throws -> (Int, Data) {
        let status = try line().split(separator: " ")
        guard status.count >= 2, status[0] == "HTTP/1.1", let code = Int(status[1]) else { throw TransportError.unreachable("BAD_STATUS") }
        var headers: [String: String] = [:], headerBytes = 0
        while true {
            let value = try line(); headerBytes += value.utf8.count + 2
            guard headerBytes <= 16384 else { throw TransportError.unreachable("HEADER_TOO_LARGE") }
            if value.isEmpty { break }
            guard let colon = value.firstIndex(of: ":") else { throw TransportError.unreachable("BAD_HEADER") }
            let key = value[..<colon].lowercased()
            guard headers[key] == nil else { throw TransportError.unreachable("DUPLICATE_HEADER") }
            headers[key] = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { throw TransportError.unreachable("BAD_FRAME") }
            var body = Data()
            while true {
                let size = try line().split(separator: ";", maxSplits: 1).first
                guard let size, let count = Int(size, radix: 16), count >= 0, count <= maximum - body.count else { throw TransportError.unreachable("BAD_CHUNK") }
                if count == 0 {
                    var trailers = 0
                    while !(try line()).isEmpty {
                        trailers += 1
                        guard trailers <= 32 else { throw TransportError.unreachable("BAD_TRAILER") }
                    }
                    return (code, body)
                }
                body.append(try take(count))
                guard try take(2) == Data([13, 10]) else { throw TransportError.unreachable("BAD_CHUNK") }
            }
        }
        guard let length = headers["content-length"], let count = Int(length) else { throw TransportError.unreachable("UNFRAMED_RESPONSE") }
        return (code, try take(count))
    }
}
