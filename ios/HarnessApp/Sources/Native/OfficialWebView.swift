import SwiftUI
import WebKit

/// A permanent root page, not a dismissible browser sheet.
struct OfficialWebView: UIViewRepresentable {
    let destination: URL
    let revision: Int
    let onLoading: () -> Void
    let onPaint: () -> Void
    let onFailure: () -> Void
    let onContentTerminated: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let configuration = WKWebViewConfiguration()
        let scripts = configuration.userContentController
        scripts.addUserScript(WKUserScript(source: Self.paintScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: Self.stopTapScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        scripts.add(context.coordinator, name: "appPaint")
        let container = UIView()
        container.backgroundColor = .systemBackground
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.translatesAutoresizingMaskIntoConstraints = false
        page.scrollView.keyboardDismissMode = .interactive
        page.navigationDelegate = context.coordinator
        page.uiDelegate = context.coordinator
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        context.coordinator.page = page
        context.coordinator.load(destination, revision: revision)
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.load(destination, revision: revision)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.paintTimeout?.cancel()
        coordinator.page?.configuration.userContentController.removeScriptMessageHandler(forName: "appPaint")
        // The App's runtime remains alive. Only page resources belong here.
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var owner: OfficialWebView
        weak var page: WKWebView?
        var paintTimeout: Task<Void, Never>?
        private var lastDestination: URL?
        private var lastRevision = -1
        private var painted = false
        private var children: [UIView] = []

        init(_ owner: OfficialWebView) { self.owner = owner }

        func load(_ destination: URL, revision: Int) {
            guard lastDestination != destination || lastRevision != revision else { return }
            lastDestination = destination
            lastRevision = revision
            painted = false
            paintTimeout?.cancel()
            DispatchQueue.main.async { [weak self] in self?.owner.onLoading() }
            page?.load(URLRequest(url: destination))
            paintTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 120_000_000_000) }
                catch { return }
                guard let self, !painted else { return }
                owner.onFailure()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === page, message.frameInfo.isMainFrame,
                  message.body as? String == "ready", !painted else { return }
            painted = true
            paintTimeout?.cancel()
            owner.onPaint()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === page else { return }
            owner.onLoading()
            owner.onContentTerminated()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard webView === page, (error as NSError).code != NSURLErrorCancelled else { return }
            paintTimeout?.cancel()
            owner.onFailure()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard webView === page else { return }
            paintTimeout?.cancel()
            owner.onFailure()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard webView === page, navigationAction.targetFrame?.isMainFrame == true,
                  let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if HarnessEndpoint.isLocalPage(url) { decisionHandler(.allow); return }
            if navigationAction.navigationType == .linkActivated { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil, let page else { return nil }
            let panel = UIView()
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.backgroundColor = .systemBackground
            let child = WKWebView(frame: .zero, configuration: configuration)
            child.translatesAutoresizingMaskIntoConstraints = false
            child.uiDelegate = self
            child.navigationDelegate = self
            let close = UIButton(type: .system)
            close.translatesAutoresizingMaskIntoConstraints = false
            close.setTitle("返回 Harness", for: .normal)
            close.addAction(UIAction { [weak self, weak panel, weak child] _ in
                child?.stopLoading()
                panel?.removeFromSuperview()
                self?.children.removeAll { $0 === panel }
            }, for: .touchUpInside)
            panel.addSubview(close)
            panel.addSubview(child)
            page.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: page.topAnchor),
                panel.bottomAnchor.constraint(equalTo: page.bottomAnchor),
                panel.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: page.trailingAnchor),
                close.topAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.topAnchor),
                close.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
                close.heightAnchor.constraint(equalToConstant: 44),
                child.topAnchor.constraint(equalTo: close.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
            ])
            children.append(panel)
            return child
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard webView !== page else { return }
            let panel = webView.superview
            panel?.removeFromSuperview()
            children.removeAll { $0 === panel }
        }
    }

    private static let paintScript = """
    (() => {
      let done = false;
      const check = () => {
        const root = document.getElementById('root');
        if (done || !root || !(root.innerText || '').trim()) return;
        done = true;
        observer.disconnect();
        requestAnimationFrame(() => requestAnimationFrame(() => {
          window.webkit.messageHandlers.appPaint.postMessage('ready');
        }));
      };
      const observer = new MutationObserver(check);
      observer.observe(document, {childList: true, subtree: true, characterData: true});
      document.addEventListener('DOMContentLoaded', check);
    })();
    """

    // Retain the independently verified iPad stop-button fix until upstream fixes it.
    private static let stopTapScript = """
    (() => {
      const stop = t => t instanceof Element && t.closest('button[aria-label="停止生成"],button[aria-label="Stop generating"]');
      let start = null;
      document.addEventListener('touchstart', e => {
        const b = stop(e.target); const p = e.changedTouches[0];
        start = b && p ? {b, x:p.clientX, y:p.clientY} : null;
      }, {capture:true, passive:true});
      document.addEventListener('touchend', e => {
        const s = start; start = null; const p = e.changedTouches[0];
        if (!s || !p || s.b.disabled || stop(e.target) !== s.b) return;
        if (Math.hypot(p.clientX-s.x, p.clientY-s.y) > 10) return;
        e.preventDefault(); s.b.click();
      }, {capture:true, passive:false});
    })();
    """
}
