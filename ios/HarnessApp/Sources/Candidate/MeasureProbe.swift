import Darwin
import Foundation
#if os(iOS)
import os
#endif

/// The #17 measurements on the device, driven through the operations the Worker bridge sends, so a run
/// needs neither the model nor a key. A launch runs one phase, as the first thing the App opens:
/// - `cold`: from process start to the native host, Linux ready and the first command; warm commands;
///   whether a guest write is natively visible at once and a native write reaches the guest; the cost of
///   one watch comparison; memory and storage.
/// - `scheduling` (G4): concurrent commands and a cancel sent while Linux prepares, native operations
///   during it, and the number of VM boots. Concurrent commands are not queued, so after ready one runs
///   and the rest are refused with `LEASE_BUSY`.
/// - `lifecycle` (G6): a native-only project never boots Linux, a second plugin project does not bind,
///   and an unexpected VM exit fails Linux for the rest of the process with a saved diagnostic.
/// - `background`: one guest command every two seconds for `background` seconds, while the driver
///   sends the App to the background and back; gaps and failures show what suspension does.
///   `background-idle` pauses the commands during `quiet`, so nothing is in flight while the App is away;
///   the guest's uptime across the pause shows whether its clock ran while the App was suspended.
/// - `execution` (PR #56): a cancel that arrives first ends its ID for good, a running command is
///   cancelled and its lease ends, a terminal holds the lease only while a line runs and a command joins
///   it, a closed terminal ID is gone, and a VM exit during a command settles the lease this process sent.
/// - `execution-hold` leaves a command running in a new project for the driver to end the App;
///   `execution-stale` opens that project (`project`) in the next launch: the writer the earlier launch
///   left stays unknown across this launch's VM exit until it is released explicitly.
/// - `network` (#18): a guest command resolves names and reaches the Git and npm hosts over HTTPS.
///   Whether a guest command reaches a listener on the host's loopback (`10.0.2.2`) is recorded, not judged.
/// - `git-fetch` (#18): in the user's project (`project`, by name, created when absent), cloning into the workspace root, a
///   second project of the same name, a second `origin`, a fetch with prompts off and one cancelled at
///   its prompt all leave the project as it was. The probe then waits for the user's own `git fetch` of
///   `remote` in the App's terminal, where the token is typed, checks that nothing in the VM kept the token,
///   and installs, tests, type-checks and builds with real exit codes; a commit that fails the pre-commit hook leaves `HEAD` where it was.
/// - `git-push` (#18): a commit sent while Linux prepares waits for it and completes only after the
///   pre-commit hook passes; the probe then waits for the user's own `git push` in the App's terminal.
/// - `git-keep` (#18): after a reopen, an overwrite upgrade or a migration, the project (`project`, by
///   name) still holds its history and `origin` (`remote`), with a clean tree and no stored credential,
///   and no file the App keeps holds a GitHub token.
/// - `preview` (#23): a new project unpacks the Vite fixture the driver left at `<root>/probe/vite-hmr.tar`,
///   installs it in the terminal, starts its dev server as a service, opens the forwarded preview and
///   times five native edits to the HMR update over the preview's own WebSocket. Closing the preview
///   leaves the server running.
/// Each phase writes `<root>/probe/measure-<phase>.json` with numbers and fixed codes only, tagged with
/// the launch's `run` id and marked `done` once final.
public enum MeasureProbe {
    public enum Phase: String {
        case cold, scheduling, lifecycle, background, backgroundIdle = "background-idle"
        case execution, executionHold = "execution-hold", executionStale = "execution-stale"
        case network
        case gitFetch = "git-fetch", gitPush = "git-push", gitKeep = "git-keep"
        case preview
    }

    /// The #23 thresholds, in milliseconds. A miss is a failure; they are never relaxed to pass.
    public enum PreviewLimit {
        public static let linuxReady = 20_000, serverReady = 60_000, combined = 120_000
        public static let hmrMedian = 5_000, hmrEach = 15_000, hmrRuns = 5
    }

    /// Prefixes of GitHub tokens: a file the App keeps that holds one is a leak.
    public static let tokenPrefixes = ["github_pat_", "ghp_", "gho_"]

    /// A guest command the `network` phase runs, passing when it exits 0.
    public struct NetworkCheck {
        public var name: String
        public var command: String
        public init(_ name: String, _ command: String) { self.name = name; self.command = command }

        /// Name resolution, Git over HTTPS to a small public repository, and the npm registry.
        public static let defaults = [
            NetworkCheck("dns", "node -e \"require('node:dns').lookup('github.com', e => process.exit(e ? 1 : 0))\""),
            NetworkCheck("git", "git ls-remote https://github.com/octocat/Hello-World.git HEAD"),
            NetworkCheck("npm", "node -e \"fetch('https://registry.npmjs.org/-/ping').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(2))\""),
        ]
    }

    public struct Timing {
        public var ready: TimeInterval = 900
        public var poll: TimeInterval = 0.05
        public var background: TimeInterval = 300
        public var tick: TimeInterval = 2
        /// `background-idle` sends no command in this window (seconds after the first tick), so the App
        /// goes to the background with nothing in flight.
        public var quiet: ClosedRange<TimeInterval> = 20...170
        /// How long `execution-hold`'s command runs; the driver ends the App well before.
        public var hold: TimeInterval = 590
        /// How long the Git phases wait for the user's own fetch or push in the App's terminal.
        public var user: TimeInterval = 1800
        /// How long one line in the probe's terminal may run.
        public var line: TimeInterval = 3600
        public init() {}
    }

    @discardableResult
    public static func run(_ phase: Phase, host: CandidateHost, bundle: String? = nil, project: String? = nil,
                           remote: String? = nil, timing: Timing = .init(),
                           network: [NetworkCheck] = NetworkCheck.defaults) -> [String: Any] {
        let started = Date()
        var record: [String: Any] = ["phase": phase.rawValue, "run": runId]
        if let launched = processStart() { record["processToProbeMs"] = ms(started.timeIntervalSince(launched)) }
        do {
            switch phase {
            case .cold: try cold(host, bundle, timing, &record)
            case .scheduling: try scheduling(host, timing, &record)
            case .lifecycle: try lifecycle(host, timing, &record)
            case .background: try background(host, timing, idle: false, &record)
            case .backgroundIdle: try background(host, timing, idle: true, &record)
            case .execution: try execution(host, timing, &record)
            case .executionHold: try executionHold(host, timing, &record)
            case .executionStale: try executionStale(host, project, timing, &record)
            case .network: try networkReach(host, network, timing, &record)
            case .gitFetch: try gitFetch(host, project, remote, timing, &record)
            case .gitPush: try gitPush(host, project, timing, &record)
            case .gitKeep: try gitKeep(host, project, remote, timing, &record)
            case .preview: try preview(host, timing, &record)
            }
        } catch let error as CandidateError {
            record["failure"] = error.code
        } catch {
            record["failure"] = "PROBE_FAILED"
        }
        record["memory"] = memory()
        // Partial records written along the way lack this mark.
        record["done"] = true
        write(host, phase, record)
        return record
    }

    // MARK: Phases

