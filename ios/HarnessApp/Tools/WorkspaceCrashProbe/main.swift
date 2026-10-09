import Darwin
import Foundation
import NativeWorkspace

// Runs one durable operation against a native workspace store and SIGKILLs itself at the named
// fault point, so the parent can reopen the store after a real process death.
//
//   workspace-crash-probe <workspace> <state> write <path> <text> [kill-point[#n]]
//   workspace-crash-probe <workspace> <state> draft <path> <text> [kill-point[#n]]
//   workspace-crash-probe <workspace> <state> checkpoint <text> [kill-point[#n]]
//   workspace-crash-probe <workspace> <state> compact [kill-point[#n]]
//   workspace-crash-probe <workspace> <state> lease <path> <text>   (killed while the lease is held)
//   workspace-crash-probe <workspace> <state> loop <seed>           (runs until the parent kills it)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2)
}

func say(_ line: String) { print(line); fflush(stdout) }

func killSelf(_ reason: String) -> Never {
    say("KILL " + reason)
    kill(getpid(), SIGKILL)
    while true { pause() }
}

/// "site.stage" or "site.stage#n" (the n-th time the point is reached).
func killHook(_ spec: String?) -> FaultHook? {
    guard let spec else { return nil }
    let parts = spec.split(separator: "#")
    guard let point = FaultPoint(name: String(parts[0])) else { fail("bad point \(spec)") }
    let occurrence = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
    var seen = 0
    return { reached in
        guard reached == point else { return }
        seen += 1
        if seen == occurrence { killSelf(spec) }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else { fail("usage: workspace-crash-probe <workspace> <state> <command> ...") }
let workspace = arguments[0], stateDirectory = arguments[1], command = arguments[2], rest = Array(arguments.dropFirst(3))
let store: WorkspaceStore
do { store = try WorkspaceStore(workspace: workspace, state: stateDirectory) } catch { fail("open: \(error)") }

func baseVersion(_ path: RelativePath) throws -> String? {
    if case .read(_, let version) = try store.nativeRead(path) { return version }
    return nil
}

do {
    switch command {
    case "write":
        let path = RelativePath(rest[0])
        let base = try baseVersion(path)
        store.fault = killHook(rest.count > 2 ? rest[2] : nil)
        say("RESULT \(try store.nativeWrite(path, Data(rest[1].utf8), base: base))")
    case "draft":
        let path = RelativePath(rest[0])
        let base = try baseVersion(path)
        if case .granted = try store.acquireLease("probe") {} else if store.lease == nil { fail("lease") }
        store.fault = killHook(rest.count > 2 ? rest[2] : nil)
        say("RESULT \(try store.nativeWrite(path, Data(rest[1].utf8), base: base))")
    case "checkpoint":
        store.fault = killHook(rest.count > 1 ? rest[1] : nil)
        say("RESULT \(try store.checkpointSession(Data(rest[0].utf8)))")
    case "compact":
        store.fault = killHook(rest.first)
        try store.compact()
        say("RESULT compacted")
    case "lease":
        let path = RelativePath(rest[0])
        let base = try baseVersion(path)
        guard case .granted(let lease) = try store.acquireLease("linux-writer") else { fail("lease busy") }
        say("LEASE \(lease.fence)")
        guard case .draftHeld(let draft) = try store.nativeWrite(path, Data(rest[1].utf8), base: base) else { fail("draft") }
        say("DRAFT \(draft)")
        // The Linux writer is mid-command when the app dies.
        try Data("linux partial output".utf8).write(to: URL(fileURLWithPath: workspace + "/linux-output.txt"))
        killSelf("lease")
    case "loop":
        var generator = SplitMix(seed: UInt64(rest.first ?? "1") ?? 1)
        store.compactionThreshold = 16
        let paths = ["notes.md", "src/app.js", "src/新文件.txt", "deep/a/b/c.txt"].map(RelativePath.init)
        var call = 0
        while true {
            let path = paths[Int(generator.next() % UInt64(paths.count))]
            let text = Data("loop \(generator.next())".utf8)
            switch generator.next() % 8 {
            case 0, 1, 2:
                _ = try store.nativeWrite(path, text, base: try baseVersion(path))
            case 3:
                _ = try store.checkpointSession(text)
            case 4:
                call += 1
                try store.toolStarted("call-\(call)")
                if generator.next() % 2 == 0 { try store.toolFinished("call-\(call)", outcome: "ok") }
            case 5:
                if store.lease == nil, case .granted = try store.acquireLease("loop") {}
                _ = try store.nativeWrite(path, text, base: store.version(path))
                let target = workspace + "/linux-\(generator.next() % 3).txt"
                try text.write(to: URL(fileURLWithPath: target))
            case 6:
                if let lease = store.lease { _ = try store.releaseLease(fence: lease.fence, reason: .guestTerminated) }
            default:
                try store.compact()
            }
        }
    default:
        fail("unknown command \(command)")
    }
} catch {
    say("ERROR \(error)")
    exit(1)
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
