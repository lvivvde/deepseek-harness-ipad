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
/// - `imported`: a project the same launch imports from an old backup (`project`, by name) brings
///   Linux up, the guest sees every imported entry, and a guest write lands.
/// - `execution` (PR #56): a cancel that arrives first ends its ID for good, a running command is
///   cancelled and its lease ends, a terminal holds the lease only while a line runs and a command joins
///   it, a closed terminal ID is gone, and a VM exit during a command settles the lease this process sent.
/// - `execution-hold` leaves a command running in a new project for the driver to end the App;
///   `execution-stale` opens that project (`project`) in the next launch: the writer the earlier launch
///   left stays unknown across this launch's VM exit until it is released explicitly.
/// Each phase writes `<root>/probe/measure-<phase>.json` with numbers and fixed codes only, tagged with
/// the launch's `run` id and marked `done` once final.
public enum MeasureProbe {
    public enum Phase: String {
        case cold, scheduling, lifecycle, background, backgroundIdle = "background-idle", imported
        case execution, executionHold = "execution-hold", executionStale = "execution-stale"
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
        public init() {}
    }

    @discardableResult
    public static func run(_ phase: Phase, host: CandidateHost, bundle: String? = nil, project: String? = nil,
                           timing: Timing = .init()) -> [String: Any] {
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
            case .imported: try imported(host, project, timing, &record)
            case .execution: try execution(host, timing, &record)
            case .executionHold: try executionHold(host, timing, &record)
            case .executionStale: try executionStale(host, project, timing, &record)
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

    private static func imported(_ host: CandidateHost, _ name: String?, _ timing: Timing, _ record: inout [String: Any]) throws {
        // The import runs on the App's queue alongside this probe; wait for its project record.
        let project = try named(host, name, timing)
        record["pluginEnabled"] = project.pluginEnabled
        let opened = Date()
        _ = host.handle(["operation": "project-open", "id": project.id])
        try waitReady(host, project.id, timing, &record)
        record["linuxReadyMs"] = ms(Date().timeIntervalSince(opened))
        let listed = execute(host, "imported-list", project.mount, "find . -mindepth 1 | wc -l")
        record["list"] = describe(listed)
        record["guestEntries"] = Int((listed["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        record["nativeEntries"] = FileManager.default.enumerator(atPath: host.registry.workspace(project))?.allObjects.count ?? -1
        let stamp = stamp()
        let wrote = execute(host, "imported-write", project.mount, "echo \(stamp) > .probe-imported && cat .probe-imported && rm .probe-imported")
        record["write"] = describe(wrote)
        record["bootCount"] = host.bootCount
        record["passed"] = record["list"] as? String == "COMPLETED" && record["guestEntries"] as? Int == record["nativeEntries"] as? Int
            && wrote["stdout"] as? String == stamp + "\n" && host.bootCount == 1
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
        let missed = expected.filter { record[$0.key] as? String != $0.value }.map(\.key)
            + flags.filter { record[$0.key] as? Bool != $0.value }.map(\.key)
        record["missed"] = missed.sorted()
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
        record["passed"] = record["stale.writerUnknown"] as? Bool == true && record["stale.command"] as? String == "REFUSED:WRITER_UNKNOWN"
            && record["exit.phase"] as? String == "FAILED" && record["exit.writerUnknown"] as? Bool == true
            && record["release"] as? String == "RELEASED" && record["after.writerUnknown"] as? Bool == false
            && record["after.nativeWrite"] as? String == "create" && host.bootCount == 1
    }

    // MARK: Helpers

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

    private static func execute(_ host: CandidateHost, _ id: String, _ cwd: String, _ command: String, timeoutMs: Int = 120_000) -> [String: Any] {
        host.handle(["operation": "execute", "operationId": id + "-" + runId, "command": command, "cwd": cwd,
                     "timeoutMs": timeoutMs, "trigger": "shell"])
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

    /// Runs `work` on its own thread; the returned function waits for its reply, for at most 120 s.
    private static func onThread(_ work: @escaping () -> [String: Any]) -> () -> [String: Any] {
        let group = DispatchGroup(), lock = NSLock()
        var value: [String: Any] = ["status": "NO_REPLY"]
        group.enter()
        Thread.detachNewThread {
            let reply = work()
            lock.lock(); value = reply; lock.unlock()
            group.leave()
        }
        return {
            _ = group.wait(timeout: .now() + 120)
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
