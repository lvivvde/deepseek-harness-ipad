import Foundation

/// Fixed failure codes. They name what happened on the wire and never carry request or response text.
public enum ModelFailure: String, Error, Sendable {
    case endpointRefused = "MODEL_ENDPOINT_REFUSED"
    case keyMissing = "MODEL_KEY_REQUIRED"
    case duplicateStream = "MODEL_STREAM_DUPLICATE"
    case unknownStream = "MODEL_STREAM_UNKNOWN"
    case offline = "MODEL_OFFLINE"
    case dns = "MODEL_DNS"
    case connect = "MODEL_CONNECT"
    case timeout = "MODEL_TIMEOUT"
    case disconnected = "MODEL_DISCONNECTED"
    case tls = "MODEL_TLS"
    case redirectRefused = "MODEL_REDIRECT_REFUSED"
    case cancelled = "MODEL_CANCELLED"
    case transport = "MODEL_TRANSPORT"
}

/// Streams Messages requests from the official Worker to the official DeepSeek endpoint (#39 gate 4).
/// The Worker keeps its own parser, retry policy and errors; this side owns the endpoint, the real key
/// and the HTTP request lifetime. Bytes are handed back in arrival order, never buffered to the end.
public final class ModelGateway: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let officialURL = URL(string: "https://api.deepseek.com/anthropic/v1/messages")!

    /// Worker request headers that may reach the endpoint. Credentials are never taken from the Worker.
    static let forwardedRequestHeaders: Set<String> = ["content-type", "accept", "anthropic-version", "anthropic-beta", "user-agent"]
    static let forwardedRequestPrefix = "x-deepseek-harness-"
    /// Response headers the official error path reads (content type, retry delay, request identity).
    public static let forwardedResponseHeaders = ["content-type", "retry-after", "request-id", "x-request-id", "x-deepseek-request-id"]
    static let maxReadBytes = 1 << 20

    public struct Head: Equatable, Sendable {
        public let status: Int
        public let headers: [String: String]
    }

    public enum Read: Equatable, Sendable {
        case chunk(Data)
        case end
    }

    /// Redacted per-request evidence: timings, counts and the final code only.
    public struct Record: Codable, Equatable, Sendable {
        public let id: String
        public let status: Int?
        public let outcome: String
        public let headMs: Double?
        public let firstChunkMs: Double?
        public let lastChunkMs: Double?
        public let endMs: Double
        public let chunks: Int
        public let bytes: Int
    }

    private final class Stream {
        let id: String
        let opened = Date()
        var task: URLSessionDataTask?
        var head: Head?
        var headAt: Date?
        var buffer = Data()
        var finished = false
        var failure: ModelFailure?
        var cancelled = false
        var redirected = false
        var firstChunk: Date?
        var lastChunk: Date?
        var chunks = 0
        var bytes = 0
        init(id: String) { self.id = id }
    }

    let target: URL
    private let key: () -> String?
    private let condition = NSCondition()
    private var streams: [String: Stream] = [:]
    private var byTask: [Int: Stream] = [:]
    private var earlyCancels: [String] = []
    private var history: [Record] = []
    private var session: URLSession!

    /// Production gateway: always the official endpoint. The idle timeout backs up the Worker's own
    /// stream watchdog and is longer than it, so the official TIMEOUT normally wins.
    public convenience init(idleTimeout: TimeInterval = 330, key: @escaping () -> String?) {
        self.init(target: Self.officialURL, idleTimeout: idleTimeout, key: key)
    }

    /// Test and macOS fault-injection seam; not public, so App builds cannot point it elsewhere.
    init(target: URL, idleTimeout: TimeInterval, key: @escaping () -> String?) {
        self.target = target
        self.key = key
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    public var records: [Record] { condition.lock(); defer { condition.unlock() }; return history }

    /// Ends every request and releases the session; the gateway cannot be used afterwards.
    public func invalidate() { session.invalidateAndCancel() }

    /// Sends one request and blocks until the response head or an explicit failure.
    public func open(id: String, url: String, headers: [String: String], body: Data) throws -> Head {
        guard url == Self.officialURL.absoluteString else { throw ModelFailure.endpointRefused }
        guard let key = key(), !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }) else {
            throw ModelFailure.keyMissing
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers {
            let lower = name.lowercased()
            if Self.forwardedRequestHeaders.contains(lower) || lower.hasPrefix(Self.forwardedRequestPrefix) {
                request.setValue(value, forHTTPHeaderField: lower)
            }
        }
        request.setValue(key, forHTTPHeaderField: "x-api-key")

        condition.lock()
        if let index = earlyCancels.firstIndex(of: id) {
            earlyCancels.remove(at: index)
            condition.unlock()
            throw ModelFailure.cancelled
        }
        guard streams[id] == nil else { condition.unlock(); throw ModelFailure.duplicateStream }
        let stream = Stream(id: id)
        let task = session.dataTask(with: request)
        stream.task = task
        streams[id] = stream
        byTask[task.taskIdentifier] = stream
        condition.unlock()
        task.resume()

        condition.lock(); defer { condition.unlock() }
        while stream.head == nil && stream.failure == nil { condition.wait() }
        if let head = stream.head { return head }
        streams[id] = nil
        throw stream.failure!
    }

    /// Next bytes in arrival order, `.end` after a clean finish, or the failure once buffered bytes are out.
    public func read(_ id: String) throws -> Read {
        condition.lock(); defer { condition.unlock() }
        guard let stream = streams[id] else { throw ModelFailure.unknownStream }
        while stream.buffer.isEmpty && !stream.finished && stream.failure == nil { condition.wait() }
        if !stream.buffer.isEmpty {
            let count = min(stream.buffer.count, Self.maxReadBytes)
            let part = stream.buffer.prefix(count)
            stream.buffer.removeFirst(count)
            return .chunk(Data(part))
        }
        streams[id] = nil
        if let failure = stream.failure { throw failure }
        return .end
    }

    /// Cancels the HTTP request itself. A cancel that wins the race with `open` stops it from sending.
    public func cancel(_ id: String) {
        condition.lock()
        guard let stream = streams[id] else {
            if !earlyCancels.contains(id) { earlyCancels.append(id); if earlyCancels.count > 64 { earlyCancels.removeFirst() } }
            condition.unlock()
            return
        }
        stream.cancelled = true
        let task = stream.task
        condition.unlock()
        task?.cancel()
    }

    static func failure(for error: Error) -> ModelFailure {
        guard let error = error as? URLError else { return .transport }
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: return .offline
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .cannotConnectToHost: return .connect
        case .timedOut: return .timeout
        case .networkConnectionLost: return .disconnected
        case .cancelled: return .cancelled
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: return .tls
        default: return .transport
        }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        condition.lock(); byTask[task.taskIdentifier]?.redirected = true; condition.unlock()
        completionHandler(nil)
        task.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        condition.lock()
        guard let stream = byTask[dataTask.taskIdentifier], !stream.redirected,
              let http = response as? HTTPURLResponse else {
            condition.unlock(); completionHandler(.cancel); return
        }
        var headers: [String: String] = [:]
        for name in Self.forwardedResponseHeaders { if let value = http.value(forHTTPHeaderField: name) { headers[name] = value } }
        stream.head = Head(status: http.statusCode, headers: headers)
        stream.headAt = Date()
        condition.broadcast()
        condition.unlock()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        if let stream = byTask[dataTask.taskIdentifier], !stream.cancelled {
            let now = Date()
            if stream.firstChunk == nil { stream.firstChunk = now }
            stream.lastChunk = now
            stream.chunks += 1
            stream.bytes += data.count
            stream.buffer.append(data)
            condition.broadcast()
        }
        condition.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard let stream = byTask.removeValue(forKey: task.taskIdentifier) else { return }
        if stream.redirected { stream.failure = .redirectRefused }
        else if stream.cancelled { stream.failure = .cancelled; stream.buffer = Data() }
        else if let error { stream.failure = Self.failure(for: error) }
        else if stream.head == nil { stream.failure = .transport }
        else { stream.finished = true }
        let ms = { (date: Date?) in date.map { $0.timeIntervalSince(stream.opened) * 1000 } }
        history.append(Record(id: stream.id, status: stream.head?.status, outcome: stream.failure?.rawValue ?? "END",
                              headMs: ms(stream.headAt), firstChunkMs: ms(stream.firstChunk), lastChunkMs: ms(stream.lastChunk),
                              endMs: Date().timeIntervalSince(stream.opened) * 1000, chunks: stream.chunks, bytes: stream.bytes))
        if history.count > 64 { history.removeFirst(history.count - 64) }
    }
}
