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
        func launch() throws {
            lock.lock(); count += 1; lock.unlock()
            release.wait()
            if fails { throw NSError(domain: "test", code: 1) }
        }
    }

    let missing = LinuxAvailability.detect { _ in false }
    let present = LinuxAvailability.detect { _ in true }

    func waitPhase(_ plugin: LinuxPlugin, _ phase: LinuxPlugin.Phase) {
        let deadline = Date().addingTimeInterval(5)
        while plugin.phase != phase, Date() < deadline { usleep(1_000) }
        XCTAssertEqual(plugin.phase, phase)
    }

    /// Admits on a background thread so a hang shows up as a timeout, not a stuck test.
    func admit(_ plugin: LinuxPlugin, _ task: LinuxPlugin.Task, enabled: Bool, within seconds: TimeInterval = 1,
               cancelled: @escaping @Sendable () -> Bool = { false }) -> LinuxPlugin.Admission? {
        let done = DispatchSemaphore(value: 0)
        let box = NSMutableArray()
        DispatchQueue.global().async {
            box.add(plugin.admit(task, pluginEnabled: enabled, isCancelled: cancelled))
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
        XCTAssertEqual(plugin.open(pluginEnabled: false), .unavailable(.privateSymbolMissing))
        XCTAssertEqual(admit(plugin, .native("fs.read"), enabled: false), .native)
        XCTAssertEqual(admit(plugin, .shell("ls"), enabled: false), .refused("LINUX_PLUGIN_NOT_ENABLED"))
        XCTAssertEqual(launcher.launches, 0)
    }

    func testMissingProjectWithPluginOpensNativelyWithoutPreparing() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: missing, launcher: launcher.launch)
        XCTAssertEqual(plugin.open(pluginEnabled: true), .unavailable(.privateSymbolMissing))
        XCTAssertEqual(plugin.prepare(), .unavailable(.privateSymbolMissing))
        XCTAssertEqual(admit(plugin, .native("fs.write"), enabled: true), .native)
        XCTAssertEqual(launcher.launches, 0)
    }

    func testMissingLinuxTaskIsRefusedImmediatelyInsteadOfWaiting() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: missing, launcher: launcher.launch)
        _ = plugin.open(pluginEnabled: true)
        // A task queued before any preparation would wait for ready in the present branch.
        XCTAssertEqual(admit(plugin, .shell("node test.cjs"), enabled: true), .refused("LINUX_PRIVATE_SYMBOL_MISSING"))
        XCTAssertEqual(launcher.launches, 0)
    }

    func testMissingHookTaskIsRefusedImmediately() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: missing, launcher: launcher.launch)
        _ = plugin.open(pluginEnabled: true)
        XCTAssertEqual(admit(plugin, .hook("PreToolUse"), enabled: true), .refused("LINUX_PRIVATE_SYMBOL_MISSING"))
        XCTAssertEqual(launcher.launches, 0)
    }

    func testMissingCapabilityDeclarationShowsReasonAndKeepsNativeItems() throws {
        let plugin = LinuxPlugin(availability: missing, launcher: {})
        let declaration = plugin.declaration(pluginEnabled: true)
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
        XCTAssertEqual(plugin.open(pluginEnabled: true), .preparing)
        XCTAssertEqual(plugin.prepare(), .preparing)
        let queued = DispatchSemaphore(value: 0)
        var answers: [LinuxPlugin.Admission] = []
        DispatchQueue.global().async {
            answers.append(plugin.admit(.shell("npm test"), pluginEnabled: true, isCancelled: { false }))
            answers.append(plugin.admit(.hook("Stop"), pluginEnabled: true, isCancelled: { false }))
            queued.signal()
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 0.3), .timedOut, "task must wait for ready")
        launcher.release.signal()
        XCTAssertEqual(queued.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(answers, [.linux, .linux])
        XCTAssertEqual(plugin.phase, .ready)
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(plugin.declaration(pluginEnabled: true).plugin.state, "READY")
    }

    func testPresentProjectWithoutPluginNeverLaunches() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        XCTAssertEqual(plugin.open(pluginEnabled: false), .cold)
        XCTAssertEqual(admit(plugin, .shell("ls"), enabled: false), .refused("LINUX_PLUGIN_NOT_ENABLED"))
        XCTAssertEqual(admit(plugin, .hook("Stop"), enabled: false), .refused("LINUX_PLUGIN_NOT_ENABLED"))
        XCTAssertEqual(launcher.launches, 0)
        let declaration = plugin.declaration(pluginEnabled: false)
        XCTAssertEqual(declaration.plugin.state, "NOT_ENABLED")
        XCTAssertTrue(declaration.items.filter { $0.path == .linux }.allSatisfy { $0.reason == "LINUX_PLUGIN_NOT_ENABLED" })
    }

    func testPresentCancelWhileWaitingNeverDispatches() {
        let launcher = Launcher()
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        _ = plugin.open(pluginEnabled: true)
        let flag = NSLock(); var cancelled = false
        let done = DispatchSemaphore(value: 0); var answer: LinuxPlugin.Admission?
        DispatchQueue.global().async {
            answer = plugin.admit(.shell("rm -rf x"), pluginEnabled: true, isCancelled: { flag.lock(); defer { flag.unlock() }; return cancelled })
            done.signal()
        }
        usleep(100_000)
        flag.lock(); cancelled = true; flag.unlock()
        plugin.wake()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(answer, .cancelledBeforeDispatch)
        launcher.release.signal()
    }

    func testPresentLaunchFailureIsExplicitAndNotRetriedInProcess() {
        let launcher = Launcher(); launcher.fails = true
        let plugin = LinuxPlugin(availability: present, launcher: launcher.launch)
        _ = plugin.open(pluginEnabled: true)
        launcher.release.signal()
        waitPhase(plugin, .failed)
        XCTAssertEqual(admit(plugin, .shell("ls"), enabled: true), .refused("LINUX_PREPARE_FAILED"))
        XCTAssertEqual(plugin.prepare(), .failed)
        XCTAssertEqual(launcher.launches, 1, "at most one QEMU start per App process")
    }
}
