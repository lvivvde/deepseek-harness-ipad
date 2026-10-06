import Darwin
import Foundation

/// Fixed failure codes. Messages never carry user paths except the conflict and skip lists, which
/// stay in the private report.
public enum MigrationError: Error, Equatable, CustomStringConvertible {
    case checksumFileInvalid
    case digestMismatch
    case archiveCorrupt
    case archiveUnsafe(String)
    case layoutInvalid
    case insufficientSpace
    case nameConflict([String])
    case verifyFailed
    case sessionInvalid
    case sessionDecoderUnavailable
    case targetExists
    case busy
    case io(String, Int32)

    public var code: String {
        switch self {
        case .checksumFileInvalid: return "CHECKSUM_FILE_INVALID"
        case .digestMismatch: return "DIGEST_MISMATCH"
        case .archiveCorrupt: return "ARCHIVE_CORRUPT"
        case .archiveUnsafe: return "ARCHIVE_UNSAFE"
        case .layoutInvalid: return "LAYOUT_INVALID"
        case .insufficientSpace: return "INSUFFICIENT_SPACE"
        case .nameConflict: return "NAME_CONFLICT"
        case .verifyFailed: return "VERIFY_FAILED"
        case .sessionInvalid: return "SESSION_INVALID"
        case .sessionDecoderUnavailable: return "SESSION_DECODER_UNAVAILABLE"
        case .targetExists: return "TARGET_EXISTS"
        case .busy: return "MIGRATION_BUSY"
        case .io: return "IO_FAILED"
        }
    }
    public var description: String {
        switch self {
        case .archiveUnsafe(let reason): return "ARCHIVE_UNSAFE:" + reason
        case .io(let call, let code): return "IO_FAILED:\(call):\(code)"
        default: return code
        }
    }
}

public struct TarEntry: Equatable {
    public enum Kind: Equatable {
        case file, directory, symlink, hardlink
        /// FIFO, character or block device: never created, only reported.
        case special(UInt8)
    }
    public let path: [UInt8]
    public let kind: Kind
    public let mode: UInt32
    public let size: Int
    public let link: [UInt8]
}

/// Streaming reader for the ustar archives node-tar writes (`portable: true`), including pax `x`
/// records for long or non-ASCII names and GNU `L`/`K` long names. Every header checksum is checked
/// and a missing end-of-archive marker counts as truncation, so a cut or flipped archive is
/// `archiveCorrupt` rather than a silently shorter tree.
public final class TarReader {
    private let descriptor: Int32
    private var remaining = 0
    private var padding = 0
    private var finished = false
    public private(set) var digest = StreamingDigest()

    public init(descriptor: Int32) { self.descriptor = descriptor }

