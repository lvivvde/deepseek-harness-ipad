import Foundation
import XCTest
@testable import HarnessRuntime

final class HarnessEndpointTests: XCTestCase {
    func testOnlyOfficialLoopbackLaunchURLIsRemappedAndTokenIsPreserved() {
        let url = HarnessEndpoint.fromSerialLine("dsh web: http://127.0.0.1:3001/?token=test-only%2Bvalue")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:28080/?token=test-only%2Bvalue")
        XCTAssertFalse(HarnessEndpoint.isLocalPage(URL(string: "http://127.0.0.1:18080/")!))
        for line in ["dsh web: https://example.com/?token=x",
                     "dsh web: http://127.0.0.1:3001/?token=",
                     "dsh web: http://127.0.0.1:3001/?token=a&token=b",
                     "dsh web: http://name:password@127.0.0.1:3001/?token=x"] {
            XCTAssertNil(HarnessEndpoint.fromSerialLine(line))
        }
    }

    func testCachedBusyBox200IsNotHarnessReadiness() {
        XCTAssertFalse(HarnessEndpoint.isReady(status: 200, body: Data("guest-local-http-ok".utf8)))
        XCTAssertFalse(HarnessEndpoint.isReady(status: 503, body: Data("__DSH_BOOT__".utf8)))
        XCTAssertTrue(HarnessEndpoint.isReady(status: 200, body: Data("<script>__DSH_BOOT__</script>".utf8)))
    }
}
