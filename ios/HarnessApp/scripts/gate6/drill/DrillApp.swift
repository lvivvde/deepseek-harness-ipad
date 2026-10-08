// Gate 6 rollback drill (#39). Runs under a dedicated test bundle ID that the re-signed old app shares, so
// both see one container. The old app's disk is only stat'ed and hashed read-only. Receipts hold counts,
// digests and fixed codes; never names from a real backup.
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserDataMigration

@main
struct Gate6DrillApp: App {
    @StateObject private var model = DrillModel()
    @State private var picking = false

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("关口 6 · 迁移演练").font(.title)
                Text(model.status).font(.headline)
                Button("选择真实备份（HarnessBackup.tar 与 HarnessBackup.tar.sha256）") { picking = true }
                    .disabled(model.busy)
                ScrollView {
                    Text(model.log).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("只读所选备份；解出的内容核对后即删除，收据只含计数、摘要和结论。").font(.footnote)
            }
            .padding()
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.verifyReal(urls)
                case .failure: model.status = "未选择备份"
                }
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                Drill.progress("launched", ["drillArgument": arguments.contains("--drill-migrate")])
                if let index = arguments.firstIndex(of: "--drill-migrate"), arguments.indices.contains(index + 1) {
                    model.drill(run: arguments[index + 1])
                }
            }
        }
    }
}

struct DrillPaths {
    let documents: URL, support: URL
    init() {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Gate6Drill")
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    var oldDisk: URL { support.appendingPathComponent("HarnessRuntime/user.raw") }
    var drill: URL { support.appendingPathComponent("Gate6Drill") }
    var target: URL { drill.appendingPathComponent("UserData") }
    var state: URL { drill.appendingPathComponent("state.json") }
    var edit: URL { target.appendingPathComponent("projects/demo/after-migration.txt") }
}

@MainActor
final class DrillModel: ObservableObject {
    @Published var status = "等待"
    @Published var log = ""
    @Published var busy = false

    func drill(run: String) {
        guard !busy, run.range(of: "^[A-Za-z0-9-]{1,32}$", options: .regularExpression) != nil else { return }
        busy = true; status = "演练 \(run) 进行中"
        Task.detached(priority: .userInitiated) {
            let receipt = Drill.migrateAndCheck()
            let paths = DrillPaths()
            Drill.write(receipt, to: paths.documents.appendingPathComponent("drill-\(run)-safe.json"))
            await MainActor.run {
                self.status = "演练 \(run)：" + ((receipt["passed"] as? Bool) == true ? "通过" : "未通过")
                self.log = Drill.text(receipt); self.busy = false
            }
        }
    }

    func verifyReal(_ urls: [URL]) {
        guard !busy else { return }
        busy = true; status = "核对真实备份中"
        Task.detached(priority: .userInitiated) {
            let receipt = Drill.verifyReal(urls)
            Drill.write(receipt, to: DrillPaths().documents.appendingPathComponent("real-backup-safe.json"))
            await MainActor.run {
                self.status = "真实备份：" + ((receipt["passed"] as? Bool) == true ? "通过" : "未通过")
                self.log = Drill.text(receipt); self.busy = false
            }
        }
    }
}

enum Drill {
    static func write(_ receipt: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Where a run has got to, so a slow or stuck phase shows up from the Mac without anyone looking at the screen.
    static func progress(_ phase: String, _ extra: [String: Any] = [:]) {
        var entry = extra
        entry["phase"] = phase
        entry["at"] = Date().timeIntervalSince1970
        write(entry, to: DrillPaths().documents.appendingPathComponent("progress.json"))
    }

    static func text(_ receipt: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Read-only identity of the old app's disk: it must be the same before and after a migration. ctime
    /// moves on any write and cannot be set back from user space.
    static func diskSnapshot(_ url: URL) -> [String: Any] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return ["exists": false] }
        let data = sparseSha256(url)
        return ["exists": true, "size": Int64(info.st_size), "inode": UInt64(info.st_ino),
                "mtimeNs": Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                "ctimeNs": Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
                "sha256": data?.digest ?? "unreadable", "dataBytes": data?.bytes ?? -1]
    }

