import CryptoKit
import Darwin
import Foundation

/// Something recovery found wrong in the journal. Only the valid complete prefix before it was
/// replayed; the original file was copied to `quarantine/` first and is never deleted.
public struct JournalAnomaly: Equatable, CustomStringConvertible {
    public enum Kind: String {
        case emptyFile = "EMPTY_FILE", badHeader = "BAD_HEADER", tornTail = "TORN_TAIL", checksum = "CHECKSUM"
        case duplicate = "DUPLICATE", sequenceGap = "SEQUENCE_GAP"
        case badSnapshot = "BAD_SNAPSHOT", badCheckpoint = "BAD_CHECKPOINT"
    }
    public let kind: Kind
    /// Byte offset of the first data that was not used.
    public let offset: Int
    /// File name under the state directory's `quarantine/`.
    public let quarantined: String
    public var description: String { "\(kind.rawValue)@\(offset) -> quarantine/\(quarantined)" }
}

/// Keeps damaged or unexplained files for inspection. Nothing that reaches it is deleted.
final class Quarantine {
    let directory: String
    init(directory: String) { self.directory = directory }

    private func target(_ label: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "\(stamp)-\(UUID().uuidString.prefix(8).lowercased())-\(label)"
    }

    func keep(_ data: Data, label: String) throws -> String {
        let name = target(label)
        let directory = try openDirectory(self.directory)
        defer { close(directory) }
        try atomicReplace(directory: directory, name: Array(name.utf8), temporary: temporaryName(), data: data,
                          mode: 0o600, site: .journal, fault: nil)
        return name
    }

    /// Moves `source` in; on a cross-volume move it copies, syncs, then unlinks the source.
    func move(_ source: String, label: String) throws -> String {
        let name = target(label)
        if rename(source, directory + "/" + name) == 0 {
            let directory = try openDirectory(self.directory)
            defer { close(directory) }
            try fullSync(directory)
            return name
        }
        guard errno == EXDEV else { throw WorkspaceError.io("rename", errno) }
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let kept = try keep(data, label: label)
        unlink(source)
        return kept
    }
}

/// Append-only record log. File: the 8-byte magic, then frames of
/// `u32 LE payload length | u64 LE sequence | 16-byte truncated SHA-256(sequence ‖ payload) | payload`.
/// A record is committed once its frame is fully synced. Recovery stops at the first frame that is
/// short, fails its checksum, or breaks the strictly increasing sequence.
final class Journal {
    static let magic = Array("DSHJRNL1".utf8)
    static let frameHeader = 4 + 8 + 16

    let directory: String
    let name: String
    var fault: FaultHook?
    private(set) var lastSequence: UInt64
    private(set) var recordCount = 0
    private var length: Int
    private var descriptor: Int32

    private init(directory: String, name: String, lastSequence: UInt64, length: Int, descriptor: Int32) {
        self.directory = directory; self.name = name; self.lastSequence = lastSequence
        self.length = length; self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    static func checksum(_ sequence: UInt64, _ payload: Data) -> [UInt8] {
        var hasher = SHA256()
        withUnsafeBytes(of: sequence.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: payload)
        return Array(hasher.finalize().prefix(16))
    }

    static func frame(_ sequence: UInt64, _ payload: Data) -> Data {
        var frame = Data()
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: checksum(sequence, payload))
        frame.append(payload)
        return frame
    }

