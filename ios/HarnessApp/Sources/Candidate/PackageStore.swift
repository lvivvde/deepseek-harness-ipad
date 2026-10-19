import Foundation
import CryptoKit

/// Plugin package tarballs (#23), keyed by their sha512 integrity. The Worker's native pnpm stores each
/// verified tarball here once and unpacks the locked tree from it at every Worker start, so the home
/// checkpoint never carries node_modules. Bytes are accepted only when they match their integrity.
final class PackageStore {
    private let directory: String
    private let lock = NSLock()
    init(root: String) { directory = root + "/packages" }

    /// `sha512-<base64>` to its hex digest, the file name; anything else is refused.
    private static func digest(_ integrity: Any?) throws -> String {
        guard let text = integrity as? String, text.hasPrefix("sha512-"),
              let bytes = Data(base64Encoded: String(text.dropFirst(7))), bytes.count == 64 else { throw CandidateError("PACKAGE_REFUSED") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func hex(_ data: Data) -> String { SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func path(_ digest: String) -> String { directory + "/" + digest + ".tgz" }

    func put(_ body: [String: Any]) throws -> [String: Any] {
        let digest = try Self.digest(body["integrity"])
        guard let text = body["base64"] as? String, let data = Data(base64Encoded: text) else { throw CandidateError("PACKAGE_REFUSED") }
        guard Self.hex(data) == digest else { throw CandidateError("PACKAGE_INTEGRITY") }
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: path(digest)) {
            do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
            catch { throw CandidateError("STORE_FAILED") }
            try ProjectRegistry.durableWrite(data, to: path(digest))
        }
        return ["stored": true]
    }

    func get(_ body: [String: Any]) throws -> [String: Any] {
        let digest = try Self.digest(body["integrity"])
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: path(digest)) else { throw CandidateError("PACKAGE_MISSING") }
        // A damaged file is reported as missing rather than unpacked.
        guard Self.hex(data) == digest else { throw CandidateError("PACKAGE_MISSING") }
        return ["base64": data.base64EncodedString()]
    }

    /// Remove every stored tarball the current lock no longer names.
    func keep(_ body: [String: Any]) throws -> [String: Any] {
        guard let list = body["integrities"] as? [Any] else { throw CandidateError("PACKAGE_REFUSED") }
        let kept = Set(try list.map { try Self.digest($0) + ".tgz" })
        lock.lock(); defer { lock.unlock() }
        var removed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where !kept.contains(name) {
            if (try? FileManager.default.removeItem(atPath: directory + "/" + name)) != nil { removed += 1 }
        }
        return ["removed": removed]
    }
}