    /// The disk is a sparse file. Reading its holes costs as much as reading data, so hash only the data
    /// extents, each with its offset and length; the holes are implied by the size.
    static func sparseSha256(_ url: URL) -> (digest: String, bytes: Int64)? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let end = lseek(fd, 0, SEEK_END)
        var hasher = SHA256(), offset: off_t = 0, total: Int64 = 0, reported: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        while offset < end {
            let start = lseek(fd, offset, SEEK_DATA)
            if start < 0 { break }  // ENXIO: only a hole remains
            let stop = lseek(fd, start, SEEK_HOLE)
            guard stop > start else { return nil }
            withUnsafeBytes(of: (Int64(start), Int64(stop - start))) { hasher.update(bufferPointer: $0) }
            var at = start
            while at < stop {
                let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, min($0.count, Int(stop - at)), at) }
                guard count > 0 else { return nil }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
                at += off_t(count); total += Int64(count)
                if total - reported >= 256 << 20 { reported = total; progress("hashing", ["dataBytes": total, "offset": Int64(at)]) }
            }
            offset = stop
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    static func redacted(_ report: MigrationReport) -> [String: Any] {
        ["archiveSha256": report.archiveSha256, "manifestSha256": report.manifestSha256, "files": report.files,
         "directories": report.directories, "symlinks": report.symlinks, "hardlinks": report.hardlinks, "bytes": report.bytes,
         "specialSkipped": report.specialSkipped.count, "credentialsExcluded": report.credentialsExcluded.count,
         "cacheEntriesExcluded": report.cacheEntriesExcluded, "sessions": report.sessions,
         "sessionsDecompressed": report.sessionsDecompressed, "sessionsMoved": report.sessionsMoved,
         "sessionsOutsideProjects": report.sessionsOutsideProjects]
    }

    static func migrate(archive: URL, checksum: URL, target: URL) -> (outcome: String, report: MigrationReport?, codec: Bool) {
        var options = MigrationOptions()
        options.codec = try? DynamicZstd()
        do {
            switch try UserDataMigrator(archive: archive.path, checksum: checksum.path, target: target.path, options: options).run() {
            case .migrated(let report): return ("migrated", report, options.codec != nil)
            case .alreadyMigrated(let report): return ("already", report, options.codec != nil)
            }
        } catch let error as MigrationError {
            return ("ERROR " + error.code, nil, options.codec != nil)
        } catch {
            return ("ERROR UNEXPECTED", nil, options.codec != nil)
        }
    }

