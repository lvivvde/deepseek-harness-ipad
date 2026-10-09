import Foundation
import XCTest
import LinuxPlugin

/// Gate 2: the Linux compatibility plugin depends on the private `pthread_fchdir_np`. Both branches are
/// exercised: the real host resolver (present on macOS) and an injected resolver that reports it missing.
final class LinuxPluginTests: XCTestCase {
    final class Launcher: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let release = DispatchSemaphore(value: 0)
        var fails = false
        var launches: Int { lock.lock(); defer { lock.unlock() }; return count }
        private var projects: [String] = []
        var launched: [String] { lock.lock(); defer { lock.unlock() }; return projects }
        func launch(_ project: String) throws {
            lock.lock(); count += 1; projects.append(project); lock.unlock()
            release.wait()
            if fails { throw NSError(domain: "test", code: 1) }
        }
    }

    let missing = LinuxAvailability.detect { _ in false }
    let present = LinuxAvailability.detect { _ in true }

    func waitPhase(_ plugin: LinuxPlugin, _ project: String, _ phase: LinuxPlugin.Phase) {
        let deadline = Date().addingTimeInterval(5)
        while plugin.phase(of: project) != phase, Date() < deadline { usleep(1_000) }
        XCTAssertEqual(plugin.phase(of: project), phase)
    }

    /// Admits on a background thread so a hang shows up as a timeout, not a stuck test.
    func admit(_ plugin: LinuxPlugin, _ task: LinuxPlugin.Task, project: String = "A", within seconds: TimeInterval = 1,
               cancelled: @escaping @Sendable () -> Bool = { false }) -> LinuxPlugin.Admission? {
        let done = DispatchSemaphore(value: 0)
        let box = NSMutableArray()
        DispatchQueue.global().async {
            box.add(plugin.admit(task, project: project, isCancelled: cancelled))
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.firstObject as? LinuxPlugin.Admission
    }

    func testDetectionQueriesTheExactPrivateSymbol() {
        var asked: [String] = []
        _ = LinuxAvailability.detect { asked.append($0); return true }
        XCTAssertEqual(asked, ["pthread_fchdir_np"])
    }

    func testRealResolverFindsTheSymbolOnThisHost() {
        XCTAssertEqual(LinuxAvailability.detect(), .available)
        XCTAssertFalse(LinuxAvailability.symbolResolves("plan500_symbol_that_does_not_exist"))
    }

    func testMissingSymbolHasAFixedReasonCode() {
        XCTAssertEqual(missing, .unavailable(.privateSymbolMissing))
        XCTAssertEqual(LinuxAvailability.Reason.privateSymbolMissing.rawValue, "LINUX_PRIVATE_SYMBOL_MISSING")
    }

    func testExecutionPathIsChosenFromTheTaskKind() {
        XCTAssertEqual(LinuxPlugin.Task.native("fs.write").path, .native)
        XCTAssertEqual(LinuxPlugin.Task.shell("npm test").path, .linux)
        XCTAssertEqual(LinuxPlugin.Task.hook("PreToolUse").path, .linux)
        XCTAssertEqual(LinuxPlugin.Task.git("commit").path, .linux)
    }

    /// #39 gate 5: every repository-changing Git operation and its hooks run on Linux; reads stay native.
    func testGitWritesAreDeclaredOnLinuxAndGitReadsNative() {
        let paths = Dictionary(uniqueKeysWithValues: CapabilityDeclaration.scope.map { ($0.0, $0.1) })
        XCTAssertEqual(paths["git.write"], .linux)
        XCTAssertEqual(paths["git.read"], .native)
        XCTAssertEqual(paths["review"], .native)
    }

    // MARK: missing branch

    func testMissingProjectWithoutPluginOpensNativelyAndNeverLaunches() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: missing, launcher: launcher.launch)
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: false), .disabled)
        XCTAssertEqual(admit(plugin, .native("fs.read")), .native)
        XCTAssertEqual(admit(plugin, .shell("ls")), .refused("LINUX_PLUGIN_NOT_ENABLED"))
        XCTAssertEqual(launcher.launches, 0)
    }

    func testMissingProjectWithPluginOpensNativelyWithoutPreparing() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: missing, launcher: launcher.launch)
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: true), .unavailable("LINUX_PRIVATE_SYMBOL_MISSING"))
        XCTAssertEqual(admit(plugin, .native("fs.write")), .native)
        XCTAssertEqual(launcher.launches, 0)
    }

    func testMissingLinuxTaskIsRefusedImmediatelyInsteadOfWaiting() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: missing, launcher: launcher.launch)
        _ = plugin.open(project: "A", pluginEnabled: true)
        // A task queued before any preparation would wait for ready in the present branch.
        XCTAssertEqual(admit(plugin, .shell("node test.cjs")), .refused("LINUX_PRIVATE_SYMBOL_MISSING"))
        XCTAssertEqual(admit(plugin, .hook("PreToolUse")), .refused("LINUX_PRIVATE_SYMBOL_MISSING"))
        XCTAssertEqual(launcher.launches, 0)
    }

    func testMissingCapabilityDeclarationShowsReasonAndKeepsNativeItems() throws {
        let plugin = LinuxPlugin(availability: missing, launcher: { _ in })
        _ = plugin.open(project: "A", pluginEnabled: true)
        let declaration = plugin.declaration(project: "A")
        XCTAssertEqual(declaration.plugin.state, "UNAVAILABLE")
        XCTAssertEqual(declaration.plugin.reason, "LINUX_PRIVATE_SYMBOL_MISSING")
        for item in declaration.items where item.path == .native { XCTAssertTrue(item.available, item.name) }
        let linux = declaration.items.filter { $0.path == .linux }
        XCTAssertFalse(linux.isEmpty)
        for item in linux {
            XCTAssertFalse(item.available, item.name)
            XCTAssertEqual(item.reason, "LINUX_PRIVATE_SYMBOL_MISSING")
        }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(declaration)) as? [String: Any]
        XCTAssertEqual((json?["plugin"] as? [String: Any])?["reason"] as? String, "LINUX_PRIVATE_SYMBOL_MISSING")
    }

    // MARK: present branch

    func testPresentPluginPreparesOnceAndQueuedTaskRunsAfterReady() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: true), .preparing)
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: true), .preparing)
        let queued = DispatchSemaphore(value: 0)
        var answers: [LinuxPlugin.Admission] = []
        DispatchQueue.global().async {
            answers.append(plugin.admit(.shell("npm test"), project: "A", isCancelled: { false }))
            answers.append(plugin.admit(.hook("Stop"), project: "A", isCancelled: { false }))
            queued.signal()
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 0.3), .timedOut, "task must wait for ready")
        launcher.release.signal()
        XCTAssertEqual(queued.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(answers, [.linux, .linux])
        XCTAssertEqual(plugin.phase(of: "A"), .ready)
        XCTAssertEqual(launcher.launched, ["A"])
        XCTAssertEqual(plugin.declaration(project: "A").plugin.state, "READY")
    }

    func testPresentProjectWithoutPluginNeverLaunches() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: false), .disabled)
        XCTAssertEqual(admit(plugin, .shell("ls")), .refused("LINUX_PLUGIN_NOT_ENABLED"))
        XCTAssertEqual(admit(plugin, .hook("Stop")), .refused("LINUX_PLUGIN_NOT_ENABLED"))
        XCTAssertEqual(launcher.launches, 0)
        let declaration = plugin.declaration(project: "A")
        XCTAssertEqual(declaration.plugin.state, "NOT_ENABLED")
        XCTAssertFalse(declaration.plugin.enabled)
        XCTAssertTrue(declaration.items.filter { $0.path == .linux }.allSatisfy { $0.reason == "LINUX_PLUGIN_NOT_ENABLED" })
    }

    func testPresentCancelWhileWaitingNeverDispatches() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        _ = plugin.open(project: "A", pluginEnabled: true)
        let flag = NSLock(); var cancelled = false
        let done = DispatchSemaphore(value: 0); var answer: LinuxPlugin.Admission?
        DispatchQueue.global().async {
            answer = plugin.admit(.shell("rm -rf x"), project: "A", isCancelled: { flag.lock(); defer { flag.unlock() }; return cancelled })
            done.signal()
        }
        usleep(100_000)
        flag.lock(); cancelled = true; flag.unlock()
        plugin.wake()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(answer, .cancelledBeforeDispatch)
        launcher.release.signal()
        waitPhase(plugin, "A", .ready)
    }

    func testPresentLaunchFailureIsExplicitAndNotRetriedInProcess() {
        let launcher = Launcher(); launcher.fails = true
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        _ = plugin.open(project: "A", pluginEnabled: true)
        launcher.release.signal()
        waitPhase(plugin, "A", .failed("LINUX_PREPARE_FAILED"))
        XCTAssertEqual(admit(plugin, .shell("ls")), .refused("LINUX_PREPARE_FAILED"))
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: true), .failed("LINUX_PREPARE_FAILED"))
        XCTAssertEqual(launcher.launches, 1, "at most one QEMU start per App process")
    }

    // MARK: per-project binding

    /// The guest mounts one project. The first plugin project opened owns Linux for the process; a later
    /// one is told to restart the App instead of starting a second QEMU or sharing the first project's guest.
    func testLinuxBindsToTheFirstPluginProjectAndRefusesOthers() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        XCTAssertEqual(plugin.open(project: "plain", pluginEnabled: false), .disabled)
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: true), .preparing)
        XCTAssertEqual(plugin.open(project: "B", pluginEnabled: true), .unavailable("LINUX_BOUND_TO_OTHER_PROJECT"))
        XCTAssertEqual(admit(plugin, .shell("ls"), project: "B"), .refused("LINUX_BOUND_TO_OTHER_PROJECT"))
        XCTAssertEqual(admit(plugin, .native("fs.write"), project: "B"), .native)
        launcher.release.signal()
        waitPhase(plugin, "A", .ready)
        XCTAssertEqual(plugin.phase(of: "B"), .unavailable("LINUX_BOUND_TO_OTHER_PROJECT"))
        XCTAssertEqual(plugin.declaration(project: "B").plugin.reason, "LINUX_BOUND_TO_OTHER_PROJECT")
        XCTAssertTrue(plugin.declaration(project: "B").plugin.enabled)
        XCTAssertEqual(launcher.launched, ["A"])
    }

    // MARK: VM exit

    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [(LinuxPlugin.Diagnostic, LinuxPlugin.Phase)] = []
        var records: [LinuxPlugin.Diagnostic] { lock.lock(); defer { lock.unlock() }; return saved.map(\.0) }
        /// The phase visible while the record was being saved.
        var phasesWhileSaving: [LinuxPlugin.Phase] { lock.lock(); defer { lock.unlock() }; return saved.map(\.1) }
        var plugin: LinuxPlugin?
        func save(_ record: LinuxPlugin.Diagnostic) {
            let phase = plugin?.phase(of: record.project) ?? .disabled
            lock.lock(); saved.append((record, phase)); lock.unlock()
        }
    }

    func testVMExitAfterReadySavesDiagnosticsBeforeFailingAndNeverRestarts() {
        let launcher = Launcher(), diagnostics = Diagnostics()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch, diagnostics: diagnostics.save)
        diagnostics.plugin = plugin
        _ = plugin.open(project: "A", pluginEnabled: true)
        launcher.release.signal()
        waitPhase(plugin, "A", .ready)
        plugin.vmExited(status: 137)
        XCTAssertEqual(diagnostics.records, [LinuxPlugin.Diagnostic(code: "LINUX_VM_EXITED", project: "A", stage: "READY", status: 137)])
        XCTAssertEqual(diagnostics.phasesWhileSaving, [.ready], "diagnostics are saved before the failure is published")
        XCTAssertEqual(plugin.phase(of: "A"), .failed("LINUX_VM_EXITED"))
        XCTAssertEqual(admit(plugin, .shell("ls")), .refused("LINUX_VM_EXITED"))
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: true), .failed("LINUX_VM_EXITED"))
        XCTAssertEqual(plugin.declaration(project: "A").plugin.reason, "LINUX_VM_EXITED")
        plugin.vmExited(status: 137)
        XCTAssertEqual(diagnostics.records.count, 1, "one exit, one record")
        XCTAssertEqual(launcher.launches, 1)
    }

    func testVMExitWhilePreparingRefusesWaitingTasksAndKeepsTheExitReason() {
        let launcher = Launcher(); launcher.fails = true
        let diagnostics = Diagnostics()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch, diagnostics: diagnostics.save)
        _ = plugin.open(project: "A", pluginEnabled: true)
        let done = DispatchSemaphore(value: 0); var answer: LinuxPlugin.Admission?
        DispatchQueue.global().async {
            answer = plugin.admit(.git("commit"), project: "A", isCancelled: { false }); done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 0.2), .timedOut)
        plugin.vmExited(status: nil)
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(answer, .refused("LINUX_VM_EXITED"))
        // The launcher then gives up on the dead guest; the exit stays the recorded reason.
        launcher.release.signal()
        usleep(100_000)
        XCTAssertEqual(plugin.phase(of: "A"), .failed("LINUX_VM_EXITED"))
        XCTAssertEqual(diagnostics.records, [LinuxPlugin.Diagnostic(code: "LINUX_VM_EXITED", project: "A", stage: "PREPARING", status: nil)])
    }

    func testLaunchFailureSavesItsFixedCause() {
        let diagnostics = Diagnostics()
        let plugin = LinuxPlugin(availability: present, launcher: { _ in throw LinuxPlugin.LaunchFailure("READY_PROOF_REFUSED") },
                                 diagnostics: diagnostics.save)
        _ = plugin.open(project: "A", pluginEnabled: true)
        waitPhase(plugin, "A", .failed("LINUX_PREPARE_FAILED"))
        XCTAssertEqual(diagnostics.records, [LinuxPlugin.Diagnostic(code: "LINUX_PREPARE_FAILED", project: "A", stage: "PREPARING",
                                                                    cause: "READY_PROOF_REFUSED")])
    }

    func testExitBeforeAnyLaunchIsIgnored() {
        let diagnostics = Diagnostics()
        let plugin = LinuxPlugin(availability: present, launcher: { _ in }, diagnostics: diagnostics.save)
        plugin.vmExited(status: 0)
        XCTAssertTrue(diagnostics.records.isEmpty)
        XCTAssertEqual(plugin.open(project: "A", pluginEnabled: true), .preparing)
    }

    /// The shipped document and the App show the same scope.
    func testCapabilityDocumentMatchesTheDeclaredScope() throws {
        let document = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../docs/design/capability-declaration.md")
        let rows = try String(contentsOf: document, encoding: .utf8).split(separator: "\n").compactMap { line -> String? in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, ["`native`", "`linux`", "`unsupported`"].contains(cells[1]) else { return nil }
            return "\(cells[0]) \(cells[1])"
        }
        XCTAssertEqual(rows, CapabilityDeclaration.scope.map { "`\($0.0)` `\($0.1.rawValue)`" })
    }
}
