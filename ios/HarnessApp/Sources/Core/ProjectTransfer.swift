import CryptoKit
import Foundation

/// Client for the guest's single-project export/import service (`/opt/harness/transfer.cjs`).
struct ProjectTransfer: Sendable {
    /// One token per app process; QEMU passes it to the guest on the kernel command line.
    static let sessionToken: String = {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }()

    /// RFC 3986 unreserved set; everything else, including CJK and spaces, is percent-encoded.
    private static let unreservedASCII = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    var token = ProjectTransfer.sessionToken
    var base = URL(string: "http://127.0.0.1:\(RuntimePorts.transfer)")!
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    func projects() async throws -> [String] {
        let (data, response) = try await session.data(for: request("projects"))
        try check(response, data)
        struct Listing: Decodable { let projects: [String] }
        return try JSONDecoder().decode(Listing.self, from: data).projects
    }

    /// Writes `<name>-<timestamp>.tar` and a `sha256sum`-compatible checksum file into `directory`.
    func export(_ name: String, into directory: URL, now: Date = Date()) async throws -> [URL] {
        let (downloaded, response) = try await session.download(for: request("projects/\(try encode(name))/archive"))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try check(response, nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let archive = directory.appendingPathComponent("\(name)-\(formatter.string(from: now)).tar")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: downloaded, to: archive)
        let checksum = archive.appendingPathExtension("sha256")
        try Data("\(try Self.sha256(of: archive))  \(archive.lastPathComponent)\n".utf8).write(to: checksum)
        return [archive, checksum]
    }

    /// Uploads an exported archive; a selected checksum file must match before anything is sent.
    func importArchive(_ archive: URL, checksum: URL?) async throws -> String {
        if let checksum { try Self.verify(archive: archive, checksumFile: checksum) }
        var upload = request("projects/import")
        upload.httpMethod = "POST"
        upload.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: upload, fromFile: archive)
        try check(response, data)
        struct Imported: Decodable { let name: String }
        return try JSONDecoder().decode(Imported.self, from: data).name
    }

    /// Moves a project into the trash on the same disk; nothing is deleted yet.
    func trash(_ name: String) async throws {
        var trash = request("projects/\(try encode(name))")
        trash.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: trash)
        try check(response, data)
    }

    func trashItems() async throws -> [TrashItem] {
        let (data, response) = try await session.data(for: request("trash"))
        try check(response, data)
        struct Listing: Decodable { let items: [TrashItem] }
        return try JSONDecoder().decode(Listing.self, from: data).items
    }

    /// Restores under the original name, or `name-2`, `name-3`, … when that name is taken.
    func restore(_ item: TrashItem) async throws -> String {
        var restore = request("trash/\(item.id)/restore")
        restore.httpMethod = "POST"
        let (data, response) = try await session.data(for: restore)
        try check(response, data)
        struct Restored: Decodable { let name: String }
        return try JSONDecoder().decode(Restored.self, from: data).name
    }

    /// Permanently deletes one trashed project, or the whole trash when `item` is nil.
    func purge(_ item: TrashItem?) async throws {
        var purge = request(item.map { "trash/\($0.id)" } ?? "trash")
        purge.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: purge)
        try check(response, data)
    }

    /// A coordinated snapshot of the whole user filesystem, including private Harness config.
    func exportUserData(into directory: URL) async throws -> [URL] {
        let (downloaded, response) = try await session.download(for: request("userdata/archive"))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try check(response, nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("HarnessBackup.tar")
        try FileManager.default.moveItem(at: downloaded, to: archive)
        let checksum = archive.appendingPathExtension("sha256")
        try Data("\(try Self.sha256(of: archive))  \(archive.lastPathComponent)\n".utf8).write(to: checksum)
        return [archive, checksum]
    }

    /// Checks the selected checksum before any restore upload reaches the guest.
    @discardableResult
    func restoreUserData(_ archive: URL, checksum: URL) async throws -> Bool {
        try Self.verify(archive: archive, checksumFile: checksum)
        var upload = request("userdata/restore")
        upload.httpMethod = "POST"
        upload.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: upload, fromFile: archive)
        try check(response, data)
        struct Restored: Decodable { let restored: Bool; let harnessRunning: Bool? }
        let result = try JSONDecoder().decode(Restored.self, from: data)
        guard result.restored else { throw ProjectTransferError.unavailable }
        return result.harnessRunning ?? true
    }

    func beginDiskGrowth(bytes: UInt64) async throws -> String {
        let data = try await storageOperation("begin", body: ["bytes": bytes])
        struct Lease: Decodable { let lease: String }
        return try JSONDecoder().decode(Lease.self, from: data).lease
    }

    func finishDiskGrowth(lease: String) async throws -> UInt64 {
        let data = try await storageOperation("finish", body: ["lease": lease])
        struct Capacity: Decodable { let capacityBytes: UInt64 }
        return try JSONDecoder().decode(Capacity.self, from: data).capacityBytes
    }

    func cancelDiskGrowth(lease: String) async throws {
        _ = try await storageOperation("cancel", body: ["lease": lease])
    }

    private func storageOperation(_ action: String, body: [String: Any]) async throws -> Data {
        var operation = request("storage/" + action)
        operation.httpMethod = "POST"
        operation.timeoutInterval = action == "finish" ? 110 : 5
        operation.setValue("application/json", forHTTPHeaderField: "Content-Type")
        operation.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: operation)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            let code = try? JSONDecoder().decode([String: String].self, from: data)["error"]
            if code == "BACKUP_BUSY" { throw UserDiskError.busy }
            if code == "DISK_SIZE_INVALID" { throw UserDiskError.invalidSize }
            throw UserDiskError.incomplete
        }
        return data
    }

    static func verify(archive: URL, checksumFile: URL) throws {
        let line = try String(contentsOf: checksumFile, encoding: .utf8)
        guard let expected = line.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              expected.count == 64 else { throw ProjectTransferError.checksumMismatch }
        guard try sha256(of: archive) == expected else { throw ProjectTransferError.checksumMismatch }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func encode(_ name: String) throws -> String {
        guard !name.isEmpty, let encoded = name.addingPercentEncoding(withAllowedCharacters: Self.unreservedASCII) else {
            throw ProjectTransferError.invalidName
        }
        return encoded
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.setValue(token, forHTTPHeaderField: "X-Harness-Transfer")
        return request
    }

    private func check(_ response: URLResponse, _ data: Data?) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0)["error"] }
            throw ProjectTransferError(code: code, status: status)
        }
    }
}

