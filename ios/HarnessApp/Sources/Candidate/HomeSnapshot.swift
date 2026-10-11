import Foundation

/// The production Worker transport. Decode and validate the entire home before writing or seeding it.
struct HomeSnapshot: Codable {
    struct Directory: Codable { let path: String; let mode: Int; let mtimeMs: Double }
    struct File: Codable { let path: String; let mode: Int; let mtimeMs: Double; let base64: String }
    let formatVersion: Int
    let directories: [Directory]
    let files: [File]

    static func decode(_ value: Any?) throws -> HomeSnapshot {
        guard let value, JSONSerialization.isValidJSONObject(value) else { throw CandidateError("SNAPSHOT_REFUSED") }
        // Path refusals remain distinct from malformed bytes/metadata.
        if let object = value as? [String: Any] {
            for entry in (object["files"] as? [[String: Any]] ?? []) + (object["directories"] as? [[String: Any]] ?? []) {
                if let path = entry["path"] as? String { try validatePath(path) }
            }
        }
        do {
            let snapshot = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
            try snapshot.validate()
            return snapshot
        } catch let error as CandidateError { throw error }
        catch { throw CandidateError("SNAPSHOT_REFUSED") }
    }

    static func validatePath(_ path: String) throws {
        guard path == "/dsh/home" || path.hasPrefix("/dsh/home/"), !path.contains("\0"),
              !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw CandidateError("HOME_ONLY_CHECKPOINT") }
        if path.hasPrefix("/dsh/home/.credentials.yaml") { throw CandidateError("CREDENTIALS_NOT_CHECKPOINTED") }
    }

    func validate() throws {
        guard formatVersion == 1 else { throw CandidateError("SNAPSHOT_VERSION") }
        var types: [String: Bool] = [:]
        for (path, mode, time, directory) in directories.map({ ($0.path, $0.mode, $0.mtimeMs, true) }) + files.map({ ($0.path, $0.mode, $0.mtimeMs, false) }) {
            try Self.validatePath(path)
            guard types[path] == nil, time.isFinite, time >= 0, mode >= 0, mode <= 0o177777,
                  mode & 0o170000 == (directory ? 0o040000 : 0o100000), directory || path != "/dsh/home"
            else { throw CandidateError("SNAPSHOT_REFUSED") }
            types[path] = directory
        }
        for path in types.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while parent.hasPrefix("/dsh/home") {
                if types[parent] == false { throw CandidateError("SNAPSHOT_REFUSED") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for file in files {
            guard let bytes = Data(base64Encoded: file.base64), bytes.base64EncodedString() == file.base64 else { throw CandidateError("SNAPSHOT_REFUSED") }
        }
    }
}
