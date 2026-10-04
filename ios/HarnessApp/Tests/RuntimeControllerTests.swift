import Foundation
import XCTest
@testable import HarnessRuntime

@MainActor
final class RuntimeControllerTests: XCTestCase {
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
    var onReconnectStarted: (() -> Void)?
    private var reconnectResult: CheckedContinuation<URL, Never>?
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
        if pauseReconnect {
            return await withCheckedContinuation { result in
                reconnectResult = result
                onReconnectStarted?()
            }
        }
        return endpoint
    }

    func finishReconnect() {
        reconnectResult?.resume(returning: endpoint)
        reconnectResult = nil
    }

    func flush() async {}
}
