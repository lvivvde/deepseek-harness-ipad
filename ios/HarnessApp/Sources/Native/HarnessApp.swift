import SwiftUI

@main
struct HarnessApp: App {
    @StateObject private var runtime = RuntimeController(driver: EmbeddedRuntime())
    @StateObject private var transfer = ProjectTransferModel()
    @StateObject private var preview = PreviewController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false

    init() { BackgroundDataWork.register() }

    var body: some Scene {
        WindowGroup {
            HarnessRoot(runtime: runtime, transfer: transfer, preview: preview)
                .projectTransfer(transfer)
                .task { await runtime.ensureRunning() }
                .task { await preview.monitor() }
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
        .commands { ProjectMenuCommands(transfer: transfer, ready: runtime.phase == .ready) }
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
    @ObservedObject var transfer: ProjectTransferModel
    @ObservedObject var preview: PreviewController
    @State private var painted = false
    @State private var showingDiagnostics = false
    @State private var showingData = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var hostSpaceLow = false

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if let destination = runtime.destination {
                HStack(spacing: 0) {
                    OfficialWebView(destination: destination, revision: runtime.pageRevision,
                                    previewRequest: preview.request, onNativePreview: { preview.nativeURL = $0 },
                                    onLoading: { painted = false }, onPaint: { painted = true },
                                    onFailure: { runtime.pageFailed() },
                                    onContentTerminated: { Task { await runtime.recoverPage() } })
                    if isLandscape && geometry.size.width >= 600, let url = preview.nativeURL {
                        Divider()
                        NativePreviewPanel(url: url) { preview.nativeURL = nil }
                            .frame(width: geometry.size.width * 0.45)
                    }
                }
                if (!isLandscape || geometry.size.width < 600), let url = preview.nativeURL {
                    NativePreviewPanel(url: url) { preview.nativeURL = nil }
                }
            }
            if runtime.phase == .reconnecting && painted {
                VStack {
                    Text("正在重新连接…").font(.callout).padding(10).background(.regularMaterial, in: Capsule())
                    Spacer()
                }.padding().allowsHitTesting(false)
            } else if runtime.phase != .ready || !painted {
                VStack(spacing: 20) {
                    Text("DeepSeek Harness").font(.title2.weight(.medium))
                    if case .failed(let message, let requiresRelaunch) = runtime.phase {
                        Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if !requiresRelaunch {
                            Button("重试") { Task { await runtime.retry() } }.buttonStyle(.borderedProminent)
                        }
                        Button("查看诊断") { showingDiagnostics = true }.buttonStyle(.bordered)
                        Button("备份与救援…") { showingData = true }
                    } else {
                        ProgressView()
                        Text(stage).foregroundStyle(.secondary)
                        Button("查看诊断") { showingDiagnostics = true }.font(.callout)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            } else {
                HarnessToolsButton(transfer: transfer, preview: preview, showData: { showingData = true }) { showingDiagnostics = true }
            }
        }
        .alert(item: $preview.prompt) { server in
            Alert(title: Text("检测到开发服务器"), message: Text("端口 \(server.port)"),
                  primaryButton: .default(Text("在侧栏预览")) { preview.open(server) }, secondaryButton: .cancel(Text("稍后")))
        }
        .overlay(alignment: .top) {
            if hostSpaceLow {
                Button { showingData = true } label: {
                    Label("iPad 剩余空间不足 2 GB，请先释放空间", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }.padding()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if let status = try? await runtime.userDiskStatus() { hostSpaceLow = status.isHostSpaceLow }
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
        .sheet(isPresented: $showingData) { UserDataView(runtime: runtime) }
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

    }

    private var isLandscape: Bool {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation.isLandscape == true
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
