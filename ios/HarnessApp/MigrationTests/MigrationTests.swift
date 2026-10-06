import Darwin
import Foundation
import XCTest
import UserDataMigration

final class MigrationTests: MigrationTestCase {
    func testMigratesBackupIntoNewLayout() throws {
        var tar = TarWriter.base()
        tar.directory("projects/演示")
        tar.file("projects/演示/笔记.txt", "第一行\n", mode: 0o640)
        tar.file("projects/演示/run.sh", "#!/bin/sh\n", mode: 0o755)
        tar.file("projects/演示/readonly.txt", "r", mode: 0o400)
        tar.directory("projects/演示/空目录")
        tar.directory("projects/locked", mode: 0o500)
        tar.file("projects/locked/inside.txt", "inside")
        tar.symlink("projects/演示/link", to: "笔记.txt")
        tar.hardlink("projects/演示/hard", to: "projects/演示/笔记.txt")
        tar.file("projects/empty.txt", "")
        tar.directory(".dsh/profiles")
        tar.file(".dsh/profiles/default.json", "{}")
        tar.file(".dsh/.credentials.yaml", "token: secret")
        tar.directory(".dsh/storages/session_projcache")
        tar.file(".dsh/storages/session_projcache/a", "cache")
        tar.file(".dsh/storages/workspace.json", "{}")
        tar.file(".bashrc", "export A=1\n")
        tar.directory(".ssh", mode: 0o700)
        tar.file(".ssh/id_ed25519", "private key", mode: 0o600)
        tar.file(".netrc", "machine x password y")
        tar.add("pipe", .fifo, mode: 0o644)
        tar.add("projects/演示/tty", .character, mode: 0o644)
        try write(tar)

        let report = try XCTUnwrap(report(try migrator().run()))
        XCTAssertEqual(text("projects/演示/笔记.txt"), "第一行\n")
        XCTAssertEqual(mode("projects/演示/笔记.txt"), 0o640)
        XCTAssertEqual(mode("projects/演示/run.sh"), 0o755)
        XCTAssertEqual(mode("projects/演示/readonly.txt"), 0o600, "owner keeps read and write")
        XCTAssertEqual(mode("projects/locked"), 0o700)
        XCTAssertEqual(text("projects/locked/inside.txt"), "inside")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target + "/projects/演示/空目录"), [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target + "/projects/演示/link"), "笔记.txt")
        var original = stat(), linked = stat()
        stat(target + "/projects/演示/笔记.txt", &original); stat(target + "/projects/演示/hard", &linked)
        XCTAssertEqual(original.st_ino, linked.st_ino)
        XCTAssertEqual(text("projects/empty.txt"), "")
        XCTAssertEqual(text("home/profiles/default.json"), "{}")
        XCTAssertEqual(text("home/storages/workspace.json"), "{}")
        XCTAssertEqual(text("linux-home/.bashrc"), "export A=1\n")
        for absent in ["home/.credentials.yaml", "home/storages/session_projcache", "linux-home/.ssh", "linux-home/.netrc",
                       "linux-home/pipe", "projects/演示/tty", ".harness-layout-version", "linux-home/.harness-layout-version"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/" + absent), absent)
        }
        XCTAssertEqual(report.specialSkipped.sorted(), ["pipe", "projects/演示/tty"])
        XCTAssertEqual(report.credentialsExcluded.sorted(), [".dsh/.credentials.yaml", ".netrc", ".ssh", ".ssh/id_ed25519"])
        XCTAssertEqual(report.cacheEntriesExcluded, 2)
        XCTAssertEqual(report.hardlinks, 1)
        XCTAssertEqual(report.symlinks, 1)
        XCTAssertEqual(report.files, 8)
        XCTAssertEqual(report.archiveSha256.count, 64)
        let marker = try JSONDecoder().decode(MigrationReport.self, from: Data(contentsOf: URL(fileURLWithPath: target + "/.migration.json")))
        XCTAssertEqual(marker, report)
        assertNoStage()
    }

    func testSameArchiveGivesSameManifestDigest() throws {
        var tar = TarWriter.base()
        tar.file("projects/a.txt", "a")
        try write(tar)
        let first = try XCTUnwrap(report(try migrator().run()))
        try FileManager.default.removeItem(atPath: target)
        let second = try XCTUnwrap(report(try migrator().run()))
        XCTAssertEqual(first.manifestSha256, second.manifestSha256)
    }

    // MARK: Refusals that leave the target untouched

    func testDigestMismatch() throws {
        var tar = TarWriter.base()
        tar.file("projects/a.txt", "a")
        try write(tar, sidecar: String(repeating: "0", count: 64) + "  HarnessBackup.tar\n")
        assertFails(.digestMismatch)
    }

    func testChecksumFileInvalid() throws {
        try write(TarWriter.base(), sidecar: "not a digest\n")
        assertFails(.checksumFileInvalid)
        try FileManager.default.removeItem(atPath: checksum)
        assertFails(.checksumFileInvalid)
    }

    func testCorruptArchive() throws {
        var tar = TarWriter.base()
        tar.file("projects/a.txt", String(repeating: "x", count: 3000))
        var bytes = tar.finish()
        // A flipped header byte with a matching sidecar: the backup was damaged before it was hashed.
        var flipped = bytes
        flipped[1536 + 10] ^= 0x01
        try writeRaw(flipped)
        assertFails(.archiveCorrupt)
        // Cut inside a file body.
        try writeRaw(bytes.prefix(2560))
        assertFails(.archiveCorrupt)
        // Cut after the last entry, before the end marker.
        bytes = bytes.prefix(2048 + 512 + 3072)
        try writeRaw(bytes)
        assertFails(.archiveCorrupt)
    }

    func testUnsafeEntriesAreRefused() throws {
        let cases: [(String, (inout TarWriter) -> Void)] = [
            ("absolute", { $0.file("/etc/passwd", "x") }),
            ("dotdot", { $0.file("projects/../../escape", "x") }),
            ("dot", { $0.file("projects/./a", "x") }),
            ("control", { $0.file("projects/a\u{01}b", "x") }),
            ("reserved", { $0.file(".restore-stage-1/a", "x") }),
            ("purging", { $0.file(".trash/.purging-1", "x") }),
            ("node_modules", { $0.file("projects/a/node_modules/x", "x") }),
            ("escaping symlink", { $0.symlink("projects/out", to: "../../etc") }),
            ("absolute symlink", { $0.symlink("projects/out", to: "/etc/passwd") }),
            ("hard link to nothing", { $0.hardlink("projects/h", to: "projects/missing") }),
            ("hard link escape", { $0.hardlink("projects/h", to: "../x") }),
            ("duplicate", { $0.file("projects/a", "1"); $0.file("projects/a", "2") }),
            ("through symlink", { $0.symlink("projects/dir", to: "."); $0.file("projects/dir/x", "x") }),
            ("unknown type", { $0.add("projects/v", .volume, mode: 0o644) }),
            ("empty link", { $0.add("projects/w", .symlink, mode: 0o777, link: "") })
        ]
        for (label, build) in cases {
            var tar = TarWriter.base()
            build(&tar)
            try write(tar)
            XCTAssertThrowsError(try migrator().run(), label) { error in
                XCTAssertEqual((error as? MigrationError)?.code, "ARCHIVE_UNSAFE", "\(label): \(error)")
            }
            assertUntouched()
        }
    }

    func testLayoutMustBeTheOldAppsLayout() throws {
        var missingVersion = TarWriter()
        missingVersion.directory("projects"); missingVersion.directory(".dsh")
        var wrongVersion = TarWriter()
        wrongVersion.file(".harness-layout-version", "2\n"); wrongVersion.directory("projects"); wrongVersion.directory(".dsh")
        var missingHome = TarWriter()
        missingHome.file(".harness-layout-version", "1\n"); missingHome.directory("projects")
        var implicitProjects = TarWriter()
        implicitProjects.file(".harness-layout-version", "1\n"); implicitProjects.directory(".dsh"); implicitProjects.file("projects/a", "a")
        for tar in [missingVersion, wrongVersion, missingHome, implicitProjects] {
            try write(tar)
            assertFails(.layoutInvalid)
        }
    }

    func testCaseAndNormalisationConflictsAreReportedNotMerged() throws {
        var tar = TarWriter.base()
        tar.file("projects/Readme.md", "upper")
        tar.file("projects/README.md", "lower")
        tar.file("projects/caf\u{E9}.txt", "nfc")
        tar.file("projects/cafe\u{301}.txt", "nfd")
        tar.directory("projects/Src")
        tar.file("projects/src/a.txt", "implicit parent")
        try write(tar)
        XCTAssertThrowsError(try migrator().run()) { error in
            guard case .nameConflict(let pairs) = error as? MigrationError else { return XCTFail("\(error)") }
            XCTAssertEqual(pairs.count, 3)
            XCTAssertTrue(pairs.contains("projects/README.md <> projects/Readme.md"), "\(pairs)")
            XCTAssertTrue(pairs.contains("projects/Src <> projects/src"), "\(pairs)")
        }
        assertUntouched()
    }

    func testInsufficientSpaceBeforeWriting() throws {
        var tar = TarWriter.base()
        tar.file("projects/a.txt", "a")
        try write(tar)
        assertFails(.insufficientSpace) { $0.availableBytes = { _ in 1 << 20 } }
    }

    func testNoSpaceMidExtractionLeavesTargetUntouchedAndRetries() throws {
        var tar = TarWriter.base()
        for index in 0..<5 { tar.file("projects/f\(index).txt", "content \(index)") }
        try write(tar)
        for (stage, occurrence) in [(MigrationStage.extract, 1), (.extract, 4), (.verify, 1), (.marker, 1), (.switching, 1)] {
            var seen = 0
            assertFails(.insufficientSpace) { options in
                options.fault = { reached in
                    guard reached == stage else { return }
                    seen += 1
                    if seen == occurrence { throw MigrationError.io("write", ENOSPC) }
                }
            }
        }
        XCTAssertNotNil(report(try migrator().run()))
        XCTAssertEqual(text("projects/f4.txt"), "content 4")
    }

    func testArchiveReplacedBetweenPassesIsRefused() throws {
        var tar = TarWriter.base()
        tar.file("projects/a.txt", "original")
        try write(tar)
        var swapped = TarWriter.base()
        swapped.file("projects/a.txt", "replaced")
        let replacement = swapped.finish()
        let path = archive
        assertFails(.digestMismatch) { options in
            options.fault = { stage in if stage == .plan { try replacement.write(to: URL(fileURLWithPath: path)) } }
        }
    }

    // MARK: Idempotence and ownership of the target

    func testSecondRunIsNoOpAndKeepsLaterChanges() throws {
        var tar = TarWriter.base()
        tar.file("projects/a.txt", "from backup")
        try write(tar)
        XCTAssertNotNil(report(try migrator().run()))
        try "changed after migration".write(toFile: target + "/projects/a.txt", atomically: false, encoding: .utf8)
        guard case .alreadyMigrated = try migrator().run() else { return XCTFail("migrated twice") }
        XCTAssertEqual(text("projects/a.txt"), "changed after migration")

        var other = TarWriter.base()
        other.file("projects/b.txt", "another backup")
        try write(other)
        XCTAssertThrowsError(try migrator().run()) { XCTAssertEqual($0 as? MigrationError, .targetExists) }
        XCTAssertEqual(text("projects/a.txt"), "changed after migration")
    }

    func testExistingTargetIsNeverOverwritten() throws {
        try write(TarWriter.base())
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "user file".write(toFile: target + "/keep.txt", atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try migrator().run()) { XCTAssertEqual($0 as? MigrationError, .targetExists) }
        XCTAssertEqual(text("keep.txt"), "user file")
        try FileManager.default.removeItem(atPath: target + "/keep.txt")
        XCTAssertNotNil(report(try migrator().run()), "an empty target directory is replaced")
    }

    func testConcurrentMigrationIsBusy() throws {
        try write(TarWriter.base())
        let lock = open(root + "/data/" + UserDataMigrator.lockName, O_RDWR | O_CREAT, 0o600)
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        assertFails(.busy)
        flock(lock, LOCK_UN)
        XCTAssertNotNil(report(try migrator().run()))
    }

    func testStaleStageIsCleanedOnRetry() throws {
        try write(TarWriter.base())
        let stale = root + "/data/" + UserDataMigrator.stagePrefix + "stale"
        try FileManager.default.createDirectory(atPath: stale + "/projects/ro", withIntermediateDirectories: true)
        chmod(stale + "/projects/ro", 0o500)
        XCTAssertNotNil(report(try migrator().run()))
        assertNoStage()
    }

    func assertNoStage(file: StaticString = #filePath, line: UInt = #line) {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root + "/data"))?
            .filter { $0.hasPrefix(UserDataMigrator.stagePrefix) } ?? []
        XCTAssertEqual(leftovers, [], file: file, line: line)
    }
}