    /// Opens (or creates) the journal and returns the committed payloads after `after`, which a
    /// snapshot already covers; `nil` (no usable snapshot) accepts whatever sequence comes first. On damage the original goes to quarantine and the journal is
    /// atomically rewritten as its valid prefix, so the next append extends committed history only.
    static func open(directory: String, name: String = "journal.log", after: UInt64?, quarantine: Quarantine)
        throws -> (Journal, [Data], JournalAnomaly?)
    {
        let path = directory + "/" + name
        var payloads: [Data] = [], anomaly: JournalAnomaly?
        var last = after ?? 0, validEnd = magic.count, anchored = after != nil
        let existing = FileManager.default.fileExists(atPath: path)
        let bytes = existing ? try Data(contentsOf: URL(fileURLWithPath: path)) : Data(magic)
        var kind: JournalAnomaly.Kind?
        if bytes.isEmpty { kind = .emptyFile; validEnd = 0 }
        else if bytes.count < magic.count || Array(bytes.prefix(magic.count)) != magic { kind = .badHeader; validEnd = 0 }
        var offset = magic.count
        while kind == nil && offset < bytes.count {
            guard bytes.count - offset >= frameHeader else { kind = .tornTail; break }
            let base = bytes.startIndex + offset
            let size = Int(bytes[base..<base + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            let sequence = bytes[base + 4..<base + 12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
            guard bytes.count - offset - frameHeader >= size else { kind = .tornTail; break }
            let payload = bytes[base + frameHeader..<base + frameHeader + size]
            guard Array(bytes[base + 12..<base + 28]) == checksum(sequence, Data(payload)) else { kind = .checksum; break }
            if !anchored { last = sequence &- 1; anchored = true }
            if sequence > (after ?? 0) {
                if sequence <= last { kind = .duplicate; break }
                if sequence != last + 1 { kind = .sequenceGap; break }
                payloads.append(Data(payload)); last = sequence
            }
            offset += frameHeader + size
            validEnd = offset
        }
        if let kind {
            let kept = try quarantine.keep(bytes, label: name)
            anomaly = JournalAnomaly(kind: kind, offset: validEnd, quarantined: kept)
        }
        if !existing || anomaly != nil {
            let valid = validEnd >= magic.count ? Data(bytes.prefix(validEnd)) : Data(magic)
            let handle = try openDirectory(directory)
            defer { close(handle) }
            try atomicReplace(directory: handle, name: Array(name.utf8), temporary: temporaryName(), data: valid,
                              mode: 0o600, site: .journal, fault: nil)
            validEnd = valid.count
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.io("open", errno) }
        let journal = Journal(directory: directory, name: name, lastSequence: last, length: validEnd, descriptor: descriptor)
        journal.recordCount = payloads.count
        return (journal, payloads, anomaly)
    }

    /// Appends one record and syncs it. On any failure the file is cut back to its previous
    /// length, so a failed append leaves no partial frame behind.
    func append(_ payload: Data) throws {
        let sequence = lastSequence + 1
        let frame = Self.frame(sequence, payload)
        do {
            guard lseek(descriptor, off_t(length), SEEK_SET) >= 0 else { throw WorkspaceError.io("lseek", errno) }
            let half = frame.count / 2
            try writeAll(descriptor, frame.prefix(half))
            try fault?(FaultPoint(.journal, .halfWritten))
            try writeAll(descriptor, frame.dropFirst(half))
            try fault?(FaultPoint(.journal, .beforeSync))
            try fullSync(descriptor)
        } catch {
            ftruncate(descriptor, off_t(length))
            try? fullSync(descriptor)
            throw error
        }
        length += frame.count
        lastSequence = sequence
        recordCount += 1
    }

    /// Replaces the journal with an empty one after a snapshot covering `lastSequence` is durable.
    /// Whether or not the replacement got as far as the rename, appends continue on whatever file
    /// is now at the journal path, never on an unlinked one.
    func reset() throws {
        let handle = try openDirectory(directory)
        defer { close(handle) }
        do {
            try atomicReplace(directory: handle, name: Array(name.utf8), temporary: temporaryName(), data: Data(Self.magic),
                              mode: 0o600, site: .journal, fault: fault)
        } catch {
            try reopen()
            throw error
        }
        try reopen()
    }

    private func reopen() throws {
        let next = Darwin.open(directory + "/" + name, O_WRONLY | O_CLOEXEC)
        guard next >= 0 else { throw WorkspaceError.io("open", errno) }
        var info = stat()
        guard fstat(next, &info) == 0 else { let code = errno; close(next); throw WorkspaceError.io("fstat", code) }
        close(descriptor)
        descriptor = next
        if Int(info.st_size) != length { length = Int(info.st_size); recordCount = 0 }
    }
}