    private static func cold(_ host: CandidateHost, _ bundle: String?, _ timing: Timing, _ record: inout [String: Any]) throws {
        record["memory.host"] = memory()
        let (id, mount) = try project(host, "measure-cold", plugin: true)
        let opened = Date()
        record["openMs"] = ms(time { _ = host.handle(["operation": "project-open", "id": id]) })
        try waitReady(host, id, timing, &record)
        record["linuxReadyMs"] = ms(Date().timeIntervalSince(opened))
        if let launched = processStart() { record["processToLinuxReadyMs"] = ms(Date().timeIntervalSince(launched)) }
        record["memory.ready"] = memory()

        var first: [String: Any] = [:]
        record["firstCommandMs"] = ms(time { first = execute(host, "cold-first", mount, "true") })
        record["firstCommand"] = first["status"] as? String ?? "NONE"
        record["warmCommandMs"] = (1...5).map { index in ms(time { _ = execute(host, "cold-warm-\(index)", mount, "true") }) }

        // Guest write, then the native read the watch comparison makes right after the command ends.
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let guestFile = "watch-guest-\(stamp).txt", nativeFile = "watch-native-\(stamp).txt"
        let wrote = execute(host, "cold-guest-write", mount, "echo \(stamp) > \(guestFile)")
        var seen: [String: Any] = [:]
        let readMs = ms(time { seen = host.handle(["operation": "path", "method": "readFile", "args": ["path": mount + "/" + guestFile]]) })
        record["watch.guestWrite"] = wrote["status"] as? String ?? "NONE"
        record["watch.guestToNativeVisible"] = decoded(seen["value"]) == stamp + "\n"
        record["watch.nativeReadMs"] = readMs
        // Native write, then the guest reads it with nothing cached (9P `none`).
        let data = Data((stamp + "\n").utf8).base64EncodedString()
        record["watch.nativeWriteMs"] = ms(time {
            _ = host.handle(["operation": "fs", "method": "write",
                             "args": ["path": mount + "/" + nativeFile, "data": data, "expected": ["kind": "createIfAbsent"]]])
        })
        var cat: [String: Any] = [:]
        record["watch.guestReadMs"] = ms(time { cat = execute(host, "cold-guest-read", mount, "cat \(nativeFile)") })
        record["watch.nativeToGuestVisible"] = cat["stdout"] as? String == stamp + "\n"
        // One watch comparison of the project root: what the bridge does every 2 s and after each command.
        record["watch.compareMs"] = ms(time {
            _ = host.handle(["operation": "path", "method": "stat", "args": ["path": mount]])
            _ = host.handle(["operation": "path", "method": "readdir", "args": ["path": mount]])
        })
        record["watch.pollIntervalMs"] = 2000
        record["bootCount"] = host.bootCount
        record["storage"] = storage(host.registry.root, bundle)
        record["passed"] = record["firstCommand"] as? String == "COMPLETED" && record["watch.guestToNativeVisible"] as? Bool == true
            && record["watch.nativeToGuestVisible"] as? Bool == true && host.bootCount == 1
    }

