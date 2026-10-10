import SwiftUI
import WebKit

@main
struct CandidateApp: App {
    @StateObject private var model = CandidateModel()

    var body: some Scene {
        WindowGroup("Harness Candidate") {
            #if os(macOS)
            CandidateView(model: model).frame(minWidth: 960, minHeight: 640)
            #else
            CandidateView(model: model)
            #endif
        }
    }
}

struct CandidateView: View {
    @ObservedObject var model: CandidateModel
    @State private var name = ""
    @State private var pluginEnabled = true
    @State private var key = ""
    @State private var selected: String?
    @State private var confirmingFresh = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Projects") {
                    ForEach(model.projects) { project in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                Text(project.pluginEnabled ? "Linux · \(project.phase)" : "Native only")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if project.open { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                            else { Button("Open") { model.open(project.id) } }
                        }.tag(project.id)
                    }
                }
                Section("New project") {
                    TextField("Name", text: $name)
                    Toggle("Linux plugin", isOn: $pluginEnabled)
                    Button("Create") { model.create(name: name, pluginEnabled: pluginEnabled); name = "" }
                        .disabled(name.isEmpty)
                }
                Section("Model key") {
                    SecureField("DeepSeek API key", text: $key)
                        .onChange(of: key) { model.setKey($0) }
                    Text("Held in memory only.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Session") {
                    Text(sessionStatus).foregroundStyle(model.sessionPhase == "BLOCKED" || model.sessionPhase == "UNSAVED" ? .orange : .secondary)
                    if let date = model.sessionSavedAt { Text("Last saved: " + date.formatted()).font(.caption) }
                    if model.sessionDiagnosis == "CHECKPOINT_FALLBACK" {
                        Text("Restored the previous checkpoint. Newer session content could not be restored.").font(.caption)
                    } else if model.sessionDiagnosis == "LEGACY_CHECKPOINT" {
                        Text("Restored a legacy checkpoint. Workspace comparison is unavailable.").font(.caption)
                    } else if let diagnosis = model.sessionDiagnosis { Text(diagnosis).font(.caption) }
                    if let failure = model.sessionFailure { Text(failure).font(.caption) }
                    if model.sessionPhase == "BLOCKED" {
                        Button("Start a new session…") { confirmingFresh = true }
                            .confirmationDialog("Start a new session?", isPresented: $confirmingFresh) {
                                Button("Start new session", role: .destructive) { model.freshSession() }
                            } message: {
                                Text("Old checkpoint evidence is preserved. Project files, drafts and unknown calls remain as they are.")
                            }
                    } else if model.webStarted {
                        Button("Save / retry") { model.saveSession() }
                    }
                }
                Section("Linux") {
                    LabeledContent("Availability", value: model.linux)
                    LabeledContent("Bound project", value: model.projects.first { $0.id == model.boundProject }?.name ?? "—")
                    if let diagnostic = model.diagnostic {
                        LabeledContent("Last failure", value: diagnostic)
                        Text("Linux stays off until the App is closed and reopened.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let event = model.lastEvent { LabeledContent("Worker", value: event) }
                    if let failure = model.failure { Text(failure).foregroundStyle(.red) }
                }
                if let project = model.projects.first(where: { $0.id == selected }), project.open {
                    CapabilitySection(project: project) { model.releaseWriter(project.id) }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if model.webStarted, let web = model.web {
                WebView(view: web.view)
            } else {
                Text("Open a project to start.").foregroundStyle(.secondary)
            }
        }
        .onChange(of: scenePhase) { phase in if phase != .active { model.saveSession() } }
    }

    private var sessionStatus: String {
        switch model.sessionPhase {
        case "BLOCKED": return "Recovery blocked"
        case "SAVING": return "Saving · not yet saved"
        case "UNSAVED": return "Not yet saved"
        case "SAVED": return "Saved"
        default: return "Waiting for session"
        }
    }
}

/// The capability declaration of an open project: where each item runs and whether it is usable now.
struct CapabilitySection: View {
    let project: ProjectRow
    let releaseWriter: () -> Void
    @State private var confirming = false

    var body: some View {
        Section("Capabilities · \(project.name)") {
            if project.recoveryComparison == "CHANGED" {
                Text("Workspace changed during or after this checkpoint was saved.").font(.caption)
            } else if project.recoveryComparison == "UNAVAILABLE" {
                Text("Workspace comparison with this checkpoint is unavailable.").font(.caption)
            }
            if project.unknownCalls > 0 { Text("Calls with unknown results: \(project.unknownCalls). They will not be replayed.").font(.caption) }
            if project.drafts > 0 { Text("Retained drafts: \(project.drafts)").font(.caption) }
            if let state = project.pluginState {
                LabeledContent("Plugin", value: [state, project.reason].compactMap { $0 }.joined(separator: " · "))
            }
            if project.writerUnknown {
                Text("A Linux command may still be writing. Native edits are kept as drafts.").font(.caption)
                Button("Release writer…") { confirming = true }
                    .confirmationDialog("Release the unknown writer?", isPresented: $confirming) {
                        Button("Release", role: .destructive, action: releaseWriter)
                    } message: {
                        Text("Whatever the command left in the workspace is kept as it is, and held drafts are rebased onto it.")
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
#endif
