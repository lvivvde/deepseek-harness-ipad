import CryptoKit
import Foundation

/// Incremental SHA-256, so archives and extracted files are hashed while they stream.
public struct StreamingDigest {
    private var hasher = SHA256()

    public init() {}

    public mutating func update(_ data: Data) { hasher.update(data: data) }

    /// Hex of the bytes seen so far; the running state is left untouched.
    public func hex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }

    public static func hex(_ data: Data) -> String {
        var digest = StreamingDigest()
        digest.update(data)
        return digest.hex()
    }
}
