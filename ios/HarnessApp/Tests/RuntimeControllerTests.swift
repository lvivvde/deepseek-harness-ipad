import Foundation
import XCTest
@testable import HarnessRuntime

@MainActor
final class RuntimeControllerTests: XCTestCase {
    func testReturningDuringExpiredRecoveryRunsFreshProbe() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))
        driver.pauseReconnect = true
        let oldProbe = Task { await runtime.resume() }
        await withCheckedContinuation { started in
            driver.onReconnectStarted = { started.resume() }
        }
        // The App returns while the probe started before suspension is still pending.
        await runtime.resume()
        driver.pauseReconnect = false
        driver.finishReconnect(failure: .guestControl)
        await oldProbe.value

        XCTAssertEqual(runtime.phase, .ready, "An expired probe must not consume the new foreground recovery")
        XCTAssertEqual(driver.reconnects, 2)
        XCTAssertEqual(runtime.pageRevision, 1)
        XCTAssertEqual(driver.starts, 1)
    }

    func testControlTimeoutAllowsRetryWithoutRestartingVM() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))
        driver.reconnectFailure = .control
        await runtime.resume()

        guard case .failed(_, requiresRelaunch: false) = runtime.phase else {
            return XCTFail("A control timeout is not evidence that QEMU exited")
        }
        XCTAssertTrue(runtime.diagnostics.contains("reconnectFailed:control"))
        driver.reconnectFailure = nil
        await runtime.retry()
        XCTAssertEqual(runtime.phase, .ready)
        XCTAssertEqual(driver.starts, 1)
    }

    func testForegroundRecoveryReopensPageEvenWhenHTTPStayedHealthy() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))

        await runtime.resume()

        XCTAssertEqual(runtime.phase, .ready)
        XCTAssertEqual(runtime.pageRevision, 1, "HTTP readiness must not leave the suspended page connection in place")
        XCTAssertEqual(driver.starts, 1)
    }

    func testGrowingUserDiskRequiresReadyRuntimeAndRejectsOverlap() async throws {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        do { _ = try await runtime.growUserDisk(toGiB: 16); XCTFail("Not ready") }
        catch { XCTAssertEqual(error as? UserDiskError, .busy) }
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))
        let growth = Task { try await runtime.growUserDisk(toGiB: 16) }
        while driver.growthResult == nil { await Task.yield() }
        do { _ = try await runtime.growUserDisk(toGiB: 32); XCTFail("Overlapping operation") }
        catch { XCTAssertEqual(error as? UserDiskError, .busy) }
        await runtime.resume()
        await runtime.recoverPage()
        XCTAssertEqual(driver.reconnects, 0)
        driver.growthResult?.resume(returning: UserDiskStatus(capacityBytes: 16 << 30, allocatedBytes: 1 << 30, hostAvailableBytes: 8 << 30))
        _ = try await growth.value
        XCTAssertEqual(runtime.phase, .ready)
        XCTAssertEqual(driver.reconnects, 1, "Defer the connection check until growth finishes")
        XCTAssertEqual(runtime.pageRevision, 1, "A page exit during growth must still reload afterward")
        XCTAssertEqual(driver.starts, 1)
    }

    func testConcurrentOpeningStartsOnlyOneRuntime() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)

        async let first: Void = runtime.ensureRunning()
        async let second: Void = runtime.ensureRunning()
        _ = await (first, second)

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(runtime.phase, .booting)
    }

    func testReloadingThePageReconnectsWithoutRestartingRuntime() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))

        await runtime.recoverPage()
        await runtime.ensureRunning()

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.reconnects, 1)
        XCTAssertEqual(runtime.destination, driver.endpoint)
        XCTAssertEqual(runtime.pageRevision, 1)
        XCTAssertEqual(runtime.phase, .ready)
    }

    func testExitedRuntimeCannotBeRevivedByStalePageEvents() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.exited)
        driver.onEvent?(.ready(driver.endpoint))

        await runtime.recoverPage()
        await runtime.ensureRunning()

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.reconnects, 0)
        guard case .failed(_, requiresRelaunch: true) = runtime.phase else {
            return XCTFail("Exited VM must require an App relaunch")
        }
    }

    func testPageTerminationDuringForegroundProbeStillReloadsThePage() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))
        driver.pauseReconnect = true

        let probe = Task { await runtime.resume() }
        await withCheckedContinuation { started in
            driver.onReconnectStarted = { started.resume() }
        }
        await runtime.recoverPage()
        driver.finishReconnect()
        await probe.value

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.reconnects, 1)
        XCTAssertEqual(runtime.pageRevision, 1)
        XCTAssertEqual(runtime.phase, .ready)
    }

    func testHarnessExitRemainsRecoverableAndNeverRestartsVM() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))
        driver.onEvent?(.harnessStopped)
        guard case .failed(_, requiresRelaunch: false) = runtime.phase else { return XCTFail("Harness failure is recoverable") }
        await runtime.retry()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.reconnects, 1)
        XCTAssertEqual(runtime.phase, .ready)
    }

    func testDataOperationFailureKeepsOnlyItsFixedCodeInDiagnostics() async {
        XCTAssertEqual(RuntimeEvent.dataFailure(serialLine: "HARNESS_BACKUP_FAILURE:PAUSE")?.diagnosticStage, "userDataOperationFailed:BACKUP:PAUSE")
        XCTAssertEqual(RuntimeEvent.dataFailure(serialLine: "HARNESS_TRANSFER_FAILURE:WRITERS_BUSY")?.diagnosticStage, "userDataOperationFailed:TRANSFER:WRITERS_BUSY")
        XCTAssertEqual(RuntimeEvent.dataFailure(serialLine: "HARNESS_TRANSFER_FAILURE:/root/secret path")?.diagnosticStage, "userDataOperationFailed:TRANSFER:UNKNOWN")
        XCTAssertNil(RuntimeEvent.dataFailure(serialLine: "HARNESS_PROCESS_STOPPED"))
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.ready(driver.endpoint))
        driver.onEvent?(RuntimeEvent.dataFailure(serialLine: "HARNESS_BACKUP_FAILURE:PAUSE")!)
        XCTAssertEqual(runtime.phase, .ready, "A refused backup must not mark the page failed")
        XCTAssertEqual(runtime.diagnostics.last, "userDataOperationFailed:BACKUP:PAUSE")
    }

    func testClockAcknowledgementMustMatchCurrentHostTimeWithinTwoSeconds() throws {
        let health = try JSONDecoder().decode(GuestHealth.self, from: Data(#"{"clock":true,"epoch":100000,"running":true,"writable":true,"restartable":false}"#.utf8))
        XCTAssertTrue(health.clockMatches(Date(timeIntervalSince1970: 101)))
        XCTAssertFalse(health.clockMatches(Date(timeIntervalSince1970: 103)))
    }

    func testIncompatibleUserDiskRemainsFailedWithoutRestartOrStaleReadiness() async {
        let driver = RecordingDriver()
        let runtime = RuntimeController(driver: driver)
        await runtime.ensureRunning()
        driver.onEvent?(.bootFailed(.userLayout))
        driver.onEvent?(.ready(driver.endpoint))
        await runtime.retry()

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.reconnects, 0)
        XCTAssertNil(runtime.destination)
        XCTAssertEqual(runtime.phase, .failed(RuntimeBootFailure.userLayout.message, requiresRelaunch: true))
    }
}

