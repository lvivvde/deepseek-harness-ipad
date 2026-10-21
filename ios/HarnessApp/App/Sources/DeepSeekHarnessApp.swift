import SwiftUI
import WebKit

@main
struct DeepSeekHarnessApp: App {
    @StateObject private var model = AppModel()
    @State private var showingStatus = false

    var body: some Scene {
        WindowGroup("DeepSeek Harness") {
            #if os(macOS)
            // The official sidebar folds away below 1024 points of page width.
            AppView(model: model, showingStatus: $showingStatus).frame(minWidth: 1100, minHeight: 680)
            #else
            AppView(model: model, showingStatus: $showingStatus)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("运行状态…") { showingStatus = true }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}

/// The official Harness page fills the window. What only Swift knows (Linux, preview, session
/// recovery, capabilities) sits in a status sheet behind one small button.
struct AppView: View {
    @ObservedObject var model: AppModel
    @Binding var showingStatus: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { size in
            // Landscape keeps the official page and the preview side by side; portrait gives the preview the screen.
            if let url = model.previewURL, size.size.width <= size.size.height {
                PreviewPane(url: url) { model.closePreview() }
            } else {
                HStack(spacing: 0) {
                    official
                    if let url = model.previewURL {
                        Divider()
                        PreviewPane(url: url) { model.closePreview() }.frame(width: size.size.width * 0.42)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) { statusButton }
        .sheet(isPresented: $showingStatus) { StatusSheet(model: model) }
        .onChange(of: model.sessionPhase) { phase in if phase == "BLOCKED" { showingStatus = true } }
        .onChange(of: scenePhase) { phase in if phase != .active { model.saveSession() } }
    }

    @ViewBuilder private var official: some View {
        if model.webStarted, let web = model.web {
            #if os(iOS)
            OfficialPage(web: web)
            #else
            WebView(view: web.view)
            #endif
        } else {
            VStack(spacing: 14) {
                Text("DeepSeek Harness").font(.title2.weight(.semibold))
                if let failure = model.failure {
                    Text("启动失败：\(failure)").foregroundStyle(.red).font(.callout)
                } else {
                    ProgressView()
                    Text("正在准备工作区…").foregroundStyle(.secondary).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Small and out of the way of the composer; tinted when something needs the user.
    private var statusButton: some View {
        Button { showingStatus = true } label: {
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "cpu")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(attention ? Color.orange : Color.secondary)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("运行状态")
        .padding(.trailing, 14)
        .padding(.bottom, 150)
        .opacity(model.webStarted ? 1 : 0)
    }

    private var attention: Bool {
        model.sessionPhase == "BLOCKED" || model.diagnostic != nil || model.projects.contains { $0.writerUnknown }
    }
}

/// Linux, preview, session recovery and capabilities: the native state the official page cannot show.
struct StatusSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingFresh = false

    var body: some View {
        NavigationStack {
            Form {
                Section("会话") {
                    LabeledContent("状态") {
                        Text(sessionStatus).foregroundStyle(model.sessionPhase == "BLOCKED" || model.sessionPhase == "UNSAVED" ? .orange : .secondary)
                    }
                    if let date = model.sessionSavedAt { LabeledContent("上次保存", value: date.formatted(date: .abbreviated, time: .standard)) }
                    if model.sessionDiagnosis == "CHECKPOINT_FALLBACK" {
                        Text("已恢复到上一个检查点，更新的会话内容无法恢复。").font(.caption)
                    } else if model.sessionDiagnosis == "LEGACY_CHECKPOINT" {
                        Text("已恢复旧格式检查点，无法比对工作区。").font(.caption)
                    } else if let diagnosis = model.sessionDiagnosis { Text(diagnosis).font(.caption) }
                    if let failure = model.sessionFailure { Text(failure).font(.caption) }
                    if model.sessionPhase == "BLOCKED" {
                        Button("开始新会话…") { confirmingFresh = true }
                            .confirmationDialog("开始新会话？", isPresented: $confirmingFresh) {
                                Button("开始新会话", role: .destructive) { model.freshSession() }
                            } message: {
                                Text("旧检查点证据会保留；项目文件、草稿和结果未知的调用保持原样。")
                            }
                    } else if model.webStarted {
                        Button("立即保存") { model.saveSession() }
                    }
                }
                Section {
                    LabeledContent("状态", value: linuxStatus)
                    LabeledContent("绑定工作区", value: model.projects.first { $0.id == model.boundProject }?.name ?? "—")
                    if let diagnostic = model.diagnostic {
                        LabeledContent("上次失败", value: diagnostic)
                        Text("关闭并重新打开 App 之前，Linux 保持关闭。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let failure = model.failure { Text(failure).foregroundStyle(.red).font(.caption) }
                } header: { Text("Linux") } footer: {
                    Text("Linux 绑定到第一个启用 Linux 插件的工作区。").font(.caption)
                }
                Section {
                    Button("查找开发服务器") { model.scanPreviewPorts() }.disabled(model.boundProject == nil)
                    ForEach(model.previewPorts, id: \.self) { port in
                        Button("打开端口 \(port)") { model.openPreview(port: port); dismiss() }
                    }
                    if model.previewURL != nil { Button("关闭预览") { model.closePreview() } }
                } header: { Text("预览") } footer: {
                    Text("只在本 App 内显示；关闭预览不会停止服务器。").font(.caption)
                }
                ForEach(model.projects.filter(\.open)) { project in
                    CapabilitySection(project: project) { model.releaseWriter(project.id) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("运行状态")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .onAppear { model.refresh() }
    }

    private var sessionStatus: String {
        switch model.sessionPhase {
        case "BLOCKED": return "恢复受阻"
        case "SAVING": return "正在保存"
        case "UNSAVED": return "尚未保存"
        case "SAVED": return "已保存"
        default: return "等待会话"
        }
    }

    /// The bound project's plugin phase once Linux can run at all.
    private var linuxStatus: String {
        guard model.linux == "AVAILABLE" else {
            return model.linux == "LINUX_PRIVATE_SYMBOL_MISSING" ? "此系统不支持" : model.linux
        }
        switch model.projects.first(where: { $0.id == model.boundProject })?.phase {
        case "READY": return "就绪"
        case "PREPARING": return "正在启动"
        case "FAILED": return "失败"
        case nil: return "可用 · 未绑定"
        case let phase?: return phase
        }
    }
}

/// The capability declaration of an open project: where each item runs and whether it is usable now.
struct CapabilitySection: View {
    let project: ProjectRow
    let releaseWriter: () -> Void
    @State private var confirming = false

    var body: some View {
        Section("能力 · \(project.name)") {
            if project.recoveryComparison == "CHANGED" {
                Text("保存此检查点期间或之后，工作区有改动。").font(.caption)
            } else if project.recoveryComparison == "UNAVAILABLE" {
                Text("无法与此检查点比对工作区。").font(.caption)
            }
            if project.unknownCalls > 0 { Text("结果未知的调用：\(project.unknownCalls)，不会重放。").font(.caption) }
            if project.drafts > 0 { Text("保留的草稿：\(project.drafts)").font(.caption) }
            if let state = project.pluginState {
                LabeledContent("Linux 插件", value: [state, project.reason].compactMap { $0 }.joined(separator: " · "))
            }
            if project.writerUnknown {
                Text("可能仍有 Linux 命令在写入，原生编辑暂存为草稿。").font(.caption)
                Button("释放写入者…") { confirming = true }
                    .confirmationDialog("释放未知的写入者？", isPresented: $confirming) {
                        Button("释放", role: .destructive, action: releaseWriter)
                    } message: {
                        Text("命令留在工作区里的内容原样保留，暂存的草稿会合并到它之上。")
                    }
            }
            ForEach(project.capabilities, id: \.name) { item in
                HStack {
                    Image(systemName: item.available ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(item.available ? .green : .secondary)
                    Text(item.name)
                    Spacer()
                    Text(item.reason.map { "\(item.path) · \($0)" } ?? item.path).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The forwarded dev server in its own web view, which never sees the official page's bridge.
struct PreviewPane: View {
    let url: URL
    let close: () -> Void
    @StateObject private var holder = PreviewHolder()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.absoluteString).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Button("刷新") { holder.view.reload() }
                Button("关闭", action: close)
            }.padding(8)
            WebView(view: holder.view).onAppear { holder.load(url) }.onChange(of: url) { holder.load($0) }
        }
    }
}

@MainActor
final class PreviewHolder: ObservableObject {
    let view = WKWebView(frame: .zero, configuration: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }())
    private var loaded: URL?
    func load(_ url: URL) {
        guard url != loaded else { return }
        loaded = url
        view.load(URLRequest(url: url))
    }
}

#if os(macOS)
struct WebView: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct WebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The official page with the terminal key row held to the top of the keyboard. SwiftUI rebuilds the
/// container when the preview layout changes; the page and the row move into the new one.
struct OfficialPage: UIViewRepresentable {
    let web: WebHost
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        let page = web.view, keys = web.keys!
        for child in [page, keys] as [UIView] {
            child.removeFromSuperview()
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        let height = keys.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            keys.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            keys.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor), height
        ])
        keys.onVisibility = { height.constant = $0 ? 44 : 0 }
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