    private static func scheduling(_ host: CandidateHost, _ timing: Timing, _ record: inout [String: Any]) throws {
        let (id, mount) = try project(host, "measure-scheduling-\(stamp())", plugin: true)
        let opened = Date()
        _ = host.handle(["operation": "project-open", "id": id])
        record["phase.afterOpen"] = entry(host, id)?["phase"] as? String

        let lock = NSLock(), group = DispatchGroup()
        var results: [[String: Any]] = []
        for index in 1...3 {
            group.enter()
            Thread.detachNewThread {
                let reply = execute(host, "sched-\(index)", mount, "echo \(index) > sched-\(index).txt")
                let end = ms(Date().timeIntervalSince(opened))
                lock.lock(); results.append(["index": index, "status": describe(reply), "endMs": end]); lock.unlock()
                group.leave()
            }
        }
        group.enter()
        var cancelled: [String: Any] = [:]
        Thread.detachNewThread {
            let reply = execute(host, "sched-cancel", mount, "echo ran > sched-cancel.txt")
            lock.lock(); cancelled = reply; lock.unlock()
            group.leave()
        }
        Thread.sleep(forTimeInterval: 0.5)
        record["cancel"] = host.handle(["operation": "cancel", "operationId": "sched-cancel-" + runId])["status"] as? String

        // Native work while Linux prepares: none of it may wait for Linux.
        let data = Data("native\n".utf8).base64EncodedString()
        var native: [String: Int] = [:]
        native["write"] = ms(time {
            _ = host.handle(["operation": "fs", "method": "write",
                             "args": ["path": mount + "/native.txt", "data": data, "expected": ["kind": "createIfAbsent"]]])
        })
        native["read"] = ms(time { _ = host.handle(["operation": "path", "method": "readFile", "args": ["path": mount + "/native.txt"]]) })
        native["search"] = ms(time { _ = host.handle(["operation": "spawn", "args": ["tool": "rg", "argv": ["rg", "--files"], "cwd": mount]]) })
        record["native"] = native
        record["phase.afterNative"] = entry(host, id)?["phase"] as? String
        // The probe polls for ready a little after the gateway sees it, so a command's end is checked
        // against this last moment Linux was still preparing.
        let preparingSeen = ms(Date().timeIntervalSince(opened))
        record["preparingSeenMs"] = preparingSeen

        try waitReady(host, id, timing, &record)
        let ready = ms(Date().timeIntervalSince(opened))
        record["linuxReadyMs"] = ready
        _ = group.wait(timeout: .now() + 120)
        lock.lock(); let finished = results.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }; let cancel = cancelled; lock.unlock()
        record["commands"] = finished
        record["cancelled"] = cancel["status"] as? String ?? "NONE"
        let project = try registered(host, id)
        let workspace = host.registry.workspace(project)
        record["cancelledRan"] = FileManager.default.fileExists(atPath: workspace + "/sched-cancel.txt")
        record["commandFiles"] = (1...3).filter { FileManager.default.fileExists(atPath: workspace + "/sched-\($0).txt") }.count
        record["bootCount"] = host.bootCount
        let preparing = record["phase.afterOpen"] as? String == "PREPARING" && record["phase.afterNative"] as? String == "PREPARING"
        // Commands in one project are not queued: once Linux is ready one takes the write lease and the
        // others are refused at once with LEASE_BUSY. None may end while Linux prepares, and only a
        // COMPLETED one may have run.
        let completed = finished.filter { $0["status"] as? String == "COMPLETED" }.count
        record["concurrent.completed"] = completed
        record["concurrent.leaseBusy"] = finished.filter { $0["status"] as? String == "REFUSED:LEASE_BUSY" }.count
        record["passed"] = finished.count == 3 && completed >= 1
            && finished.allSatisfy { ["COMPLETED", "REFUSED:LEASE_BUSY"].contains($0["status"] as? String ?? "") && ($0["endMs"] as? Int ?? 0) >= preparingSeen }
            && record["commandFiles"] as? Int == completed && record["cancelled"] as? String == "CANCELLED_BEFORE_DISPATCH"
            && record["cancelledRan"] as? Bool == false && host.bootCount == 1 && preparing
            && native.values.allSatisfy { $0 < 2000 }
    }

    private static func lifecycle(_ host: CandidateHost, _ timing: Timing, _ record: inout [String: Any]) throws {
        let suffix = stamp()
        let (native, nativeMount) = try project(host, "measure-native-\(suffix)", plugin: false)
        record["native.phase"] = (host.handle(["operation": "project-open", "id": native])["project"] as? [String: Any])?["phase"] as? String
        record["native.command"] = describe(execute(host, "life-native", nativeMount, "true"))
        record["native.boots"] = host.bootCount

        let (first, firstMount) = try project(host, "measure-life-\(suffix)", plugin: true)
        _ = host.handle(["operation": "project-open", "id": first])
        try waitReady(host, first, timing, &record)
        record["first.command"] = describe(execute(host, "life-first", firstMount, "true"))

        let (second, secondMount) = try project(host, "measure-second-\(suffix)", plugin: true)
        _ = host.handle(["operation": "project-open", "id": second])
        record["second.phase"] = entry(host, second)?["phase"] as? String
        record["second.reason"] = entry(host, second)?["reason"] as? String
        record["second.command"] = describe(execute(host, "life-second", secondMount, "true"))
        record["boots.beforeExit"] = host.bootCount

        host.stopVMUnexpectedly()
        _ = wait(60, timing.poll) { entry(host, first)?["phase"] as? String == "FAILED" }
        record["exit.phase"] = entry(host, first)?["phase"] as? String
        record["exit.reason"] = entry(host, first)?["reason"] as? String
        let diagnostic = host.handle(["operation": "status"])["diagnostic"] as? [String: Any]
        record["exit.diagnostic"] = diagnostic?["code"] as? String
        record["exit.diagnosticSaved"] = FileManager.default.fileExists(atPath: host.registry.root + "/" + CandidateHost.diagnosticRecord)
        record["exit.command"] = describe(execute(host, "life-after-exit", firstMount, "true"))
        record["exit.nativeWrite"] = nativeWrite(host, firstMount + "/after-exit.txt")
        record["boots.afterExit"] = host.bootCount
        record["passed"] = record["native.phase"] as? String == "DISABLED" && record["native.boots"] as? Int == 0
            && (record["native.command"] as? String ?? "").hasPrefix("REFUSED")
            && record["first.command"] as? String == "COMPLETED" && record["second.phase"] as? String != "READY"
            && (record["second.command"] as? String ?? "").hasPrefix("REFUSED") && record["boots.beforeExit"] as? Int == 1
            && record["exit.phase"] as? String == "FAILED" && record["exit.diagnosticSaved"] as? Bool == true
            && (record["exit.command"] as? String ?? "").hasPrefix("REFUSED") && record["exit.nativeWrite"] as? String == "create"
            && host.bootCount == 1
    }

    private static func background(_ host: CandidateHost, _ timing: Timing, idle: Bool, _ record: inout [String: Any]) throws {
        // Each run takes its own project: a run interrupted mid-command leaves its writer unknown.
        let (id, mount) = try project(host, "measure-\(idle ? "background-idle" : "background")-\(stamp())", plugin: true)
        let opened = Date()
        _ = host.handle(["operation": "project-open", "id": id])
        try waitReady(host, id, timing, &record)
        record["linuxReadyMs"] = ms(Date().timeIntervalSince(opened))
        let start = Date()
        var ticks: [[String: Any]] = []
        var index = 0
        while Date().timeIntervalSince(start) < timing.background {
            if idle, timing.quiet.contains(Date().timeIntervalSince(start)) {
                Thread.sleep(forTimeInterval: min(timing.tick, timing.quiet.upperBound - Date().timeIntervalSince(start) + 0.001))
                continue
            }
            index += 1
            let at = Date()
            var reply: [String: Any] = [:]
            let took = ms(time { reply = execute(host, "bg-\(index)", mount, "cut -d' ' -f1 /proc/uptime", timeoutMs: 60_000) })
            ticks.append(["atMs": ms(at.timeIntervalSince(start)), "ms": took, "status": describe(reply),
                          "guestUptime": Double((reply["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1,
                          "phase": entry(host, id)?["phase"] as? String ?? "NONE"])
            // Written every tick, so a killed or suspended App still leaves what it saw.
            var partial = record; partial["ticks"] = ticks; partial["memory"] = memory()
            write(host, idle ? .backgroundIdle : .background, partial)
            Thread.sleep(forTimeInterval: max(0, timing.tick - Date().timeIntervalSince(at)))
        }
        record["ticks"] = ticks
        let gaps = zip(ticks, ticks.dropFirst()).map { (($1["atMs"] as? Int ?? 0) - ($0["atMs"] as? Int ?? 0)) }
        record["maxGapMs"] = gaps.max() ?? 0
        record["failedTicks"] = ticks.filter { $0["status"] as? String != "COMPLETED" }.count
        record["bootCount"] = host.bootCount
        record["passed"] = record["failedTicks"] as? Int == 0 && host.bootCount == 1
    }

    private static func execution(_ host: CandidateHost, _ timing: Timing, _ record: inout [String: Any]) throws {
        let (id, mount) = try project(host, "measure-execution-\(stamp())", plugin: true)
        _ = host.handle(["operation": "project-open", "id": id])
        try waitReady(host, id, timing, &record)
        let workspace = host.registry.workspace(try registered(host, id))
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: workspace + "/" + name) }

        // A cancel that arrives first ends its ID for good: neither the command nor a resubmit runs.
        record["early.cancel"] = cancel(host, "exec-early")
        record["early.first"] = describe(execute(host, "exec-early", mount, "echo ran > early.txt"))
        record["early.again"] = describe(execute(host, "exec-early", mount, "echo ran > early.txt"))
        record["early.lateCancel"] = cancel(host, "exec-early")
        record["early.ran"] = exists("early.txt")

        // Cancelling a running command stops it, and its lease ends with it. A finished ID never runs again.
        let running = onThread { execute(host, "exec-running", mount, "sleep 20; echo ran > running.txt") }
        Thread.sleep(forTimeInterval: 1.5)
        record["running.cancel"] = cancel(host, "exec-running")
        let stopped = running()
        record["running.status"] = describe(stopped)
        record["running.cancelled"] = stopped["cancelled"] as? Bool ?? false
        record["running.ran"] = exists("running.txt")
        record["running.writerUnknown"] = entry(host, id)?["writerUnknown"] as? Bool
        record["running.next"] = describe(execute(host, "exec-next", mount, "true"))
        record["repeat"] = describe(execute(host, "exec-next", mount, "echo ran > repeat.txt"))
        record["repeat.ran"] = exists("repeat.txt")

        // An idle terminal is read-only. A line run in it takes the lease until the prompt is idle again,
        // and a command sent meanwhile joins that lease instead of being refused.
        let terminal = "exec-term-" + runId
        var offset = 0
        record["terminal.open"] = terminalOpen(host, terminal, mount)
        record["terminal.prompt"] = terminalUntil(host, terminal, &offset, timing) { ($0["activity"] as? [String: Any])?["state"] as? String == "idle" }
        record["terminal.write"] = terminalWrite(host, terminal, "echo hi > term.txt\n")
        record["terminal.released"] = terminalUntil(host, terminal, &offset, timing) { $0["released"] as? Bool == true }
        record["terminal.file"] = (try? String(contentsOfFile: workspace + "/term.txt", encoding: .utf8)) == "hi\n"
        record["terminal.after"] = describe(execute(host, "exec-after-terminal", mount, "true"))

        record["join.write"] = terminalWrite(host, terminal, "sleep 4; echo t > join-terminal.txt\n")
        Thread.sleep(forTimeInterval: 0.5)
        record["join.command"] = describe(execute(host, "exec-join", mount, "echo c > join-command.txt"))
        record["join.stillLeased"] = terminalRead(host, terminal, &offset, waitMs: 0)["leased"] as? Bool ?? false
        record["join.released"] = terminalUntil(host, terminal, &offset, timing) { $0["released"] as? Bool == true }
        record["join.files"] = ["join-terminal.txt", "join-command.txt"].filter(exists).count
        record["join.after"] = describe(execute(host, "exec-after-join", mount, "true"))

        // A closed terminal's ID is gone; the same ID then opens a new terminal.
        let closed = host.handle(["operation": "terminal-close", "terminalId": terminal])
        record["close"] = closed["closed"] as? Bool == true ? "CLOSED" : describe(closed)
        record["close.lateWrite"] = terminalWrite(host, terminal, "true\n")
        record["close.reopen"] = terminalOpen(host, terminal, mount)

        // A VM exit during a command settles the lease this process sent: native writes commit at once,
        // while the command's own result stays unknown. Open terminals end with the VM.
        let lost = onThread { execute(host, "exec-exit", mount, "sleep 60; echo ran > exit.txt") }
        Thread.sleep(forTimeInterval: 1.5)
        host.stopVMUnexpectedly()
        record["exit.command"] = describe(lost())
        _ = wait(60, timing.poll) { entry(host, id)?["phase"] as? String == "FAILED" }
        record["exit.phase"] = entry(host, id)?["phase"] as? String
        record["exit.writerUnknown"] = entry(host, id)?["writerUnknown"] as? Bool
        record["exit.terminal"] = terminalWrite(host, terminal, "true\n")
        record["exit.nativeWrite"] = nativeWrite(host, mount + "/after-exit.txt")
        record["bootCount"] = host.bootCount

        let expected: [String: String] = [
            "early.cancel": "CANCELLED_BEFORE_DISPATCH", "early.first": "CANCELLED_BEFORE_DISPATCH",
            "early.again": "REFUSED:DUPLICATE_OPERATION", "early.lateCancel": "FINISHED",
            "running.cancel": "CANCEL_REQUESTED", "running.status": "COMPLETED", "running.next": "COMPLETED",
            "repeat": "REFUSED:DUPLICATE_OPERATION",
            "terminal.open": "OPEN", "terminal.write": "WRITTEN:LEASED", "terminal.after": "COMPLETED",
            "join.write": "WRITTEN:LEASED", "join.command": "COMPLETED", "join.after": "COMPLETED",
            "close": "CLOSED", "close.lateWrite": "TERMINAL_NOT_FOUND", "close.reopen": "OPEN",
            "exit.phase": "FAILED", "exit.terminal": "TERMINAL_NOT_FOUND", "exit.nativeWrite": "create"]
        let flags: [String: Bool] = [
            "early.ran": false, "running.cancelled": true, "running.ran": false, "running.writerUnknown": false, "repeat.ran": false,
            "terminal.prompt": true, "terminal.released": true, "terminal.file": true,
            "join.stillLeased": true, "join.released": true, "exit.writerUnknown": false]
        let missed = misses(record, expected, flags)
        record["missed"] = missed
        record["passed"] = missed.isEmpty && record["join.files"] as? Int == 2 && host.bootCount == 1
    }

    private static func executionHold(_ host: CandidateHost, _ timing: Timing, _ record: inout [String: Any]) throws {
        let name = "measure-exec-stale-\(stamp())"
        let (id, mount) = try project(host, name, plugin: true)
        _ = host.handle(["operation": "project-open", "id": id])
        try waitReady(host, id, timing, &record)
        record["project"] = name
        _ = onThread { execute(host, "exec-hold", mount, "sleep \(Int(timing.hold))", timeoutMs: maxTimeoutMs) }
        Thread.sleep(forTimeInterval: 2)
        // The running command holds the lease, so another one is refused.
        record["hold.other"] = describe(execute(host, "exec-hold-other", mount, "true"))
        record["passed"] = record["hold.other"] as? String == "REFUSED:LEASE_BUSY" && host.bootCount == 1
    }

    private static func executionStale(_ host: CandidateHost, _ name: String?, _ timing: Timing, _ record: inout [String: Any]) throws {
        let project = try named(host, name, timing)
        _ = host.handle(["operation": "project-open", "id": project.id])
        try waitReady(host, project.id, timing, &record)
        record["stale.writerUnknown"] = entry(host, project.id)?["writerUnknown"] as? Bool
        record["stale.command"] = describe(execute(host, "exec-stale", project.mount, "true"))
        host.stopVMUnexpectedly()
        _ = wait(60, timing.poll) { entry(host, project.id)?["phase"] as? String == "FAILED" }
        record["exit.phase"] = entry(host, project.id)?["phase"] as? String
        record["exit.writerUnknown"] = entry(host, project.id)?["writerUnknown"] as? Bool
        record["release"] = host.handle(["operation": "writer-release", "id": project.id])["status"] as? String ?? "NONE"
        record["after.writerUnknown"] = entry(host, project.id)?["writerUnknown"] as? Bool
        record["after.nativeWrite"] = nativeWrite(host, project.mount + "/after-release.txt")
        record["bootCount"] = host.bootCount
        let missed = misses(record, ["stale.command": "REFUSED:WRITER_UNKNOWN", "exit.phase": "FAILED", "release": "RELEASED",
                                     "after.nativeWrite": "create"],
                            ["stale.writerUnknown": true, "exit.writerUnknown": true, "after.writerUnknown": false])
        record["missed"] = missed
        record["passed"] = missed.isEmpty && host.bootCount == 1
    }

    private static func networkReach(_ host: CandidateHost, _ checks: [NetworkCheck], _ timing: Timing, _ record: inout [String: Any]) throws {
        let (id, mount) = try project(host, "measure-network", plugin: true)
        _ = host.handle(["operation": "project-open", "id": id])
        try waitReady(host, id, timing, &record)
        for check in checks {
            var reply: [String: Any] = [:]
            record["\(check.name).ms"] = ms(time { reply = execute(host, "net-\(check.name)", mount, check.command) })
            record["\(check.name).status"] = describe(reply)
            record["\(check.name).exitCode"] = reply["exitCode"] as? Int ?? -1
        }
        // The guest reaches the host's loopback as 10.0.2.2. Observed only: QEMU has no switch to close it.
        if let listener = try? Listener() {
            defer { listener.close() }
            let reply = execute(host, "net-host-loopback", mount, "timeout 5 bash -c 'exec 3<>/dev/tcp/10.0.2.2/\(listener.port)'")
            record["hostLoopback.exitCode"] = reply["exitCode"] as? Int ?? -1
            record["hostLoopback.accepted"] = listener.accepted()
        }
        record["bootCount"] = host.bootCount
        record["passed"] = checks.allSatisfy { record["\($0.name).exitCode"] as? Int == 0 } && host.bootCount == 1
    }

    private static func gitFetch(_ host: CandidateHost, _ name: String?, _ remote: String?, _ timing: Timing,
                                 _ record: inout [String: Any]) throws {
        guard let remote, !remote.contains("'") else { throw CandidateError("REMOTE_MISSING") }
        guard let name else { throw CandidateError("PROJECT_UNKNOWN") }
        let known = host.registry.projects.contains { $0.name == name }
        let project = try registered(host, try self.project(host, name, plugin: true).0)
        record["created"] = !known
        let workspace = host.registry.workspace(project)
        func fetched() -> String? { ref(workspace, "refs/remotes/origin/main") }
        // A second project of the same name is refused and leaves this one's workspace alone.
        var listed = listing(workspace)
        record["duplicate.project"] = describe(host.handle(["operation": "project-create", "name": project.name, "pluginEnabled": true]))
        record["duplicate.unchanged"] = listing(workspace) == listed
        let opened = Date()
        _ = host.handle(["operation": "project-open", "id": project.id])
        try waitReady(host, project.id, timing, &record)
        record["linuxReadyMs"] = ms(Date().timeIntervalSince(opened))
        let shell = try Shell(host, "acc-probe-" + runId, project.mount, timing)
        defer { shell.close() }
        var expected: [String: Int] = [:]
        var flags: [String: Bool] = [:]
        var reasons: [String: String] = [:]
        record["resumed"] = fetched() != nil
        if fetched() == nil {
            // The reserved files at the root make `clone` into it fail, so the steps below replace it.
            listed = listing(workspace)
            record["clone.exitCode"] = shell.run("git clone -q '\(remote)' .") ?? -1
            record["clone.reason"] = Shell.reason(shell.last)
            record["clone.unchanged"] = listing(workspace) == listed
            if !FileManager.default.fileExists(atPath: workspace + "/.git") {
                // No exclude entries: the guest's system git config ignores the reserved root files.
                record["setup.exitCode"] = shell.run("git init -q -b main"
                    + " && git remote add origin '\(remote)' && git config user.name 'Harness Acceptance'"
                    + " && git config user.email acceptance@invalid && git config core.hooksPath .githooks") ?? -1
                expected["setup.exitCode"] = 0
            }
            record["duplicateRemote.exitCode"] = shell.run("git remote add origin https://invalid.invalid/other.git") ?? -1
            record["remote.same"] = shell.run("test \"$(git remote get-url origin)\" = '\(remote)'") == 0
            record["failure.exitCode"] = shell.run("GIT_TERMINAL_PROMPT=0 git fetch -q origin") ?? -1
            record["failure.reason"] = Shell.reason(shell.last)
            record["failure.noRefs"] = fetched() == nil
            // Ctrl-C at the credential prompt ends the fetch with SIGINT. A fetch that ends before
            // prompting, as on a network error, is recorded with its reason instead.
            let (prompted, ended) = shell.prompt("git fetch origin", "Username for", timing.line)
            record["cancel.prompted"] = prompted
            record["cancel.reason"] = Shell.reason(shell.last)
            record["cancel.exitCode"] = (prompted ? shell.interrupt() : ended) ?? -1
            record["cancel.noRefs"] = fetched() == nil
            expected.merge(["clone.exitCode": 128, "duplicateRemote.exitCode": 3, "failure.exitCode": 128, "cancel.exitCode": 130]) { $1 }
            reasons = ["clone.reason": "NOT_EMPTY", "failure.reason": "PROMPTS_DISABLED", "cancel.reason": "PROMPTED"]
            flags = ["duplicate.unchanged": true, "clone.unchanged": true, "remote.same": true, "failure.noRefs": true,
                     "cancel.prompted": true, "cancel.noRefs": true]

            record["state"] = "waiting-fetch"
            write(host, .gitFetch, record)
            let waited = Date()
            record["fetch.seen"] = wait(timing.user, 1) { fetched() != nil }
            record["fetch.waitMs"] = ms(Date().timeIntervalSince(waited))
            record.removeValue(forKey: "state")
            guard fetched() != nil else { throw CandidateError("FETCH_NOT_SEEN") }
            // The fetch authenticated with a token typed in this VM; nothing in the VM may have kept it.
            record["credential.helper"] = shell.run(storedHelper).map { $0 == 0 } ?? "NO_EXIT_CODE"
            record["credential.file"] = shell.run(storedFile).map { $0 == 0 } ?? "NO_EXIT_CODE"
            flags.merge(["credential.helper": false, "credential.file": false]) { $1 }
        }

        record["checkout.exitCode"] = shell.run("git checkout -q main") ?? -1
        record["head"] = head(workspace)
        record["head.fetched"] = head(workspace) == fetched()
        for (step, command) in [("install", "npm ci --no-audit --no-fund"), ("test", "npm test"), ("typecheck", "npm run typecheck"),
                                ("build", "npm run build"), ("precommit", ".githooks/pre-commit")] {
            var code: Int?
            record["\(step).ms"] = ms(time { code = shell.run(command) })
            record["\(step).exitCode"] = code ?? -1
            expected["\(step).exitCode"] = 0
        }
        record["build.output"] = ["dist/index.js", "dist/index.d.ts"].allSatisfy { FileManager.default.fileExists(atPath: workspace + "/" + $0) }
        // A commit that breaks the typecheck, in a scratch clone, is refused by the hook.
        let scratch = "/tmp/acc-hook-" + runId
        record["hookBlock.exitCode"] = shell.run("(git clone -q /workspace \(scratch) && cd \(scratch) && ln -s /workspace/node_modules node_modules"
            + " && git config user.name probe && git config user.email probe@invalid && git config core.hooksPath .githooks"
            + " && printf 'export const broken: number = \"x\";\\n' >> src/index.ts && git commit -qam broken) >/dev/null 2>&1") ?? -1
        record["hookBlock.headUnchanged"] = shell.run("test \"$(git -C \(scratch) rev-parse HEAD)\" = \"$(git rev-parse HEAD)\"") == 0
        _ = shell.run("rm -rf \(scratch)")
        record["bootCount"] = host.bootCount
        record["shell.reopened"] = shell.reopened

        expected["checkout.exitCode"] = 0
        flags.merge(["head.fetched": true, "build.output": true, "hookBlock.headUnchanged": true]) { $1 }
        var missed = expected.filter { record[$0.key] as? Int != $0.value }.map(\.key)
            + flags.filter { record[$0.key] as? Bool != $0.value }.map(\.key)
            + reasons.filter { record[$0.key] as? String != $0.value }.map(\.key)
        if [0, -1].contains(record["hookBlock.exitCode"] as? Int) { missed.append("hookBlock.exitCode") }
        if record["duplicate.project"] as? String != "PROJECT_NAME_TAKEN" { missed.append("duplicate.project") }
        missed.sort()
        record["missed"] = missed
        record["passed"] = missed.isEmpty && host.bootCount == 1
    }

    private static func gitPush(_ host: CandidateHost, _ name: String?, _ timing: Timing, _ record: inout [String: Any]) throws {
        let project = try named(host, name, timing)
        let workspace = host.registry.workspace(project)
        guard let before = head(workspace) else { throw CandidateError("HEAD_MISSING") }
        let opened = Date()
        _ = host.handle(["operation": "project-open", "id": project.id])
        // The commit goes in while Linux prepares: opening its terminal waits, and the hook runs once
        // Linux is ready. A terminal, because the hook outlasts the shell tool's 60 s limit on the iPad.
        record["commit.phaseAtSubmit"] = entry(host, project.id)?["phase"] as? String
        let commit = onThread(limit: timing.ready + timing.line) { () -> [String: Any] in
            guard let shell = try? Shell(host, "acc-commit-" + String(UUID().uuidString.prefix(8)), project.mount, timing) else {
                return ["status": "TERMINAL_REFUSED"]
            }
            defer { shell.close() }
            let code = shell.run("(git add -A && if git diff --cached --quiet; then exit 90; fi"
                                 + " && git commit -q -m 'Apply the reviewed model edit (#18)')")
            return ["status": code == nil ? "NO_EXIT_CODE" : "COMPLETED", "exitCode": code ?? -1]
        }
        try waitReady(host, project.id, timing, &record)
        record["linuxReadyMs"] = ms(Date().timeIntervalSince(opened))
        let reply = commit()
        record["commit.ms"] = ms(Date().timeIntervalSince(opened))
        record["commit.status"] = reply["status"] as? String ?? describe(reply)
        record["commit.exitCode"] = reply["exitCode"] as? Int ?? -1
        let after = head(workspace)
        record["head"] = after
        record["head.moved"] = after != nil && after != before
        record["head.parent"] = (execute(host, "git-parent", project.mount, "test \"$(git rev-parse HEAD~1)\" = \(before)")["exitCode"] as? Int) == 0
        record["clean"] = (execute(host, "git-clean", project.mount, "test -z \"$(git status --porcelain)\"")["exitCode"] as? Int) == 0

        // Only a new commit is waited for: the remote already holds the one before it.
        if record["head.moved"] as? Bool == true {
            record["state"] = "waiting-push"
            write(host, .gitPush, record)
            let waited = Date()
            record["push.seen"] = wait(timing.user, 1) { ref(workspace, "refs/remotes/origin/main") == after }
            record["push.waitMs"] = ms(Date().timeIntervalSince(waited))
            record.removeValue(forKey: "state")
        }
        record["bootCount"] = host.bootCount
        let missed = (misses(record, ["commit.phaseAtSubmit": "PREPARING", "commit.status": "COMPLETED"],
                             ["head.moved": true, "head.parent": true, "clean": true, "push.seen": true])
            + (record["commit.exitCode"] as? Int == 0 ? [] : ["commit.exitCode"])).sorted()
        record["missed"] = missed
        record["passed"] = missed.isEmpty && host.bootCount == 1
    }

    private static func preview(_ host: CandidateHost, _ timing: Timing, _ record: inout [String: Any]) throws {
        guard let fixture = FileManager.default.contents(atPath: host.registry.root + "/probe/vite-hmr.tar") else {
            throw CandidateError("FIXTURE_MISSING")
        }
        let (id, mount) = try project(host, "measure-preview-\(stamp())", plugin: true)
        let opened = Date()
        _ = host.handle(["operation": "project-open", "id": id])
        try waitReady(host, id, timing, &record)
        record["linuxReadyMs"] = ms(Date().timeIntervalSince(opened))

        // The fixture goes in as a native write and is unpacked and installed in the terminal, like a
        // user would; the install is timed on its own and is not part of the thresholds.
        let written = host.handle(["operation": "fs", "method": "write",
                                   "args": ["path": mount + "/vite-hmr.tar", "data": fixture.base64EncodedString()]])
        guard (written["value"] as? [String: Any])?["operation"] != nil else { throw CandidateError("FIXTURE_REFUSED") }
        let shell = try Shell(host, "acc-preview-" + runId, mount, timing)
        defer { shell.close() }
        record["unpack.exitCode"] = shell.run("tar -xf vite-hmr.tar && rm vite-hmr.tar") ?? -1
        var install: Int?
        record["installMs"] = ms(time { install = shell.run("npm ci --no-audit --no-fund") })
        record["install.exitCode"] = install ?? -1
        write(host, .preview, record)
        guard install == 0 else { throw CandidateError("INSTALL_FAILED") }

        // The dev server runs unleased and read-only, so the native edits below commit at once.
        let service = "vite-" + runId
        let started = Date()
        let start = host.handle(["operation": "service-start", "serviceId": service, "cwd": mount,
                                 "command": "exec node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5173 --strictPort --configLoader native"])
        record["service.start"] = start["pid"] != nil ? "STARTED" : describe(start)
        defer { _ = host.handle(["operation": "service-stop", "serviceId": service]) }
        func listed() -> Bool {
            ((host.handle(["operation": "preview-ports"])["ports"] as? [[String: Any]]) ?? []).contains { $0["port"] as? Int == 5173 }
        }
        record["service.listening"] = wait(Double(PreviewLimit.combined) / 1000, 0.25, listed)
        record["service.listenMs"] = ms(Date().timeIntervalSince(started))
        let open = host.handle(["operation": "preview-open", "port": 5173])
        guard let url = (open["url"] as? String).flatMap(URL.init(string:)) else {
            record["service.exited"] = (host.handle(["operation": "service-read", "serviceId": service])["exited"] as? [String: Any]) != nil
            throw CandidateError("PREVIEW_" + describe(open))
        }
        var page: String?
        record["server.ok"] = wait(Double(PreviewLimit.combined) / 1000, 0.25) {
            page = get(url); return page?.contains("id=\"message\"") == true
        }
        let serverReady = ms(Date().timeIntervalSince(started))
        record["serverReadyMs"] = serverReady
        write(host, .preview, record)

        // Vite's client gives the token its WebSocket needs; loading the modules puts them in its graph.
        guard let client = get(url.appendingPathComponent("@vite/client")),
              let range = client.range(of: "wsToken = \"[^\"]+\"", options: .regularExpression) else { throw CandidateError("HMR_TOKEN_MISSING") }
        let token = client[range].dropFirst("wsToken = \"".count).dropLast()
        for module in ["src/main.js", "src/message.js"] { _ = get(url.appendingPathComponent(module)) }
        var socketURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        socketURL.scheme = "ws"; socketURL.queryItems = [URLQueryItem(name: "token", value: String(token))]
        let socket = URLSession.shared.webSocketTask(with: socketURL.url!, protocols: ["vite-hmr"])
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        record["hmr.connected"] = receive(socket, 15)?.contains("\"connected\"") == true

        var runs: [Int] = [], kinds: [String] = [], served = 0
        for run in 1...PreviewLimit.hmrRuns {
            Thread.sleep(forTimeInterval: 1)
            let text = "export const message = 'edit \(run)';\n"
            let edited = Date()
            _ = host.handle(["operation": "fs", "method": "write",
                             "args": ["path": mount + "/src/message.js", "data": Data(text.utf8).base64EncodedString()]])
            var kind = "TIMEOUT"
            let deadline = edited.addingTimeInterval(Double(PreviewLimit.hmrEach) / 1000)
            while Date() < deadline, let message = receive(socket, deadline.timeIntervalSinceNow) {
                if message.contains("\"type\":\"update\"") { kind = "update"; break }
                if message.contains("\"type\":\"full-reload\"") { kind = "full-reload"; break }
            }
            runs.append(kind == "TIMEOUT" ? -1 : ms(Date().timeIntervalSince(edited)))
            kinds.append(kind)
            if get(url.appendingPathComponent("src/message.js"))?.contains("edit \(run)") == true { served += 1 }
        }
        record["hmr.ms"] = runs
        record["hmr.kinds"] = kinds
        record["hmr.served"] = served
        let timed = runs.filter { $0 >= 0 }.sorted()
        let median = timed.count == runs.count ? timed[timed.count / 2] : -1
        record["hmr.medianMs"] = median
        record["hmr.maxMs"] = timed.count == runs.count ? timed.last ?? -1 : -1

        // Closing the preview clears only the forward; the server keeps running.
        _ = host.handle(["operation": "preview-close"])
        let after = host.handle(["operation": "service-read", "serviceId": service])
        record["close.serviceRunning"] = after["exited"] is NSNull || (after["exited"] == nil && after["error"] == nil)
        record["bootCount"] = host.bootCount

        let linux = record["linuxReadyMs"] as? Int ?? .max
        var missed = misses(record, ["service.start": "STARTED"],
                            ["service.listening": true, "server.ok": true, "hmr.connected": true, "close.serviceRunning": true])
        if record["unpack.exitCode"] as? Int != 0 { missed.append("unpack.exitCode") }
        if linux > PreviewLimit.linuxReady { missed.append("linuxReadyMs") }
        if serverReady > PreviewLimit.serverReady { missed.append("serverReadyMs") }
        if linux + serverReady > PreviewLimit.combined { missed.append("combinedMs") }
        if median < 0 || median > PreviewLimit.hmrMedian { missed.append("hmr.medianMs") }
        if runs.contains(where: { $0 < 0 || $0 > PreviewLimit.hmrEach }) { missed.append("hmr.each") }
        if kinds.contains(where: { $0 != "update" }) { missed.append("hmr.kinds") }
        if served != runs.count { missed.append("hmr.served") }
        record["combinedMs"] = linux + serverReady
        record["missed"] = missed.sorted()
        record["passed"] = missed.isEmpty && host.bootCount == 1
    }

    /// The body of a 200 reply from the preview, or nil.
    private static func get(_ url: URL) -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("text/html,*/*", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var body: String?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return body
    }

    /// The next text message on `socket`, or nil when none comes within `limit` seconds.
    private static func receive(_ socket: URLSessionWebSocketTask, _ limit: TimeInterval) -> String? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var text: String?
        socket.receive { result in
            if case .success(.string(let value)) = result { text = value }
            done.signal()
        }
        return done.wait(timeout: .now() + max(limit, 0)) == .success ? text : nil
    }

    /// Exit 0 when guest git would keep a typed credential: a helper is configured, or a credential file exists.
    static let storedHelper = "git config --get-all credential.helper >/dev/null"
    static let storedFile = "test -e ~/.git-credentials || test -e .git-credentials || test -e ~/.config/git/credentials"

    private static func gitKeep(_ host: CandidateHost, _ name: String?, _ remote: String?, _ timing: Timing,
                                _ record: inout [String: Any]) throws {
        let project = try named(host, name, timing)
        let workspace = host.registry.workspace(project)
        record["pluginEnabled"] = project.pluginEnabled
        record["head"] = head(workspace)
        record["origin.main"] = ref(workspace, "refs/remotes/origin/main")
        let opened = Date()
        _ = host.handle(["operation": "project-open", "id": project.id])
        try waitReady(host, project.id, timing, &record)
        record["linuxReadyMs"] = ms(Date().timeIntervalSince(opened))
        func check(_ id: String, _ command: String) -> Int {
            execute(host, "keep-" + id, project.mount, command)["exitCode"] as? Int ?? -1
        }
        record["fsck.exitCode"] = check("fsck", "git fsck --no-progress >/dev/null 2>&1")
        // The count is the exit code, so the record needs no output; a history of 255 or more reads as 255.
        record["commits"] = check("count", "n=$(git rev-list --count HEAD) || exit 255; [ \"$n\" -lt 255 ] && exit \"$n\"; exit 255")
        record["clean"] = check("clean", "test -z \"$(git status --porcelain)\"") == 0
        if let remote, !remote.contains("'") {
            record["origin.same"] = check("origin", "test \"$(git remote get-url origin)\" = '\(remote)'") == 0
        }
        // Prompted credentials are not kept: no helper is set and no credential file exists.
        record["credential.helper"] = check("helper", storedHelper) == 0
        record["credential.file"] = check("file", storedFile) == 0
        #if os(iOS)
        let scanned = NSHomeDirectory()
        #else
        let scanned = host.registry.root
        #endif
        let scan = tokens(in: scanned)
        record["tokens.ms"] = scan.ms
        record["tokens.files"] = scan.files
        record["tokens.bytes"] = scan.bytes
        record["tokens.found"] = scan.found
        record["bootCount"] = host.bootCount
        var missed = misses(record, [:], ["clean": true, "credential.helper": false, "credential.file": false])
        if record["fsck.exitCode"] as? Int != 0 { missed.append("fsck.exitCode") }
        if record["head"] == nil { missed.append("head") }
        if remote != nil, record["origin.same"] as? Bool != true { missed.append("origin.same") }
        if !scan.found.isEmpty { missed.append("tokens.found") }
        missed.sort()
        record["missed"] = missed
        record["passed"] = missed.isEmpty && host.bootCount == 1
    }

    /// The files under `root` holding a GitHub token prefix, as paths relative to it. Read in chunks, so
    /// a disk image of several gigabytes needs little memory.
    static func tokens(in root: String) -> (files: Int, bytes: Int, found: [String], ms: Int) {
        let started = Date()
        let patterns = tokenPrefixes.map { Data($0.utf8) }
        let overlap = patterns.map(\.count).max()! - 1
        var files = 0, bytes = 0, found: [String] = []
        let items = FileManager.default.enumerator(atPath: root)
        while let relative = items?.nextObject() as? String {
            guard items?.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  let handle = FileHandle(forReadingAtPath: root + "/" + relative) else { continue }
            defer { try? handle.close() }
            files += 1
            var tail = Data(), hit = false
            while !hit, let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                bytes += chunk.count
                let window = tail + chunk
                hit = patterns.contains { window.range(of: $0) != nil }
                tail = window.suffix(overlap)
            }
            if hit { found.append(relative) }
        }
        return (files, bytes, found.sorted(), ms(Date().timeIntervalSince(started)))
    }

    // MARK: Helpers

    /// A terminal the probe runs lines in, one at a time. Each line prints a marker with its exit code,
    /// so a line's result is read from the output without its text.
    private final class Shell {
        let host: CandidateHost, id: String, cwd: String, timing: Timing
        private var offset = 0, count = 0
        /// How often the terminal was reopened: a new Worker closes the terminals an earlier one left open.
        private(set) var reopened = 0
        private var output = ""
        /// The output of the last line, kept in the probe only: records hold a reason code, not the text.
        var last: String { output }

        init(_ host: CandidateHost, _ id: String, _ cwd: String, _ timing: Timing) throws {
            self.host = host; self.id = id; self.cwd = cwd; self.timing = timing
            try open()
        }

        private func open() throws {
            offset = 0
            guard terminalOpen(host, id, cwd) == "OPEN" else { throw CandidateError("TERMINAL_REFUSED") }
            guard terminalUntil(host, id, &offset, timing, { ($0["activity"] as? [String: Any])?["state"] as? String == "idle" }) else {
                throw CandidateError("TERMINAL_NOT_IDLE")
            }
        }

        /// The exit code of `line`, or nil when its marker did not come within `limit`.
        func run(_ line: String, _ limit: TimeInterval? = nil) -> Int? {
            count += 1
            let tag = "@@\(count)@@"
            guard send(line + "; printf '\\n\(tag)%d@@\\n' $?\n") else { return nil }
            guard read(limit ?? timing.line, { $0.contains(tag) && Shell.code($0, tag) != nil }) else { return nil }
            return Shell.code(output, tag)
        }

        /// Sends `line` and reads until its output contains `text` (`prompted`), or until the line ends
        /// first (its exit code in `ended`).
        func prompt(_ line: String, _ text: String, _ limit: TimeInterval) -> (prompted: Bool, ended: Int?) {
            count += 1
            let tag = "@@\(count)@@"
            guard send(line + "; printf '\\n\(tag)%d@@\\n' $?\n"),
                  read(limit, { $0.contains(text) || Shell.code($0, tag) != nil }) else { return (false, nil) }
            let ended = Shell.code(output, tag)
            return (ended == nil, ended)
        }

        /// A fixed code for why a Git command ended, from its output.
        static func reason(_ output: String) -> String {
            let known: [(String, String)] = [
                ("terminal prompts disabled", "PROMPTS_DISABLED"), ("Username for", "PROMPTED"),
                ("already exists and is not an empty directory", "NOT_EMPTY"), ("Could not resolve host", "DNS"),
                ("Failed to connect", "CONNECT"), ("Couldn't connect", "CONNECT"), ("timed out", "TIMEOUT"),
                ("SSL", "TLS"), ("certificate", "TLS"), ("Authentication failed", "AUTH"), ("not found", "NOT_FOUND")]
            return known.first { output.contains($0.0) }?.1 ?? "OTHER"
        }

        /// Sends Ctrl-C and returns the exit code of what was running.
        func interrupt() -> Int? {
            _ = terminalWrite(host, id, "\u{3}")
            Thread.sleep(forTimeInterval: 2)
            count += 1
            let tag = "@@\(count)@@"
            guard send("printf '\\n\(tag)%d@@\\n' $?\n"), read(timing.line, { Shell.code($0, tag) != nil }) else { return nil }
            return Shell.code(output, tag)
        }

        func close() { _ = host.handle(["operation": "terminal-close", "terminalId": id]) }

        /// Writes once the project's lease is free: the user's own line may still be finishing. A terminal
        /// closed by a new Worker is reopened once; a line it was running is not resumed.
        private func send(_ text: String) -> Bool {
            output = ""
            let deadline = Date().addingTimeInterval(120)
            var retried = false
            while true {
                let written = terminalWrite(host, id, text)
                if written.hasPrefix("WRITTEN") { return true }
                if written == "TERMINAL_NOT_FOUND", !retried, Date() < deadline {
                    retried = true
                    guard (try? open()) != nil else { return false }
                    reopened += 1
                    continue
                }
                guard written == "REFUSED:LEASE_BUSY", Date() < deadline else { return false }
                Thread.sleep(forTimeInterval: 1)
            }
        }

        private func read(_ limit: TimeInterval, _ done: (String) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(limit)
            while Date() < deadline {
                let reply = terminalRead(host, id, &offset, waitMs: 5000)
                if reply["error"] != nil { return false }
                output += decoded(reply["data"]) ?? ""
                if done(output) { return true }
            }
            return false
        }

        /// The code printed after `tag`. The echoed line holds `%d` there, so it never matches.
        private static func code(_ output: String, _ tag: String) -> Int? {
            guard let range = output.range(of: tag + "(-?[0-9]+)@@", options: .regularExpression) else { return nil }
            return Int(output[range].dropFirst(tag.count).dropLast(2))
        }
    }

    /// The names at the root of a workspace, sorted.
    private static func listing(_ workspace: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: workspace)) ?? []).sorted()
    }

    /// A Git ref read natively, loose or packed.
    private static func ref(_ workspace: String, _ name: String) -> String? {
        if let loose = try? String(contentsOfFile: workspace + "/.git/" + name, encoding: .utf8) {
            return loose.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let packed = (try? String(contentsOfFile: workspace + "/.git/packed-refs", encoding: .utf8)) ?? ""
        for line in packed.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[1] == name { return String(fields[0]) }
        }
        return nil
    }

    /// The commit `HEAD` names, read natively.
    private static func head(_ workspace: String) -> String? {
        guard let text = try? String(contentsOfFile: workspace + "/.git/HEAD", encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("ref: ") ? ref(workspace, String(value.dropFirst(5))) : value
    }

    /// A TCP listener on a free host loopback port, to see whether a guest command connects to it.
    private final class Listener {
        let fd: Int32
        let port: UInt16

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CandidateError("PORT_UNAVAILABLE") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
            }
            guard bound, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw CandidateError("PORT_UNAVAILABLE") }
            self.fd = fd
            port = UInt16(bigEndian: address.sin_port)
        }

        /// True when a connection is waiting or was made; accepts and closes it.
        func accepted() -> Bool {
            let client = accept(fd, nil, nil)
            if client >= 0 { Darwin.close(client) }
            return client >= 0
        }

        func close() { Darwin.close(fd) }
    }

    /// The record keys whose value differs from the expected code or flag, sorted.
    private static func misses(_ record: [String: Any], _ expected: [String: String], _ flags: [String: Bool]) -> [String] {
        (expected.filter { record[$0.key] as? String != $0.value }.map(\.key)
            + flags.filter { record[$0.key] as? Bool != $0.value }.map(\.key)).sorted()
    }

    private static func named(_ host: CandidateHost, _ name: String?, _ timing: Timing) throws -> CandidateProject {
        var found: CandidateProject?
        _ = wait(timing.ready, timing.poll) { found = host.registry.projects.first { $0.name == name }; return found != nil }
        guard let found else { throw CandidateError("PROJECT_UNKNOWN") }
        return found
    }

    private static func project(_ host: CandidateHost, _ name: String, plugin: Bool) throws -> (String, String) {
        if let known = host.registry.projects.first(where: { $0.name == name }) { return (known.id, known.mount) }
        let created = host.handle(["operation": "project-create", "name": name, "pluginEnabled": plugin])
        guard let project = created["project"] as? [String: Any], let id = project["id"] as? String,
              let mount = project["mount"] as? String else { throw CandidateError("PROJECT_REFUSED") }
        return (id, mount)
    }

    private static func waitReady(_ host: CandidateHost, _ id: String, _ timing: Timing, _ record: inout [String: Any]) throws {
        _ = wait(timing.ready, timing.poll) { entry(host, id)?["phase"] as? String != "PREPARING" }
        let phase = entry(host, id)?["phase"] as? String
        guard phase == "READY" else {
            record["reason.open"] = entry(host, id)?["reason"] as? String
            record["diagnostic.open"] = (host.handle(["operation": "status"])["diagnostic"] as? [String: Any])?["code"] as? String
            throw CandidateError("LINUX_NOT_READY_" + (phase ?? "NONE"))
        }
    }

    private static func execute(_ host: CandidateHost, _ id: String, _ cwd: String, _ command: String, timeoutMs: Int = 120_000,
                                trigger: String = "shell") -> [String: Any] {
        host.handle(["operation": "execute", "operationId": id + "-" + runId, "command": command, "cwd": cwd,
                     "timeoutMs": timeoutMs, "trigger": trigger])
    }

    private static let maxTimeoutMs = 600_000

    private static func cancel(_ host: CandidateHost, _ id: String) -> String {
        describe(host.handle(["operation": "cancel", "operationId": id + "-" + runId]))
    }

    /// `create` when a native write commits at once; the failure code otherwise.
    private static func nativeWrite(_ host: CandidateHost, _ path: String) -> String {
        let data = Data("native\n".utf8).base64EncodedString()
        let written = host.handle(["operation": "fs", "method": "write",
                                   "args": ["path": path, "data": data, "expected": ["kind": "createIfAbsent"]]])
        return (written["value"] as? [String: Any])?["operation"] as? String
            ?? ((written["failure"] as? [String: Any])?["code"] as? String) ?? "NONE"
    }

    private static func terminalOpen(_ host: CandidateHost, _ id: String, _ cwd: String) -> String {
        let reply = host.handle(["operation": "terminal-open", "terminalId": id, "cwd": cwd, "argv": ["/bin/bash", "-i"],
                                 "cols": 80, "rows": 24, "env": [String: String](), "terminalType": "xterm-256color"])
        return reply["pid"] != nil ? "OPEN" : describe(reply)
    }

    private static func terminalWrite(_ host: CandidateHost, _ id: String, _ text: String) -> String {
        let reply = host.handle(["operation": "terminal-write", "terminalId": id, "data": Data(text.utf8).base64EncodedString()])
        guard reply["status"] as? String == "WRITTEN" else { return describe(reply) }
        return reply["leased"] as? Bool == true ? "WRITTEN:LEASED" : "WRITTEN"
    }

    private static func terminalRead(_ host: CandidateHost, _ id: String, _ offset: inout Int, waitMs: Int) -> [String: Any] {
        let reply = host.handle(["operation": "terminal-read", "terminalId": id, "offset": offset, "waitMs": waitMs])
        offset = reply["next"] as? Int ?? offset
        return reply
    }

    /// Reads the terminal until a reply satisfies `done`, for at most 30 s.
    private static func terminalUntil(_ host: CandidateHost, _ id: String, _ offset: inout Int, _ timing: Timing,
                                      _ done: ([String: Any]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let reply = terminalRead(host, id, &offset, waitMs: 1000)
            if done(reply) { return true }
            if reply["error"] != nil { return false }
            Thread.sleep(forTimeInterval: timing.poll)
        }
        return false
    }

    /// Runs `work` on its own thread; the returned function waits for its reply, for at most `limit`.
    private static func onThread(limit: TimeInterval = 120, _ work: @escaping () -> [String: Any]) -> () -> [String: Any] {
        let group = DispatchGroup(), lock = NSLock()
        var value: [String: Any] = ["status": "NO_REPLY"]
        group.enter()
        Thread.detachNewThread {
            let reply = work()
            lock.lock(); value = reply; lock.unlock()
            group.leave()
        }
        return {
            _ = group.wait(timeout: .now() + limit)
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private static func describe(_ reply: [String: Any]) -> String {
        [reply["status"] as? String ?? reply["error"] as? String ?? "NONE", reply["reason"] as? String].compactMap { $0 }.joined(separator: ":")
    }

    private static func decoded(_ value: Any?) -> String? {
        (value as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func registered(_ host: CandidateHost, _ id: String) throws -> CandidateProject {
        guard let project = host.registry.project(id) else { throw CandidateError("PROJECT_UNKNOWN") }
        return project
    }

    private static func entry(_ host: CandidateHost, _ id: String) -> [String: Any]? {
        (host.handle(["operation": "projects"])["projects"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private static func write(_ host: CandidateHost, _ phase: Phase, _ record: [String: Any]) {
        let directory = host.registry.root + "/probe"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: directory + "/measure-\(phase.rawValue).json"), options: .atomic)
        }
    }

    /// Operation ids stay unique across launches: a gateway's store runs each id at most once.
    private static let runId = String(UUID().uuidString.prefix(8))
    private static func stamp() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) }
    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    private static func time(_ body: () -> Void) -> TimeInterval {
        let start = Date(); body(); return Date().timeIntervalSince(start)
    }

    private static func wait(_ limit: TimeInterval, _ poll: TimeInterval, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while !done() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
        return true
    }

    /// When the kernel started this process.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// The process footprint the system limits (`phys_footprint`), its peak so far, and on iPad what the
    /// process may still allocate before it is ended.
    static func memory() -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return ["error": Int(result)] }
        var value: [String: Any] = ["footprintMB": mb(info.phys_footprint), "peakMB": mb(UInt64(info.ledger_phys_footprint_peak)),
                                    "residentMB": mb(info.resident_size)]
        #if os(iOS)
        value["availableMB"] = mb(UInt64(os_proc_available_memory()))
        #endif
        return value
    }

    /// Allocated bytes of the data root by top-level entry, of the App bundle, and the volume's free space.
    static func storage(_ root: String, _ bundle: String?) -> [String: Any] {
        var parts: [String: Int] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            parts[name] = Int(mb(allocated(root + "/" + name)))
        }
        var value: [String: Any] = ["rootMB": parts]
        if let bundle { value["bundleMB"] = mb(allocated(bundle)) }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        if let volume = try? URL(fileURLWithPath: root).resourceValues(forKeys: keys) {
            value["freeMB"] = volume.volumeAvailableCapacityForImportantUsage.map { mb(UInt64(max(0, $0))) } ?? -1
            value["totalMB"] = volume.volumeTotalCapacity.map { mb(UInt64($0)) } ?? -1
        }
        return value
    }

    private static func allocated(_ path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        var total = UInt64(info.st_blocks) * 512
        if info.st_mode & S_IFMT == S_IFDIR {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { total += allocated(path + "/" + name) }
        }
        return total
    }

    private static func mb(_ bytes: UInt64) -> Int { Int((Double(bytes) / 1_048_576).rounded()) }
}