@MainActor
private final class RecordingDriver: RuntimeDriving {
    private(set) var hasLaunched = false
    private(set) var starts = 0
    private(set) var reconnects = 0
    var onEvent: (@MainActor (RuntimeEvent) -> Void)?
    var pauseReconnect = false
    var reconnectFailure: RecoveryFailure?
    var onReconnectStarted: (() -> Void)?
    private var reconnectResult: CheckedContinuation<URL, Error>?
    let endpoint = URL(string: "http://127.0.0.1:28080/?token=test-only")!

    func start(onEvent: @escaping @MainActor (RuntimeEvent) -> Void) async throws {
        starts += 1
        self.onEvent = onEvent
        await Task.yield()
        hasLaunched = true
        onEvent(.booting)
    }

    func reconnect() async throws -> URL {
        reconnects += 1
        if let reconnectFailure { throw reconnectFailure }
        if pauseReconnect {
            return try await withCheckedThrowingContinuation { result in
                reconnectResult = result
                onReconnectStarted?()
            }
        }
        return endpoint
    }

    func finishReconnect(failure: RecoveryFailure? = nil) {
        if let failure { reconnectResult?.resume(throwing: failure) }
        else { reconnectResult?.resume(returning: endpoint) }
        reconnectResult = nil
    }

    var growthResult: CheckedContinuation<UserDiskStatus, Error>?
    func growUserDisk(toGiB size: Int) async throws -> UserDiskStatus {
        try await withCheckedThrowingContinuation { growthResult = $0 }
    }
    func flush() async {}
}
