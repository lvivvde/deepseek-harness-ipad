import XCTest
import Vision
@MainActor final class NativeMenuUITests: XCTestCase {
    func testNativeRowMenuLight() throws { try runMenu(dark: false) }
    func testNativeRowMenuDark() throws { try runMenu(dark: true) }
    private func runMenu(dark: Bool) throws {
        let app = XCUIApplication(bundleIdentifier: "org.lvivvde.harness.acceptance.menu-fixture")
        app.launchArguments = dark ? ["dark"] : []
        app.launch()
        let row = app.buttons["验收项目甲"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["导出…"].waitForExistence(timeout: 3))
        XCTAssertTrue(row.exists, "NATIVE_ROW_TEXT_DISAPPEARED")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: app.screenshot().image.cgImage!, options: [:]).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(visible.contains { $0.contains("验收项目甲") }, "NATIVE_ROW_TITLE_NOT_RENDERED_WITH_MENU")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = dark ? "native-menu-dark" : "native-menu-light"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["原生菜单隔离验收"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let trash = app.buttons["验收项目乙, 回收站测试行"]
        XCTAssertTrue(trash.exists)
        trash.tap()
        XCTAssertTrue(app.buttons["恢复"].waitForExistence(timeout: 3))
        XCTAssertTrue(trash.exists, "NATIVE_TRASH_ROW_TEXT_DISAPPEARED")
        try VNImageRequestHandler(cgImage: app.screenshot().image.cgImage!, options: [:]).perform([request])
        let trashVisible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(trashVisible.contains { $0.contains("验收项目乙") }, "NATIVE_TRASH_TITLE_NOT_RENDERED_WITH_MENU")
        print("SIM_UI_SAFE:nativeProjectAndTrashMenusTextPreserved dark=\(dark)")
    }
}
