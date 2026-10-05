import SwiftUI
import UniformTypeIdentifiers

struct UserDataView: View {
    @ObservedObject var runtime: RuntimeController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var workTask: Task<Void, Never>?
    @State private var busy: String?
    @State private var message: String?
    @State private var exported: ProjectManagerSheet.ExportedFiles?
    @State private var exportDirectory: URL?
    @State private var importing = false
    @State private var diskStatus: UserDiskStatus?
    @State private var diskSize = 16
    @State private var confirmingGrowth = false
    @State private var confirmingRestore = false
    @State private var confirmingRescue = false
    @AppStorage("userData.lastBackup") private var lastBackup: Double = 0

    var body: some View {
        NavigationStack {
            List {
                Section("用户盘容量") {
                    if let diskStatus {
                        LabeledContent("容量上限", value: formatted(diskStatus.capacityBytes))
                        LabeledContent("已占 iPad 空间", value: formatted(diskStatus.allocatedBytes))
                        LabeledContent("iPad 剩余空间", value: formatted(diskStatus.hostAvailableBytes))
                        if diskStatus.isHostSpaceLow {
                            Text("iPad 剩余空间不足 2 GB，请先释放空间。用户盘还有空余也可能无法继续写入。")
                                .foregroundStyle(.orange)
                        }
                        Picker("扩容到", selection: $diskSize) {
                            ForEach(capacities, id: \.self) { size in Text("\(size) GB").tag(size) }
                        }.disabled(busy != nil)
                        Button("确认容量…") { confirmingGrowth = true }
                            .disabled(busy != nil || runtime.phase != .ready || diskStatus.isHostSpaceLow)
                    } else {
                        Text("正在读取容量…").foregroundStyle(.secondary)
                    }
                    Text("默认 8 GB，最高 64 GB；只支持增大，不自动扩容。稀疏数据盘按实际写入占用 iPad 空间。删除文件是否释放 iPad 空间仍待真机验证；备份恢复会保留旧数据，不能自动压缩原盘。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("用户数据备份") {
                    Text("建议定期导出，重签前先备份。备份会停止正在进行的任务，完成后恢复 Harness。备份含 API Key、会话及私密配置，请保存到你信任的位置；不含 node_modules、.cache 和 Git 凭据。")
                        .foregroundStyle(.secondary)
                    if lastBackup > 0 { Text("上次生成：\(Date(timeIntervalSince1970: lastBackup).formatted())").font(.caption) }
                    Button("导出完整备份…") { export() }.disabled(busy != nil)
                    Button("恢复备份…") { confirmingRestore = true }.disabled(busy != nil)
                }
                Section("故障救援") {
                    Text("完整备份不可用时，可停止运行环境并导出原始数据盘。原盘保留在应用中，之后需要关闭并重新打开应用。")
                        .foregroundStyle(.secondary)
                    Button("停止运行环境并导出救援盘…") { confirmingRescue = true }.disabled(busy != nil)
                }
                if let busy { HStack { ProgressView(); Text(busy) } }
                if let message { Text(message) }
            }
            .navigationTitle("iPad 应用设置")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if busy == nil { await refreshDisk() }
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                }
            }
            .toolbar { Button("完成") { dismiss() }.disabled(busy != nil) }
            .interactiveDismissDisabled(busy != nil)
            .sheet(item: $exported, onDismiss: cleanExport) { files in DocumentExporter(urls: files.urls) }
            .confirmationDialog("将用户盘扩容到 \(diskSize) GB？iPad 当前剩余 \(diskStatus.map { formatted($0.hostAvailableBytes) } ?? "未知")。不会预占全部容量，但后续写入仍需要真实空间；容量不能缩小。请保持应用在前台。", isPresented: $confirmingGrowth, titleVisibility: .visible) {
                Button("在线扩容到 \(diskSize) GB") { growDisk() }
            }
            .confirmationDialog("恢复会停止正在进行的任务，并替换当前用户配置和项目。原数据会保留在用户盘的救援目录。", isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button("选择备份与 SHA256 文件…") { importing = true }
            }
            .confirmationDialog("停止后需重开 App；不会删除或重置原盘。", isPresented: $confirmingRescue, titleVisibility: .visible) {
                Button("停止并导出") { rescue() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.archive, .data], allowsMultipleSelection: true, onCompletion: restore)
        }
    }

    private var capacities: [Int] {
        let current = Int(((diskStatus?.capacityBytes ?? 8 << 30) + (1 << 30) - 1) >> 30)
        return Array(Set([8, 16, 32, 64, current])).sorted().filter { $0 >= current && $0 <= 64 }
    }
    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
    private func refreshDisk() async {
        do {
            diskStatus = try await runtime.userDiskStatus()
            if !capacities.contains(diskSize) { diskSize = capacities.first ?? 64 }
        } catch { message = error.localizedDescription }
    }
    private func growDisk() {
        busy = "正在在线扩容，请保持应用在前台…"; message = nil
        workTask = Task {
            do {
                diskStatus = try await runtime.growUserDisk(toGiB: diskSize)
                message = "用户盘容量已确认，正在运行的 Harness 和项目保留。"
            } catch {
                message = error.localizedDescription
                await refreshDisk()
            }
            busy = nil
        }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HarnessData-\(UUID().uuidString)", isDirectory: true)
    }
    private func export() {
        busy = "正在停止写入并生成完整备份；刚启动时停止 Harness 可能需要几分钟…"; message = nil
        workTask = Task {
            let work = BackgroundDataWork(title: "用户数据备份") { workTask?.cancel() }
            var completed = false
            defer { work.finish(success: completed && !Task.isCancelled) }
            let target = directory()
            do {
                let urls = try await ProjectTransfer(session: work.session).exportUserData(into: target)
                completed = true
                lastBackup = Date().timeIntervalSince1970
                exportDirectory = target
                exported = .init(urls: urls)
                message = "备份已生成，请在 Files 中保存 tar 和 SHA256 两个文件。"
            } catch { message = error.localizedDescription; try? FileManager.default.removeItem(at: target) }
            busy = nil
        }
    }
    private func copy(_ source: URL, into directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }.value
    }
    private func restore(_ result: Result<[URL], Error>) {
        guard case .success(let files) = result else { return }
        guard let archive = files.first(where: { $0.pathExtension.lowercased() == "tar" }),
              let checksum = files.first(where: { $0.pathExtension.lowercased() == "sha256" }) else {
            message = "请同时选择完整备份的 tar 和 SHA256 文件。"; return
        }
        busy = "正在校验并恢复，原数据会保留…"; message = nil
        workTask = Task {
            let work = BackgroundDataWork(title: "恢复用户数据") { workTask?.cancel() }
            var completed = false
            defer { work.finish(success: completed && !Task.isCancelled) }
            let target = directory()
            defer { try? FileManager.default.removeItem(at: target); busy = nil }
            do {
                let localArchive = try await copy(archive, into: target)
                let localChecksum = try await copy(checksum, into: target)
                let restarted = try await ProjectTransfer(session: work.session).restoreUserData(localArchive, checksum: localChecksum)
                completed = true
                await runtime.recoverPage()
                message = (restarted ? "备份已恢复；" : "数据已恢复，Harness 尚未启动，请重试连接；") + "原数据保留在用户盘的 .restore-original-* 目录。依赖需重新安装，Git 凭据需重新输入。"
            } catch { message = "恢复未完成：\(error.localizedDescription)。原数据与救援目录会保留。" }
        }
    }
    private func rescue() {
        busy = "正在停止运行环境并复制救援盘…"; message = nil
        Task {
            let target = directory()
            do {
                let disk = try await runtime.exportRescueDisk(into: target)
                let checksum = disk.appendingPathExtension("sha256")
                try await Task.detached(priority: .userInitiated) {
                    try Data("\(try ProjectTransfer.sha256(of: disk))  \(disk.lastPathComponent)\n".utf8).write(to: checksum)
                }.value
                exportDirectory = target
                exported = .init(urls: [disk, checksum])
                message = "救援盘已生成，原盘未删除。请关闭并重新打开应用。"
            } catch { message = error.localizedDescription; try? FileManager.default.removeItem(at: target) }
            busy = nil
        }
    }
    private func cleanExport() {
        // The picker owns its exported copies; only our staged temporary copy is removed.
        if let directory = exportDirectory { try? FileManager.default.removeItem(at: directory) }
        exported = nil
        exportDirectory = nil
    }
}
