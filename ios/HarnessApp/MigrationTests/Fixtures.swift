import Foundation
import XCTest
import UserDataMigration

/// Writes ustar archives in node-tar's portable shape (pax `x` headers for long or non-ASCII names),
/// so tests can build hostile archives the real exporter never would.
struct TarWriter {
    private(set) var data = Data()

    enum Kind: UInt8 {
        case file = 0x30, hardlink = 0x31, symlink = 0x32, character = 0x33, directory = 0x35, fifo = 0x36, volume = 0x56
    }

    mutating func file(_ path: String, _ text: String, mode: Int = 0o644) { add(path, .file, mode: mode, body: Data(text.utf8)) }
    mutating func directory(_ path: String, mode: Int = 0o755) { add(path.hasSuffix("/") ? path : path + "/", .directory, mode: mode) }
    mutating func symlink(_ path: String, to link: String) { add(path, .symlink, mode: 0o777, link: link) }
    mutating func hardlink(_ path: String, to link: String) { add(path, .hardlink, mode: 0o644, link: link) }

    mutating func add(_ path: String, _ kind: Kind, mode: Int, body: Data = Data(), link: String = "") {
        var pax = ""
        if path.utf8.count > 99 || !path.allSatisfy(\.isASCII) { pax += record("path", path) }
        if link.utf8.count > 99 || !link.allSatisfy(\.isASCII) { pax += record("linkpath", link) }
        if !pax.isEmpty {
            let paxBody = Data(pax.utf8)
            appendHeader(name: "PaxHeader/x", type: 0x78, mode: 0o644, size: paxBody.count, link: "")
            appendBody(paxBody)
        }
        appendHeader(name: String(path.utf8.prefix(99).map { $0 < 0x80 ? Character(UnicodeScalar($0)) : "_" }),
                     type: kind.rawValue, mode: mode, size: body.count,
                     link: String(link.utf8.prefix(99).map { $0 < 0x80 ? Character(UnicodeScalar($0)) : "_" }))
        appendBody(body)
    }

    /// Two zero blocks, padded to a 10 KiB record like node-tar.
    mutating func finish() -> Data {
        data.append(Data(count: 1024))
        let record = 10240
        if data.count % record != 0 { data.append(Data(count: record - data.count % record)) }
        return data
    }

    private func record(_ key: String, _ value: String) -> String {
        let body = " \(key)=\(value)\n"
        var length = body.utf8.count + 1
        while "\(length)\(body)".utf8.count != length { length += 1 }
        return "\(length)\(body)"
    }

    private mutating func appendHeader(name: String, type: UInt8, mode: Int, size: Int, link: String) {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ offset: Int, _ width: Int) {
            for (index, byte) in text.utf8.prefix(width).enumerated() { header[offset + index] = byte }
        }
        func octal(_ value: Int, _ offset: Int, _ width: Int) {
            put(String(String(value, radix: 8).suffix(width - 1)).leftPadded(width - 1) + "\0", offset, width)
        }
        put(name, 0, 100)
        octal(mode, 100, 8); octal(0, 108, 8); octal(0, 116, 8); octal(size, 124, 12); octal(1_700_000_000, 136, 12)
        header[156] = type
        put(link, 157, 100)
        put("ustar\0", 257, 6); put("00", 263, 2)
        for index in 148..<156 { header[index] = 0x20 }
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(String(sum, radix: 8)).leftPadded(6) + "\0 ", 148, 8)
        data.append(contentsOf: header)
    }

    private mutating func appendBody(_ body: Data) {
        data.append(body)
        if body.count % 512 != 0 { data.append(Data(count: 512 - body.count % 512)) }
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

extension TarWriter {
    /// The minimum the old app's restore accepts: layout version, `projects/` and `.dsh/`.
    static func base() -> TarWriter {
        var tar = TarWriter()
        tar.file(".harness-layout-version", "1\n")
        tar.directory("projects")
        tar.directory(".dsh")
        return tar
    }
}

/// Temporary root with an archive, its sidecar and a target path beside them.
class MigrationTestCase: XCTestCase {
    var root = ""
    var archive: String { root + "/inbox/HarnessBackup.tar" }
    var checksum: String { archive + ".sha256" }
    var target: String { root + "/data/UserData" }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "migration-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/inbox", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/data", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Read-only directories from the archive would block removal.
        if let walker = FileManager.default.enumerator(atPath: root) {
            for case let path as String in walker { chmod(root + "/" + path, 0o755) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Writes the archive and a matching sidecar (or `sidecar` verbatim).
    func write(_ tar: TarWriter, sidecar: String? = nil) throws {
        var copy = tar
        let bytes = copy.finish()
        try writeRaw(bytes, sidecar: sidecar)
    }

    func writeRaw(_ bytes: Data, sidecar: String? = nil) throws {
        try bytes.write(to: URL(fileURLWithPath: archive))
        let line = sidecar ?? StreamingDigest.hex(bytes) + "  HarnessBackup.tar\n"
        try Data(line.utf8).write(to: URL(fileURLWithPath: checksum))
    }

    func migrator(_ configure: (inout MigrationOptions) -> Void = { _ in }) -> UserDataMigrator {
        var options = MigrationOptions()
        options.codec = try? DynamicZstd()
        configure(&options)
        return UserDataMigrator(archive: archive, checksum: checksum, target: target, options: options)
    }

    func report(_ outcome: MigrationOutcome, file: StaticString = #filePath, line: UInt = #line) -> MigrationReport? {
        guard case .migrated(let report) = outcome else { XCTFail("not migrated: \(outcome)", file: file, line: line); return nil }
        return report
    }

    func assertFails(_ expected: MigrationError, _ configure: (inout MigrationOptions) -> Void = { _ in },
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try migrator(configure).run(), file: file, line: line) { error in
            XCTAssertEqual(error as? MigrationError, expected, file: file, line: line)
        }
        assertUntouched(file: file, line: line)
    }

    /// No target, no stage left beside it.
    func assertUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "target created", file: file, line: line)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root + "/data"))?
            .filter { $0.hasPrefix(UserDataMigrator.stagePrefix) } ?? []
        XCTAssertEqual(leftovers, [], "stage left behind", file: file, line: line)
    }

    func text(_ path: String) -> String? { try? String(contentsOfFile: target + "/" + path, encoding: .utf8) }

    func mode(_ path: String) -> Int {
        var info = stat()
        lstat(target + "/" + path, &info)
        return Int(info.st_mode & 0o7777)
    }
}
