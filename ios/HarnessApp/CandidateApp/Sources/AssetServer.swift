import Foundation
import Network

/// Serves the candidate web root (the official frontend, the patched Worker and its VFS image) on a
/// loopback port, so the Worker loads as a module from an http origin. GET only; anything outside the
/// root, and the server routes the official page asks for but the candidate does not have, answer 404.
final class AssetServer {
    let root: URL
    private let queue = DispatchQueue(label: "candidate.assets")
    private var listener: NWListener?

    init(root: URL) { self.root = root.resolvingSymlinksInPath() }

    static let types = [
        "html": "text/html; charset=utf-8", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "webmanifest": "application/manifest+json", "svg": "image/svg+xml",
        "png": "image/png", "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf",
        "wasm": "application/wasm", "gz": "application/gzip", "txt": "text/plain; charset=utf-8",
    ]

    func start(_ ready: @escaping (Result<URL, Error>) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        var delivered = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !delivered, let port = listener.port { delivered = true; ready(.success(URL(string: "http://127.0.0.1:\(port)/")!)) }
            case .failed(let error):
                if !delivered { delivered = true; ready(.failure(error)) }
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, Data())
        }
        listener.start(queue: queue)
    }

    /// The file a request path names, or nil when it is not a file inside the root.
    func file(for target: Substring) -> URL? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard path.hasPrefix("/"), let decoded = String(path).removingPercentEncoding,
              !decoded.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return nil }
        let relative = decoded == "/" ? "index.html" : String(decoded.dropFirst())
        // Symlinks are resolved so a link inside the root cannot serve a file outside it.
        let url = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard url.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
        return url
    }

    private func receive(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var request = accumulated
            if let data { request.append(data) }
            guard request.count <= 16384, error == nil else { connection.cancel(); return }
            guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { receive(connection, request) }
                return
            }
            let line = String(decoding: request[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            let response: Data
            if line.count == 3, line[0] == "GET", let url = file(for: line[1]), let bytes = try? Data(contentsOf: url) {
                let type = Self.types[url.pathExtension.lowercased()] ?? "application/octet-stream"
                var head = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
                head.append(bytes)
                response = head
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    deinit { listener?.cancel() }
}
