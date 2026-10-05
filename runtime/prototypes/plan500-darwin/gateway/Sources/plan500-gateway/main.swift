import Foundation
import Plan500Gateway

// JSON-lines server for the research harness: one request per stdin line, one reply per stdout
// line. Requests run concurrently (a leased command blocks for its whole duration); replies are
// written one at a time. Not a product interface.

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let key = arguments.next(), let value = arguments.next() { options[key] = value }
guard let workspace = options["--workspace"], let state = options["--state"], let identity = options["--identity"] else {
    FileHandle.standardError.write("usage: plan500-gateway --workspace DIR --state DIR --identity ID\n".data(using: .utf8)!)
    exit(2)
}

let transport = HTTPTransport()
let gateway: Gateway
do { gateway = try Gateway(workspace: workspace, state: state, identity: identity, transport: transport) }
catch { FileHandle.standardError.write("gateway: \(error)\n".data(using: .utf8)!); exit(1) }

let output = DispatchQueue(label: "plan500.output")
let work = DispatchQueue(label: "plan500.work", attributes: .concurrent)
let inFlight = DispatchGroup()

func reply(_ object: [String: Any]) {
    output.sync {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"error":"ENCODE"}"#.utf8)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

func handle(_ method: String, _ params: [String: Any]) throws -> Any {
    func path(_ params: [String: Any]) throws -> RelativePath { try RelativePath(json: params["path"] ?? NSNull()) }
    switch method {
    case "attach":
        transport.configure(port: params["port"] as? Int ?? 0, token: params["token"] as? String ?? "")
        return try gateway.attach()
    case "state":
        let (state, ack) = gateway.snapshot()
        return ["s": try JSONSerialization.jsonObject(with: try JSONEncoder().encode(state)), "guestAck": ack]
    case "version":
        return ["version": gateway.version(try path(params)) as Any? ?? NSNull()]
    case "nativeWrite":
        guard let encoded = params["data"] as? String, let data = Data(base64Encoded: encoded) else { throw WorkspaceError.pathRefused("BAD_DATA") }
        return try gateway.nativeWrite(try path(params), data, base: params["base"] as? String)
    case "acquire":
        guard let lease = try gateway.acquire(params["operation"] as? String ?? UUID().uuidString) else { return NSNull() }
        return ["op": lease.op, "epoch": lease.epoch, "fence": lease.fence, "state": lease.state]
    case "runLeased":
        return try gateway.runLeased(params["operation"] as? String ?? UUID().uuidString, argv: params["argv"] as? [String] ?? [],
                                     timeout: params["timeout"] as? Int ?? 10000, test: params["test"] as? [String: Any] ?? [:])
    case "reconcile":
        return try gateway.reconcile(vmExited: params["vmExited"] as? Bool ?? false)
    default:
        throw WorkspaceError.pathRefused("UNKNOWN_METHOD")
    }
}

reply(["ready": true, "pid": Int(getpid())])
while let line = readLine(strippingNewline: true) {
    guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let id = request["id"], let method = request["method"] as? String else { reply(["error": "BAD_REQUEST"]); continue }
    let params = request["params"] as? [String: Any] ?? [:]
    work.async(group: inFlight) {
        do { reply(["id": id, "result": try handle(method, params)]) }
        catch { reply(["id": id, "error": "\(error)"]) }
    }
}
inFlight.wait()