struct TrashItem: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Milliseconds since 1970.
    let deletedAt: Double
    /// Disk usage; nil while the guest is still measuring.
    let bytes: Int64?

    var deletedDate: Date { Date(timeIntervalSince1970: deletedAt / 1000) }
}

enum ProjectTransferError: Error, LocalizedError, Equatable {
    case invalidName
    case notFound
    case invalidArchive
    case checksumMismatch
    case workspaceUnavailable
    case writersBusy
    case unavailable

    init(code: String?, status: Int) {
        switch code {
        case "PROJECT_NOT_FOUND", "TRASH_NOT_FOUND": self = .notFound
        case "ARCHIVE_LAYOUT", "ARCHIVE_INVALID": self = .invalidArchive
        case "WRITERS_BUSY", "BACKUP_BUSY": self = .writersBusy
        case "WORKSPACE_UNAVAILABLE": self = .workspaceUnavailable
        default: self = .unavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidName: return "项目名称无效"
        case .notFound: return "找不到该项目，可能已被移动或删除"
        case .invalidArchive: return "归档无效：需要由本应用导出的、只含一个项目目录的 tar"
        case .checksumMismatch: return "SHA256 校验不一致，未导入"
        case .writersBusy: return "任务尚未停止，未备份或替换原数据。请先停止终端里的长任务，再重试。"
        case .workspaceUnavailable: return "无法同步官方工作区，未移动或清空项目文件。请等 Harness 就绪后重试；部分会话可能已归档。"
        case .unavailable: return "运行环境暂不可用，请等 Harness 就绪后重试"
        }
    }
}
