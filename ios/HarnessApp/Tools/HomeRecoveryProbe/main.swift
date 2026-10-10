import Foundation
import Darwin
import HarnessCandidate
import HarnessHost
import LinuxPlugin
import NativeWorkspace

// JSON-lines adapter for cross-language contract and crash tests; synthetic temporary roots only.
final class NoMachine: GuestMachine, GuestRPC {
    var rpc: GuestRPC { self }; var exited = false; var onExit: ((Int32?) -> Void)?
    func boot(workspace: String) throws { fatalError("recovery must not boot Linux") }
    func stop() {}
    func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any] { fatalError("recovery must not replay commands") }
}
let root = CommandLine.arguments[1]
var interruption: String?
var crash = false
var skip = 0
let hook: FaultHook = { point in
    if point.description == interruption {
        if skip > 0 { skip -= 1; return }
        if crash { kill(getpid(), SIGKILL) }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    }
}
func makeHost() throws -> CandidateHost {
    CandidateHost(registry: try ProjectRegistry(root: root), machine: NoMachine(), availability: .unavailable(.privateSymbolMissing),
                  gitScripts: [], recoveryFault: hook)
}
var host = try makeHost()
while let line = readLine() {
    do {
        let body = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let result: [String: Any]
        switch body["operation"] as? String {
        case "probe-restart": host = try makeHost(); result = [:]
        case "probe-fault": interruption = body["point"] as? String; skip = body["skip"] as? Int ?? 0; crash = body["crash"] as? Bool ?? false; result = [:]
        default: result = host.handle(body)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        fflush(stdout)
    } catch { print("{\"error\":\"PROBE_FAILED\"}"); fflush(stdout) }
}
