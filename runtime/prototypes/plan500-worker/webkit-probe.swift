// Throwaway macOS WKWebView harness. It never loads the installed iPad app.
import Cocoa
import WebKit
import CryptoKit

final class Probe: NSObject, WKScriptMessageHandler {
    let directory: URL
    var view: WKWebView!
    var failNext = false
    init(directory: URL) { self.directory = directory }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "log" {
            if let bytes = try? JSONSerialization.data(withJSONObject: body), let text = String(data: bytes, encoding: .utf8) {
                FileHandle.standardError.write(Data((text + "\n").utf8))
            }
            return
        }
        guard let id = body["id"] as? Int, let operation = body["operation"] as? String else { return }
        var result: [String: Any] = [:]
        do {
            let checkpoint = directory.appendingPathComponent("checkpoint.json")
            switch operation {
            case "checkpoint":
                if failNext { failNext = false; throw NSError(domain: "PROTOTYPE_PERSISTENCE_REFUSED", code: 1) }
                guard let snapshot = body["snapshot"] as? [String: Any], snapshot["formatVersion"] as? Int == 1,
                      let files = snapshot["files"] as? [[String: Any]],
                      let dirs = snapshot["directories"] as? [[String: Any]] else {
                    throw NSError(domain: "PROTOTYPE_SNAPSHOT_REFUSED", code: 1)
                }
                for entry in files + dirs {
                    guard let path = entry["path"] as? String,
                          !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                          ["/dsh/home", "/dsh/workspace"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                        throw NSError(domain: "PROTOTYPE_PATH_REFUSED", code: 1)
                    }
                }
                let bytes = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
                try bytes.write(to: checkpoint, options: .atomic)
                let handle = try FileHandle(forWritingTo: checkpoint)
                try handle.synchronize(); try handle.close()
                guard try Data(contentsOf: checkpoint) == bytes else { throw NSError(domain: "PROTOTYPE_READBACK_FAILED", code: 1) }
                result = ["durable": true, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
            case "readCheckpoint":
                result = ["snapshot": try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint))]
            case "failNextCheckpoint":
                failNext = true; result = ["accepted": true]
            case "done":
                guard let receipt = body["result"] as? [String: Any] else { return }
                let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                try bytes.write(to: directory.appendingPathComponent("webkit-safe.json"), options: .atomic)
                print(String(data: bytes, encoding: .utf8)!)
                exit(receipt["passed"] as? Bool == true ? 0 : 1)
            default: throw NSError(domain: "PROTOTYPE_OPERATION_REFUSED", code: 1)
            }
        } catch { result = ["error": (error as NSError).domain] }
        let bytes = try! JSONSerialization.data(withJSONObject: result)
        let json = String(data: bytes, encoding: .utf8)!
        view.evaluateJavaScript("window.prototypeNativeReply(\(id), \(json))", completionHandler: nil)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let probe = Probe(directory: directory)
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
config.userContentController.add(probe, name: "native")
config.userContentController.add(probe, name: "log")
config.userContentController.addUserScript(WKUserScript(source: """
window.addEventListener('error', e => window.webkit.messageHandlers.log.postMessage({pageError: String(e.message), source: e.filename, line: e.lineno}));
window.addEventListener('unhandledrejection', e => window.webkit.messageHandlers.log.postMessage({rejection: String(e.reason)}));
""", injectionTime: .atDocumentStart, forMainFrameOnly: true))
probe.view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
let window = NSWindow(contentRect: probe.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "PROTOTYPE: isolated Harness Worker"
window.contentView = probe.view
probe.view.load(URLRequest(url: URL(string: CommandLine.arguments[1])!))
DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
    fputs("PROTOTYPE_TIMEOUT\n", stderr); exit(2)
}
application.run()
