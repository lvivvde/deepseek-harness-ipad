import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native entry for project management, trash and export/import through the Files app.
@MainActor
final class ProjectTransferModel: ObservableObject {
    @Published var manager: ManagerPage?
    @Published var importing = false
    @Published var notice: Notice?

    enum ManagerPage: String, Identifiable {
        case projects, trash
        var id: String { rawValue }
    }

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
            Button("项目管理…") { transfer.manager = .projects }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!ready)
            Button("导入项目…") { transfer.importing = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!ready)
            Button("回收站…") { transfer.manager = .trash }
                .disabled(!ready)
        }
    }
}

struct ProjectManagerSheet: View {
    @ObservedObject var transfer: ProjectTransferModel
    let start: ProjectTransferModel.ManagerPage
    @State private var path: [ProjectTransferModel.ManagerPage] = []
    @State private var projects: [String]?
    @State private var busy: String?
    @State private var exported: ExportedFiles?
    @State private var failure: String?
    @State private var confirmingTrash: String?

    struct ExportedFiles: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                Section {
                    if let projects {
                        if projects.isEmpty { Text("/root/projects 下还没有项目").foregroundStyle(.secondary) }
                        ForEach(projects, id: \.self) { name in
                            // A menu anchors its popover to the tapped row on iPad.
                            Menu {
                                Button { export(name) } label: { Label("导出…", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { confirmingTrash = name } label: {
                                    Label("移到回收站", systemImage: "trash")
                                }
                            } label: {
                                HStack {
                                    Label(name, systemImage: "folder").foregroundStyle(Color.primary)
                                    Spacer()
                                    if busy == name { ProgressView() }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(busy != nil)
                            .swipeActions {
                                Button("删除", role: .destructive) { confirmingTrash = name }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                } header: {
                    Text("/root/projects")
                } footer: {
                    Text("点项目可导出或删除。导出为 tar 和 SHA256 校验文件，不含 node_modules 与 .cache；Git 凭据不在项目内，不会被导出。")
                }
                Section {
                    NavigationLink(value: ProjectTransferModel.ManagerPage.trash) {
                        Label("回收站", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("项目管理")
            .toolbar { Button("完成") { transfer.manager = nil } }
            .navigationDestination(for: ProjectTransferModel.ManagerPage.self) { _ in
                TrashView(onRestore: { Task { await load() } })
            }
            .refreshable { await load() }
            .task { await load() }
            .onAppear { if start == .trash, path.isEmpty { path = [.trash] } }
            .onChange(of: path) { if $0.isEmpty { Task { await load() } } }
            .alert("移到回收站？", isPresented: Binding(get: { confirmingTrash != nil }, set: { if !$0 { confirmingTrash = nil } }),
                   presenting: confirmingTrash) { name in
                Button("移到回收站", role: .destructive) { moveToTrash(name) }
                Button("取消", role: .cancel) {}
            } message: { name in
                Text("“\(name)”可在回收站恢复。如果它已登记为工作区，请同时在左侧工作区列表中移除。")
            }
            .sheet(item: $exported) { files in
                DocumentExporter(urls: files.urls)
            }
        }
    }

    private func load() async {
        do { projects = try await ProjectTransfer().projects(); failure = nil }
        catch { failure = error.localizedDescription; projects = projects ?? [] }
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

    private func moveToTrash(_ name: String) {
        busy = name
        Task {
            defer { busy = nil }
            do { try await ProjectTransfer().trash(name) } catch { failure = error.localizedDescription }
            await load()
        }
    }
}

private struct TrashView: View {
    let onRestore: () -> Void
    @State private var items: [TrashItem]?
    @State private var failure: String?
    @State private var restored: String?
    @State private var purging: TrashItem?
    @State private var confirmingEmpty = false

    var body: some View {
        List {
            if let failure { Text(failure).foregroundStyle(.red) }
            if let restored { Text("已恢复为 /root/projects/\(restored)").foregroundStyle(.secondary) }
            if let items {
                if items.isEmpty { Text("回收站是空的").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    Menu {
                        Button { restore(item) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { purging = item } label: { Label("彻底删除", systemImage: "trash") }
                    } label: {
                        row(item).contentShape(Rectangle())
                    }
                        .swipeActions(edge: .leading) {
                            Button("恢复") { restore(item) }.tint(.blue)
                        }
                        .swipeActions {
                            Button("彻底删除", role: .destructive) { purging = item }
                        }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("回收站")
        .toolbar {
            Button("清空", role: .destructive) { confirmingEmpty = true }
                .disabled(items?.isEmpty ?? true)
        }
        .refreshable { await load() }
        .task { await load() }
        .alert("彻底删除？", isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }),
               presenting: purging) { item in
            Button("彻底删除", role: .destructive) { purge(item) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("“\(item.name)”将从磁盘上永久删除，无法恢复。")
        }
        .alert("清空回收站？", isPresented: $confirmingEmpty) {
            Button("全部彻底删除", role: .destructive) { purge(nil) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("回收站中的 \(items?.count ?? 0) 个项目将从磁盘上永久删除，无法恢复。")
        }
    }

    private func row(_ item: TrashItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(item.name, systemImage: "folder").foregroundStyle(.primary)
            HStack(spacing: 12) {
                Text("删除于 \(item.deletedDate.formatted(date: .abbreviated, time: .shortened))")
                Text(item.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "正在计算大小…")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        do { items = try await ProjectTransfer().trashItems(); failure = nil }
        catch { failure = error.localizedDescription; items = items ?? [] }
    }

    private func restore(_ item: TrashItem) {
        Task {
            do {
                restored = try await ProjectTransfer().restore(item)
                onRestore()
            } catch { failure = error.localizedDescription }
            await load()
        }
    }

    private func purge(_ item: TrashItem?) {
        Task {
            do { try await ProjectTransfer().purge(item) } catch { failure = error.localizedDescription }
            await load()
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
            .sheet(item: Binding(get: { transfer.manager }, set: { transfer.manager = $0 })) { page in
                ProjectManagerSheet(transfer: transfer, start: page)
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

/// Touch entry for app-level tools; a small edge tab the user can drag along either side.
struct HarnessToolsButton: View {
    @ObservedObject var transfer: ProjectTransferModel
    let showDiagnostics: () -> Void
    @AppStorage("toolsButton.y") private var storedY = 0.5
    @AppStorage("toolsButton.leading") private var leading = false
    @State private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let size: CGFloat = 40
            let minY = size / 2 + 8, maxY = geometry.size.height - size / 2 - 8
            let x = leading ? size / 2 + 4 : geometry.size.width - size / 2 - 4
            let y = min(max(storedY * geometry.size.height, minY), maxY)
            Menu {
                Button { transfer.manager = .projects } label: { Label("项目管理…", systemImage: "folder") }
                Button { transfer.importing = true } label: { Label("导入项目…", systemImage: "square.and.arrow.down") }
                Button { transfer.manager = .trash } label: { Label("回收站…", systemImage: "trash") }
                Divider()
                Button { showDiagnostics() } label: { Label("诊断", systemImage: "stethoscope") }
            } label: {
                Image(systemName: "shippingbox")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: size, height: size)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .opacity(drag == .zero ? 0.75 : 1)
            }
            .accessibilityLabel("项目工具")
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        let endX = x + value.translation.width
                        leading = endX < geometry.size.width / 2
                        storedY = min(max(y + value.translation.height, minY), maxY) / max(geometry.size.height, 1)
                        drag = .zero
                    }
            )
            .position(x: x + drag.width, y: y + drag.height)
            .animation(.spring(duration: 0.25), value: leading)
        }
    }
}