    /// First run: migrate, compare with the synthetic expected tree, then make a later change. A run after
    /// the old app came back must find the migration already done and that change intact.
    static func migrateAndCheck() -> [String: Any] {
        let paths = DrillPaths()
        let started = Date()
        let state = (try? Data(contentsOf: paths.state)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        progress("snapshot before")
        let before = diskSnapshot(paths.oldDisk)
        progress("migrating")
        try? FileManager.default.createDirectory(at: paths.drill, withIntermediateDirectories: true)
        let archive = paths.documents.appendingPathComponent("HarnessBackup.tar")
        let result = migrate(archive: archive, checksum: archive.appendingPathExtension("sha256"), target: paths.target)
        progress("snapshot after")
        let after = diskSnapshot(paths.oldDisk)
        progress("checking")
        var checks: [String: Bool] = [
            "oldDiskPresent": before["exists"] as? Bool == true,
            "oldDiskUnchangedByMigration": NSDictionary(dictionary: before).isEqual(to: after),
            "zstdDecoderLoaded": result.codec,
            "noStageLeft": ((try? FileManager.default.contentsOfDirectory(atPath: paths.drill.path)) ?? [])
                .allSatisfy { !$0.hasPrefix(UserDataMigrator.stagePrefix) }
        ]
        let marker = sha256(paths.target.appendingPathComponent(UserDataMigrator.marker))
        var receipt: [String: Any] = ["outcome": result.outcome, "firstRun": state == nil, "oldDisk": before]
        if let report = result.report { receipt["report"] = redacted(report) }
        if state == nil {
            checks["migrated"] = result.outcome == "migrated"
            let problems = treeProblems(target: paths.target, expected: paths.documents.appendingPathComponent("expected.json"))
            receipt["treeProblems"] = problems.count
            receipt["treeProblemPaths"] = Array(problems.prefix(20))
            checks["treeMatchesExpected"] = problems.isEmpty
            let token = UUID().uuidString
            try? Data("changed after migration \(token)\n".utf8).write(to: paths.edit)
            let edit = sha256(paths.edit)
            checks["laterChangeWritten"] = edit != nil
            write(["markerSha256": marker ?? "", "editSha256": edit ?? "", "oldDiskSha256": before["sha256"] ?? ""], to: paths.state)
        } else {
            checks["alreadyMigrated"] = result.outcome == "already"
            checks["markerUnchanged"] = marker != nil && marker == state?["markerSha256"] as? String
            checks["laterChangeKept"] = sha256(paths.edit) != nil && sha256(paths.edit) == state?["editSha256"] as? String
            receipt["oldDiskChangedSinceFirstRun"] = before["sha256"] as? String != state?["oldDiskSha256"] as? String
        }
        receipt["checks"] = checks
        receipt["passed"] = checks.values.allSatisfy { $0 }
        receipt["elapsedMilliseconds"] = Int(Date().timeIntervalSince(started) * 1000)
        return receipt
    }

    /// The same comparison as scripts/gate6/synthetic-matrix.py `check_tree`.
    static func treeProblems(target: URL, expected: URL) -> [String] {
        guard let data = try? Data(contentsOf: expected),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wanted = spec["expected"] as? [String: [String: Any]],
              let hardlinks = spec["hardlinks"] as? [[String]] else { return ["expected.json unreadable"] }
        var seen: [String: [String: Any]] = [:]
        let root = target.path
        guard let walker = FileManager.default.enumerator(atPath: root) else { return ["target unreadable"] }
        while let relative = walker.nextObject() as? String {
            if relative == UserDataMigrator.marker || relative == "home/sessions" || relative.hasPrefix("home/sessions/") { continue }
            var info = stat()
            guard lstat(root + "/" + relative, &info) == 0 else { seen[relative] = ["type": "missing"]; continue }
            let mode = Int(info.st_mode & 0o7777)
            switch info.st_mode & S_IFMT {
            case S_IFDIR: seen[relative] = ["type": "directory", "mode": mode]
            case S_IFLNK:
                seen[relative] = ["type": "symlink", "link": (try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/" + relative)) ?? ""]
            case S_IFREG: seen[relative] = ["type": "file", "mode": mode, "sha256": sha256(target.appendingPathComponent(relative)) ?? ""]
            default: seen[relative] = ["type": "other", "mode": mode]
            }
        }
        var problems = Set(seen.keys).union(wanted.keys).filter { path in
            guard let a = seen[path], let b = wanted[path] else { return true }
            return !NSDictionary(dictionary: a).isEqual(to: b)
        }
        for group in hardlinks {
            let inodes = Set(group.map { path -> UInt64 in var info = stat(); _ = lstat(root + "/" + path, &info); return UInt64(info.st_ino) })
            if inodes.count != 1 { problems.insert("hardlink " + (group.first ?? "")) }
        }
        let log = target.appendingPathComponent("home/sessions/--dsh-workspace-demo--/s-1/session.v4.jsonl")
        let bytes = (try? Data(contentsOf: log)) ?? Data()
        let split = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        let header = (try? JSONSerialization.jsonObject(with: bytes[..<split])) as? [String: Any]
        let rest = split < bytes.endIndex ? bytes[(split + 1)...] : Data()
        if header?["cwd"] as? String != "/dsh/workspace/demo" || Data(rest) != Data("{\"type\":\"user\",\"text\":\"保持 /root/projects/demo\"}\n".utf8) {
            problems.insert("session s-1")
        }
        if FileManager.default.fileExists(atPath: root + "/home/sessions/--root-projects-demo--") ||
            !FileManager.default.fileExists(atPath: root + "/home/sessions/_no-cwd/s-2/session.v4.jsonl") {
            problems.insert("session layout")
        }
        return problems.sorted()
    }

    /// What a rejected archive looks like, without any names: entry counts by type and its top-level items
    /// sorted into the layout file, `projects`, `home` and anything else.
    static func shape(_ archive: URL) -> [String: Any] {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return ["readable": false] }
        defer { try? handle.close() }
        var types: [String: Int] = [:], top: [String: Set<String>] = [:], pending: String?
        while let header = try? handle.read(upToCount: 512), header.count == 512, header.contains(where: { $0 != 0 }) {
            let field = { (from: Int, count: Int) in String(decoding: header[from..<(from + count)].prefix { $0 != 0 }, as: UTF8.self) }
            let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let flag = header[156] == 0 ? "0" : String(UnicodeScalar(header[156]))
            var body = Data()
            if flag == "x" { body = (try? handle.read(upToCount: size)) ?? Data() } else { try? handle.seek(toOffset: handle.offsetInFile + UInt64(size)) }
            try? handle.seek(toOffset: (handle.offsetInFile + 511) / 512 * 512)
            types[flag, default: 0] += 1
            if flag == "x" {
                pending = String(decoding: body, as: UTF8.self).split(separator: "\n")
                    .first { $0.contains(" path=") }.map { String($0.split(separator: "=", maxSplits: 1)[1]) }
                continue
            }
            if flag == "g" { continue }
            let prefix = field(345, 155)
            let path = pending ?? (prefix.isEmpty ? field(0, 100) : prefix + "/" + field(0, 100))
            pending = nil
            let first = path.split(separator: "/").first.map(String.init) ?? ""
            let kind = first == ".harness-layout-version" ? "layoutVersion" : first == "projects" || first == "home" ? first : "other"
            top[kind, default: []].insert(first)
        }
        return ["entryTypes": types, "topLevel": top.mapValues { $0.count }]
    }

    /// A backup the user exported from the formal app through Files: migrate it into a scratch target, run
    /// again to show a repeat is a no-op, then delete everything that was extracted.
    static func verifyReal(_ urls: [URL]) -> [String: Any] {
        let started = Date()
        guard urls.count == 2,
              let archive = urls.first(where: { $0.pathExtension.lowercased() == "tar" }),
              let checksum = urls.first(where: { $0.pathExtension.lowercased() == "sha256" }) else {
            return ["passed": false, "outcome": "ERROR SELECTION_NEEDS_TAR_AND_SHA256", "selected": urls.count]
        }
        let scoped = [archive, checksum].map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, started) in zip([archive, checksum], scoped) where started { url.stopAccessingSecurityScopedResource() } }
        let scratch = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gate6Real-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appendingPathComponent("UserData")
        let first = migrate(archive: archive, checksum: checksum, target: target)
        let second = first.report == nil ? nil : migrate(archive: archive, checksum: checksum, target: target)
        var receipt: [String: Any] = ["outcome": first.outcome, "repeatOutcome": second?.outcome ?? "skipped",
                                      "archiveBytes": (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1]
        if let report = first.report { receipt["report"] = redacted(report) } else { receipt["shape"] = shape(archive) }
        try? FileManager.default.removeItem(at: scratch)
        let checks: [String: Bool] = [
            "migrated": first.outcome == "migrated",
            "repeatIsNoOp": second?.outcome == "already",
            "repeatReportEqual": second?.report == first.report,
            "zstdDecoderLoaded": first.codec,
            "extractedTreeRemoved": !FileManager.default.fileExists(atPath: scratch.path)
        ]
        receipt["checks"] = checks
        receipt["passed"] = checks.values.allSatisfy { $0 }
        receipt["elapsedMilliseconds"] = Int(Date().timeIntervalSince(started) * 1000)
        return receipt
    }
}
