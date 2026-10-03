import SwiftUI

@main
struct HarnessApp: App {
    @StateObject private var runtime = RuntimeController(driver: EmbeddedRuntime())
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false

    var body: some Scene {
        WindowGroup {
            HarnessRoot(runtime: runtime)
                .task { await runtime.ensureRunning() }
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        wasBackgrounded = true
                        flushBeforeSuspension()
                    } else if phase == .active, wasBackgrounded {
                        wasBackgrounded = false
                        Task { await runtime.resume() }
                    }
                }
        }
    }

    private func flushBeforeSuspension() {
        let lease = BackgroundLease()
        Task {
            await runtime.flush()
            lease.finish()
        }
    }
}

@MainActor
private final class BackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "harness-sync") { [weak self] in
            self?.finish()
        }
    }
    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private struct HarnessRoot: View {
    @ObservedObject var runtime: RuntimeController
    @State private var painted = false
    @State private var showingDiagnostics = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if let destination = runtime.destination {
                OfficialWebView(destination: destination, revision: runtime.pageRevision,
                                onLoading: { painted = false }, onPaint: { painted = true },
                                onFailure: { runtime.pageFailed() },
                                onContentTerminated: { Task { await runtime.recoverPage() } })
            }
            if runtime.phase != .ready || !painted {
                VStack(spacing: 20) {
                    Text("DeepSeek Harness").font(.title2.weight(.medium))
                    if case .failed(let message, let requiresRelaunch) = runtime.phase {
                        Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if !requiresRelaunch {
                            Button("重试") { Task { await runtime.retry() } }.buttonStyle(.borderedProminent)
                        }
                        Button("查看诊断") { showingDiagnostics = true }.buttonStyle(.bordered)
                    } else {
                        ProgressView()
                        Text(stage).foregroundStyle(.secondary)
                        Button("查看诊断") { showingDiagnostics = true }.font(.callout)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                List {
                    Section("运行状态") { Text(stage) }
                    Section("事件（不含凭据）") {
                        ForEach(Array(runtime.diagnostics.enumerated()), id: \.offset) { _, event in Text(event) }
                    }
                }
                .navigationTitle("诊断")
                .toolbar { Button("完成") { showingDiagnostics = false } }
            }
        }
    }

    private var stage: String {
        switch runtime.phase {
        case .idle, .preparing: return "正在准备用户数据"
        case .booting: return "正在启动运行环境"
        case .loadingHarness: return "正在启动 Harness"
        case .ready: return painted ? "Harness 已就绪" : "正在打开官方界面"
        case .reconnecting: return "正在重新连接"
        case .failed(let message, _): return message
        }
    }
}
