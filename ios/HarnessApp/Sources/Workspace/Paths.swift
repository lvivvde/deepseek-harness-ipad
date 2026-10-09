import CryptoKit
import Darwin
import Foundation

/// A workspace-relative path compared byte for byte. Swift `String` equality is canonical
/// equivalence, so NFC and NFD spellings of one name would collide as `String` keys; a Linux
/// guest can create both, and the store must keep them apart.
public struct RelativePath: Hashable, Comparable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(_ string: String) { bytes = Array(string.utf8) }

    public var components: [[UInt8]] { bytes.split(separator: 0x2F, omittingEmptySubsequences: false).map(Array.init) }
    public func appending(_ name: [UInt8]) -> RelativePath { RelativePath(bytes: bytes.isEmpty ? name : bytes + [0x2F] + name) }
    public static func < (a: RelativePath, b: RelativePath) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }

    /// Exact UTF-8 text when the bytes are valid UTF-8 (no BOM stripping, no normalization).
    public var text: String? {
        let decoded = String(decoding: bytes, as: UTF8.self)
        return Array(decoded.utf8) == bytes ? decoded : nil
    }
    public var description: String { text ?? "b64:" + Data(bytes).base64EncodedString() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self.init(text); return }
        let object = try container.decode([String: String].self)
        guard let encoded = object["b64"], let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "path encoding")
        }
        self.init(bytes: Array(data))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let text { try container.encode(text) } else { try container.encode(["b64": Data(bytes).base64EncodedString()]) }
    }

    /// Native writes accept only plain descendants: no absolute, empty, `.`, `..` or NUL components,
    /// and nothing the store reserves for itself.
    public func validate() throws {
        guard !bytes.isEmpty, bytes.first != 0x2F, !bytes.contains(0) else { throw WorkspaceError.pathRefused("PATH_REFUSED") }
        for component in components where component.isEmpty || component == [0x2E] || component == [0x2E, 0x2E] {
            throw WorkspaceError.pathRefused("PATH_REFUSED")
        }
        if bytes == WorkspaceFiles.identity || components.last!.starts(with: WorkspaceFiles.temporaryPrefix) {
            throw WorkspaceError.pathRefused("PATH_RESERVED")
        }
    }
}

public enum WorkspaceError: Error, Equatable, CustomStringConvertible {
    case pathRefused(String)
    case io(String, Int32)
    public var description: String {
        switch self {
        case .pathRefused(let reason): return reason
        case .io(let call, let code): return "\(call): \(String(cString: strerror(code)))"
        }
    }
}

func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
