import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native entry for single-project export/import through the Files app.
@MainActor
final class ProjectTransferModel: ObservableObject {
    @Published var exporting = false
    @Published var importing = false
    @Published var notice: Notice?

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    func importSelected(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let archive = urls.first { $0.pathExtension.lowercased() != "sha256" }
        let checksum = urls.first { $0.pathExtension.lowercased() == "sha256" }
        guard let archive else {
            notice = Notice(title: "导入失败", message: "请选择导出的 .tar 文件（可同时选择 .sha256 校验文件）")
            return
        }
        Task {
            do {
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Import-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                let localArchive = try Self.copy(archive, into: staging)
                let localChecksum = try checksum.map { try Self.copy($0, into: staging) }
                let name = try await ProjectTransfer().importArchive(localArchive, checksum: localChecksum)
                notice = Notice(title: "已导入", message: "项目位于 /root/projects/\(name)。请在左侧“工作区 → 添加工作区”登记该目录；依赖需重新 npm install。")
            } catch {
                notice = Notice(title: "导入失败", message: error.localizedDescription)
            }
        }
    }

    private static func copy(_ source: URL, into directory: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

struct ProjectMenuCommands: Commands {
    @ObservedObject var transfer: ProjectTransferModel
    let ready: Bool

    var body: some Commands {
        CommandMenu("项目") {
            Button("导出项目…") { transfer.exporting = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!ready)
            Button("导入项目…") { transfer.importing = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!ready)
        }
    }
}

struct ProjectExportSheet: View {
    @ObservedObject var transfer: ProjectTransferModel
    @State private var projects: [String]?
    @State private var busy: String?
    @State private var exported: ExportedFiles?
    @State private var failure: String?

    struct ExportedFiles: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                if let projects {
                    if projects.isEmpty { Text("/root/projects 下还没有项目").foregroundStyle(.secondary) }
                    ForEach(projects, id: \.self) { name in
                        Button { export(name) } label: {
                            HStack {
                                Label(name, systemImage: "folder")
                                Spacer()
                                if busy == name { ProgressView() }
                            }
                        }
                        .disabled(busy != nil)
                    }
                } else {
                    ProgressView()
                }
                Section {
                    Text("导出为 tar 和 SHA256 校验文件，不含 node_modules 与 .cache；Git 凭据不在项目内，不会被导出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导出项目")
            .toolbar { Button("完成") { transfer.exporting = false } }
            .task { await load() }
            .sheet(item: $exported, onDismiss: { transfer.exporting = false }) { files in
                DocumentExporter(urls: files.urls)
            }
        }
    }

    private func load() async {
        do { projects = try await ProjectTransfer().projects() }
        catch { failure = error.localizedDescription; projects = [] }
    }

    private func export(_ name: String) {
        busy = name
        failure = nil
        Task {
            defer { busy = nil }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                exported = ExportedFiles(urls: try await ProjectTransfer().export(name, into: directory))
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

extension View {
    func projectTransfer(_ transfer: ProjectTransferModel) -> some View {
        self
            .sheet(isPresented: Binding(get: { transfer.exporting }, set: { transfer.exporting = $0 })) {
                ProjectExportSheet(transfer: transfer)
            }
            .fileImporter(isPresented: Binding(get: { transfer.importing }, set: { transfer.importing = $0 }),
                          allowedContentTypes: [.archive, .data], allowsMultipleSelection: true) { result in
                transfer.importSelected(result)
            }
            .alert(item: Binding(get: { transfer.notice }, set: { transfer.notice = $0 })) { notice in
                Alert(title: Text(notice.title), message: Text(notice.message))
            }
    }
}
