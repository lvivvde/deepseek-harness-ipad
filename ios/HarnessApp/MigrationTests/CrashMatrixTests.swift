import Foundation
import XCTest
import UserDataMigration

/// Real process death: `migration-crash-probe` SIGKILLs itself at each stage, then a fresh process retries.
final class CrashMatrixTests: MigrationTestCase {
    var probe: String {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("migration-crash-probe").path
    }

    func launch(_ extra: [String]) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probe)
        process.arguments = [archive, checksum, target] + extra
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        return (process, output)
    }

    func runProbe(_ extra: [String] = []) throws -> (status: Int32, reason: Process.TerminationReason, output: String) {
        let (process, output) = try launch(extra)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, process.terminationReason, String(decoding: data, as: UTF8.self))
    }

    func archiveWithSessions() throws -> TarWriter {
        var tar = try sessionsArchive(compressed: true)
        tar.directory("projects/演示/src")
        for index in 1...4 { tar.file("projects/演示/src/f\(index).txt", String(repeating: "\(index)", count: 4096)) }
        tar.symlink("projects/演示/link", to: "src/f1.txt")
        tar.hardlink("projects/演示/same.txt", to: "projects/演示/src/f2.txt")
        return tar
    }

    /// The marker of a clean in-process run into a separate target, as the reference for every retry.
    func referenceMarker() throws -> Data {
        let other = root + "/reference/UserData"
        try FileManager.default.createDirectory(atPath: root + "/reference", withIntermediateDirectories: true)
        var options = MigrationOptions()
        options.codec = try DynamicZstd()
        _ = try UserDataMigrator(archive: archive, checksum: checksum, target: other, options: options).run()
        return try Data(contentsOf: URL(fileURLWithPath: other + "/" + UserDataMigrator.marker))
    }

    func testKilledAtEveryStageLeavesTargetUntouchedAndRetries() throws {
        try write(try archiveWithSessions())
        let reference = try referenceMarker()
        let points = ["digest", "plan", "extract#1", "extract#3", "verify", "sessions#1", "sessions#2", "marker", "switching", "switched"]
        XCTAssertEqual(Set(points.map { String($0.split(separator: "#")[0]) }), Set(MigrationStage.allCases.map(\.rawValue)))
        for point in points {
            try? FileManager.default.removeItem(atPath: target)
            let killed = try runProbe([point])
            XCTAssertEqual(killed.reason, .uncaughtSignal, point)
            XCTAssertEqual(killed.status, SIGKILL, point)
            XCTAssertEqual(killed.output, "KILL \(point)\n", point)
            if point == "switched" {
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target + "/" + UserDataMigrator.marker)), reference, point)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target), point)
            }

            let retry = try runProbe()
            XCTAssertEqual(retry.status, 0, point)
            XCTAssertEqual(retry.output, point == "switched" ? "RESULT already\n" : "RESULT migrated 8\n", point)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target + "/" + UserDataMigrator.marker)), reference, point)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root + "/data").filter { $0.hasPrefix(UserDataMigrator.stagePrefix) }
            XCTAssertEqual(leftovers, [], point)
            XCTAssertEqual(try runProbe().output, "RESULT already\n", point)
        }
    }

    func testSecondProcessIsBusyWhileFirstHoldsTheLock() throws {
        try write(try archiveWithSessions())
        let (holder, output) = try launch(["hold"])
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            line += chunk
        }
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "HOLD\n")
        XCTAssertEqual(try runProbe().output, "ERROR MIGRATION_BUSY\n")
        XCTAssertThrowsError(try migrator().run()) { XCTAssertEqual($0 as? MigrationError, .busy) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        XCTAssertEqual(try runProbe().output, "RESULT migrated 8\n", "the lock dies with its holder")
    }
}
