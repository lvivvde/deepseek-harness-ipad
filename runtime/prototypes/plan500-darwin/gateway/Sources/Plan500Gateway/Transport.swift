import Foundation

public enum TransportError: Error, CustomStringConvertible {
    /// The guest answered with a non-200 status before doing anything (agent refusals happen before spawn).
    case refused(status: Int, error: String?)
    /// No answer: the request may or may not have reached the guest.
    case unreachable(String)
    public var description: String {
        switch self {
        case .refused(let status, let error): return "refused \(status) \(error ?? "")"
        case .unreachable(let reason): return "unreachable \(reason)"
        }
    }
}

public protocol GuestTransport: AnyObject {
    func rpc(_ route: String, _ body: [String: Any]?) throws -> [String: Any]
}

/// Guest agent RPC over the QEMU user-network host forward. One URLSession per request, so a
/// severed or stale keep-alive connection can never be reused for the next request.
public final class HTTPTransport: GuestTransport {
    private let lock = NSLock()
    private var port = 0
    private var token = ""

    public init() {}

    public func configure(port: Int, token: String) {
        lock.lock(); self.port = port; self.token = token; lock.unlock()
    }

    public func rpc(_ route: String, _ body: [String: Any]?) throws -> [String: Any] {
        lock.lock(); let port = self.port, token = self.token; lock.unlock()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)\(route)") else { throw TransportError.unreachable("NOT_ATTACHED") }
        // /execute answers only when the command ends: wait past the agent's own stop for it.
        let wait = route == "/ready" ? 2 : route == "/execute" ? Double(body?["timeoutMs"] as? Int ?? 15000) / 1000 + 25 : 25
        var request = URLRequest(url: url, timeoutInterval: wait)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = request.timeoutInterval + 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        var outcome: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: request) { data, response, error in outcome = (data, response, error); done.signal() }.resume()
        done.wait()
        if let error = outcome.2 { throw TransportError.unreachable((error as NSError).localizedDescription) }
        guard let response = outcome.1 as? HTTPURLResponse, let data = outcome.0 else { throw TransportError.unreachable("NO_RESPONSE") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard response.statusCode == 200 else { throw TransportError.refused(status: response.statusCode, error: object?["error"] as? String) }
        guard let object else { throw TransportError.unreachable("BAD_JSON") }
        return object
    }
}
