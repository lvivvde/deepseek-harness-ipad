import SwiftUI
import WebKit

@MainActor
final class PreviewController: ObservableObject {
    @Published private(set) var servers: [PreviewServer] = []
    @Published var prompt: PreviewServer?
    @Published var request: PreviewRequest?
    @Published var nativeURL: URL?
    private var announced = Set<Int>()
    private var forwarded = Set(RuntimePorts.previewFallback)
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration, delegate: LocalRedirectPolicy(), delegateQueue: nil)
    }()

    private struct Catalog: Decodable {
        struct Port: Decodable { let port: Int; let relayPort: Int }
        let ports: [Port]
    }

    func monitor() async {
        while !Task.isCancelled {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(RuntimePorts.previewCatalog)/ports")!)
            request.setValue(ProjectTransfer.sessionToken, forHTTPHeaderField: "X-Harness-Transfer")
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw QemuControl.Failure.unavailable }
                let catalog = try JSONDecoder().decode(Catalog.self, from: data)
                var live: [PreviewServer] = []
                for item in catalog.ports where PreviewServer.accepts(port: item.port) && (40000..<40100).contains(item.relayPort) {
                    if !forwarded.contains(item.port) {
                        let command = "hostfwd_add net0 tcp:127.0.0.1:\(item.port)-10.0.2.15:\(item.relayPort)"
                        if let result = try? await QemuControl.shared.monitor(command), result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            forwarded.insert(item.port)
                        }
                    }
                    if forwarded.contains(item.port) { live.append(PreviewServer(port: item.port, hostPort: item.port)) }
                }
                guard !Task.isCancelled else { return }
                servers = live
                for server in live where !announced.contains(server.port) {
                    announced.insert(server.port)
                    if prompt == nil { prompt = server }
                }
            } catch {
                // Boot forwards always exist even if discovery/control is temporarily unavailable.
                if servers.isEmpty { servers = RuntimePorts.previewFallback.map { PreviewServer(port: $0, hostPort: $0) } }
            }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        }
    }

    func open(_ server: PreviewServer) { prompt = nil; request = PreviewRequest(url: server.url) }
}

struct NativePreviewPanel: View {
    let url: URL
    let close: () -> Void
    @State private var revision = 0
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("预览 · \(url.port ?? 0)").font(.headline)
                Spacer()
                Button { failed = false; revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                Button("关闭", action: close)
            }.padding().background(Color(uiColor: .secondarySystemBackground))
            ZStack {
                PreviewWebView(url: url, revision: revision, failed: { failed = true })
                if failed {
                    VStack(spacing: 12) {
                        Text("开发服务器暂时不可用，请确认项目中的服务仍在运行。")
                        Button("重新连接") { failed = false; revision += 1 }
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemBackground))
                }
            }
        }.background(Color(uiColor: .systemBackground))
    }
}

private struct PreviewWebView: UIViewRepresentable {
    let url: URL
    let revision: Int
    let failed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let page = WKWebView()
        page.navigationDelegate = context.coordinator
        context.coordinator.load(page)
        return page
    }
    func updateUIView(_ page: WKWebView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.load(page)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var owner: PreviewWebView
        var loadedRevision = -1
        var loadedURL: URL?
        init(_ owner: PreviewWebView) { self.owner = owner }
        func load(_ page: WKWebView) {
            guard loadedURL != owner.url || loadedRevision != owner.revision else { return }
            loadedURL = owner.url; loadedRevision = owner.revision
            page.load(URLRequest(url: owner.url))
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { owner.failed() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { owner.failed() }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame == true, let target = action.request.url else { decisionHandler(.allow); return }
            decisionHandler(target.scheme == "http" && target.host == "127.0.0.1" && target.port == owner.url.port ? .allow : .cancel)
        }
    }
}
