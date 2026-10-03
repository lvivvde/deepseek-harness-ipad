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
}

@MainActor
private final class RecordingDriver: RuntimeDriving {
    private(set) var hasLaunched = false
    private(set) var starts = 0
    private(set) var reconnects = 0
    var onEvent: (@MainActor (RuntimeEvent) -> Void)?
    let endpoint = URL(string: "http://127.0.0.1:18080/?token=test-only")!

    func start(onEvent: @escaping @MainActor (RuntimeEvent) -> Void) async throws {
        starts += 1
        self.onEvent = onEvent
        await Task.yield()
        hasLaunched = true
        onEvent(.booting)
    }

    func reconnect() async throws -> URL {
        reconnects += 1
        return endpoint
    }

    func flush() async {}
}
