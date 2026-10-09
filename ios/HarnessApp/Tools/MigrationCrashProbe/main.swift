import Darwin
import Foundation
import UserDataMigration

// Runs one migration and SIGKILLs itself at the named stage, so the parent can check the target and
// retry after a real process death.
//
//   migration-crash-probe <archive> <checksum> <target> [stage[#n]]
//   migration-crash-probe <archive> <checksum> <target> hold      (holds the lock until killed)
//   migration-crash-probe <archive> <checksum> <target> nospacecheck   (writes until the volume is full)

func say(_ line: String) { print(line); fflush(stdout) }

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else { FileHandle.standardError.write(Data("usage\n".utf8)); exit(2) }
var options = MigrationOptions()
options.codec = try? DynamicZstd()
if arguments.count > 3 {
    let spec = arguments[3]
    let parts = spec.split(separator: "#")
    if spec == "nospacecheck" {
        options.reserveBytes = 0
        options.availableBytes = { _ in .max }
    } else if spec == "hold" {
        options.fault = { stage in
            guard stage == .plan else { return }
            say("HOLD")
            while true { pause() }
        }
    } else {
        guard let stage = MigrationStage(rawValue: String(parts[0])) else { exit(2) }
        let occurrence = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        var seen = 0
        options.fault = { reached in
            guard reached == stage else { return }
            seen += 1
            guard seen == occurrence else { return }
            say("KILL " + spec)
            kill(getpid(), SIGKILL)
            while true { pause() }
        }
    }
}
do {
    switch try UserDataMigrator(archive: arguments[0], checksum: arguments[1], target: arguments[2], options: options).run() {
    case .migrated(let report): say("RESULT migrated \(report.files)")
    case .alreadyMigrated: say("RESULT already")
    }
} catch let error as MigrationError {
    say("ERROR " + error.code)
    exit(1)
}
