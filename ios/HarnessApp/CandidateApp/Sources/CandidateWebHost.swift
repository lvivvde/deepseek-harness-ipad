import Foundation
import HarnessCandidate
import AppKit
import WebKit

/// The official frontend and Worker in one WKWebView. Every native call the Worker's bridge makes is
/// answered by `CandidateHost` with one JSON string; the Worker never sees the key or the workspace.
@MainActor
final class CandidateWebHost: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let host: CandidateHost
    let assets: AssetServer
    let view: WKWebView
    private let logs: URL
    /// The latest Worker event name, for the status line.
    var onEvent: ((String) -> Void)?
    /// Native calls can block (a Linux command, a model read); they never run on the main thread.
    private let calls = DispatchQueue(label: "candidate.native", qos: .userInitiated, attributes: .concurrent)
    private var started = false
    /// The asset server's origin. Only this page may navigate the view or call the handlers; any other
    /// page (a link in model output, a redirect) would otherwise inherit the project tools and the key.
    private var origin: URL?
    private static let logLimit = 8 << 20

    init(host: CandidateHost, webRoot: URL, logs: URL) {
        self.host = host; assets = AssetServer(root: webRoot); self.logs = logs
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // A covered or minimised window must not stall the Worker's long timers (model retry backoff,
        // checkpoints). KVC reaches WebKit's `_set…` preference setters.
        // KVC on a key WebKit no longer has raises an Objective-C exception, so each setter is checked first.
        for key in ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageDOMTimerThrottlingAutoIncreases",
                    "pageVisibilityBasedProcessSuppressionEnabled"]
        where config.preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased() + key.dropFirst()):")) {
            config.preferences.setValue(false, forKey: key)
        }
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "native")
        config.userContentController.add(self, name: "log")
    }

    /// Loads the page once; later project opens are forwarded with `projectOpened`.
    func start(_ failed: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        do {
            try assets.start { [weak self] answer in
                DispatchQueue.main.async {
                    switch answer {
                    case .success(let url): self?.origin = url; self?.view.load(URLRequest(url: url))
                    case .failure: failed("ASSET_SERVER_FAILED")
                    }
                }
            }
        } catch {
            failed("ASSET_SERVER_FAILED")
        }
    }

    /// A project the user opened natively after the page loaded becomes a workspace in the Worker. A
    /// page that has not installed yet picks it up from the `projects` call instead.
    func projectOpened(_ project: [String: Any]) {
        guard started, let data = try? JSONSerialization.data(withJSONObject: project) else { return }
        view.evaluateJavaScript("window.candidateProjectOpened?.(\(String(decoding: data, as: UTF8.self)))")
    }

    private func trusted(_ url: URL?) -> Bool {
        guard let origin, let url else { return false }
        return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
    }

    private func trusted(_ frame: WKFrameInfo) -> Bool {
        let source = frame.securityOrigin
        return frame.isMainFrame && source.protocol == origin?.scheme && source.host == origin?.host && source.port == origin?.port
    }

    /// The view stays on the asset origin. A link the user follows opens in their browser instead.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Frames below the page cannot reach the handlers, so only the page itself is held to the origin.
        if action.targetFrame?.isMainFrame == false || trusted(action.request.url) { return .allow }
        openExternally(action)
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openExternally(action)
        return nil
    }

    private func openExternally(_ action: WKNavigationAction) {
        guard action.navigationType == .linkActivated || action.targetFrame == nil, let url = action.request.url,
              url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard trusted(message.frameInfo), let body = message.body as? [String: Any] else {
            replyHandler(nil, "REQUEST_REFUSED"); return
        }
        let host = self.host
        nonisolated(unsafe) let request = body
        calls.async {
            let result = host.handle(request)
            let text = JSONSerialization.isValidJSONObject(result)
                ? (try? JSONSerialization.data(withJSONObject: result)).map { String(decoding: $0, as: UTF8.self) } : nil
            Task { @MainActor in
                if let text { replyHandler(text, nil) } else { replyHandler(nil, "REPLY_REFUSED") }
            }
        }
    }

    /// Worker diagnostics: each entry and the file are bounded, appended to the private log directory,
    /// never shown with their details. A full log rolls over to `worker-private.1.log`.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard trusted(message.frameInfo), let body = message.body as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 65536 else { return }
        let event = (body["event"] as? String).map { String($0.prefix(64)) } ?? "log"
        append(data)
        onEvent?(event)
    }

    private func append(_ line: Data) {
        let url = logs.appendingPathComponent("worker-private.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= Self.logLimit {
            let previous = logs.appendingPathComponent("worker-private.1.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data("\n".utf8))
    }
}