    /// The next entry, or nil at the end-of-archive marker. Unread file content is skipped.
    public func next() throws -> TarEntry? {
        guard !finished else { return nil }
        try skipBody()
        var pax: [String: [UInt8]] = [:]
        var longName: [UInt8]?, longLink: [UInt8]?
        while true {
            let block = try readBlock()
            if block.allSatisfy({ $0 == 0 }) {
                // End marker: two zero blocks. Anything else is a cut archive.
                guard try readBlock().allSatisfy({ $0 == 0 }) else { throw MigrationError.archiveCorrupt }
                try drain()
                finished = true
                return nil
            }
            try checkChecksum(block)
            let type = block[156]
            let size = try number(block[124..<136])
            switch type {
            case UInt8(ascii: "x"):
                pax.merge(try paxRecords(try readMeta(size))) { $1 }
                continue
            case UInt8(ascii: "g"):
                _ = try readMeta(size)
                continue
            case UInt8(ascii: "L"):
                longName = trimNul(try readMeta(size)); continue
            case UInt8(ascii: "K"):
                longLink = trimNul(try readMeta(size)); continue
            default: break
            }
            var path = trimNul(Array(block[0..<100]))
            if block[257..<262].elementsEqual("ustar".utf8) {
                let prefix = trimNul(Array(block[345..<500]))
                if !prefix.isEmpty { path = prefix + [0x2F] + path }
            }
            if let longName { path = longName }
            if let value = pax["path"] { path = value }
            var link = trimNul(Array(block[157..<257]))
            if let longLink { link = longLink }
            if let value = pax["linkpath"] { link = value }
            var bodySize = size
            if let value = pax["size"] {
                guard let text = String(bytes: value, encoding: .utf8), let parsed = Int(text), parsed >= 0 else { throw MigrationError.archiveCorrupt }
                bodySize = parsed
            }
            let mode = UInt32(try number(block[100..<108]) & 0o7777)
            let kind: TarEntry.Kind
            switch type {
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): kind = path.last == 0x2F ? .directory : .file
            case UInt8(ascii: "1"): kind = .hardlink; bodySize = 0
            case UInt8(ascii: "2"): kind = .symlink; bodySize = 0
            case UInt8(ascii: "5"): kind = .directory; bodySize = 0
            case UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "6"): kind = .special(type); bodySize = 0
            default: throw MigrationError.archiveUnsafe("ENTRY_TYPE")
            }
            remaining = bodySize
            padding = (512 - bodySize % 512) % 512
            return TarEntry(path: path, kind: kind, mode: mode, size: bodySize, link: link)
        }
    }

    /// Streams the current entry's content in chunks.
    public func readBody(_ body: (Data) throws -> Void) throws {
        while remaining > 0 {
            let chunk = try readExactly(min(remaining, 1 << 20))
            remaining -= chunk.count
            try body(chunk)
        }
        _ = try readExactly(padding)
        padding = 0
    }

    private func skipBody() throws { try readBody { _ in } }

    /// Reads to EOF after the end marker, so the digest covers the whole file (node-tar pads to a record).
    private func drain() throws {
        while try !readUpTo(1 << 20).isEmpty {}
    }

    private func readMeta(_ size: Int) throws -> [UInt8] {
        guard size <= 1 << 20 else { throw MigrationError.archiveUnsafe("HEADER_SIZE") }
        let data = Array(try readExactly(size))
        _ = try readExactly((512 - size % 512) % 512)
        return data
    }

    private func readBlock() throws -> [UInt8] { Array(try readExactly(512)) }

    private func readExactly(_ count: Int) throws -> Data {
        let data = try readUpTo(count)
        guard data.count == count else { throw MigrationError.archiveCorrupt }
        return data
    }

    private func readUpTo(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let read = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, count - offset) }
            if read < 0 { if errno == EINTR { continue }; throw MigrationError.io("read", errno) }
            if read == 0 { break }
            offset += read
        }
        data.count = offset
        digest.update(data)
        return data
    }

    private func checkChecksum(_ block: [UInt8]) throws {
        let stored = try number(block[148..<156])
        var unsigned = 0, signed = 0
        for (index, byte) in block.enumerated() {
            let value = (148..<156).contains(index) ? 0x20 : byte
            unsigned += Int(value); signed += Int(Int8(bitPattern: value))
        }
        guard stored == unsigned || stored == signed else { throw MigrationError.archiveCorrupt }
    }

    /// Octal (space or NUL terminated) or GNU base-256 for large values.
    private func number(_ field: ArraySlice<UInt8>) throws -> Int {
        guard let first = field.first else { throw MigrationError.archiveCorrupt }
        if first & 0x80 != 0 {
            guard first == 0x80 else { throw MigrationError.archiveCorrupt }
            var value = 0
            for byte in field.dropFirst() {
                guard value < Int.max >> 8 else { throw MigrationError.archiveCorrupt }
                value = value << 8 | Int(byte)
            }
            return value
        }
        var value = 0, seen = false
        for byte in field {
            if byte == 0 || byte == 0x20 { if seen { break } else { continue } }
            guard (0x30...0x37).contains(byte), value < Int.max >> 3 else { throw MigrationError.archiveCorrupt }
            value = value << 3 | Int(byte - 0x30); seen = true
        }
        return value
    }

    /// "<length> <key>=<value>\n" records; values are raw bytes (paths may be any UTF-8).
    private func paxRecords(_ bytes: [UInt8]) throws -> [String: [UInt8]] {
        var records: [String: [UInt8]] = [:]
        var index = 0
        while index < bytes.count {
            guard let space = bytes[index...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: bytes[index..<space], as: UTF8.self)),
                  length > space - index, index + length <= bytes.count, bytes[index + length - 1] == 0x0A,
                  let equals = bytes[(space + 1)..<(index + length)].firstIndex(of: 0x3D) else {
                throw MigrationError.archiveCorrupt
            }
            records[String(decoding: bytes[(space + 1)..<equals], as: UTF8.self)] = Array(bytes[(equals + 1)..<(index + length - 1)])
            index += length
        }
        return records
    }

    private func trimNul(_ bytes: [UInt8]) -> [UInt8] {
        guard let end = bytes.firstIndex(of: 0) else { return bytes }
        return Array(bytes[..<end])
    }
}
