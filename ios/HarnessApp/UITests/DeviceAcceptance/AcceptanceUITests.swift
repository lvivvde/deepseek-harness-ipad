import XCTest

/// Attach to the installed app. No app dependency, launch, terminate, or token entry.
@MainActor
final class AcceptanceUITests: XCTestCase {
    private enum AttachError: Error { case appUnavailable }

    private func attach() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.lvivvde.harness.ipad")
        guard [.runningForeground, .runningBackground, .runningBackgroundSuspended].contains(app.state) else {
            XCTFail("HARNESS_UI_APP_EXITED_DO_NOT_AUTO_RELAUNCH")
            throw AttachError.appUnavailable
        }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "HARNESS_UI_FOREGROUND_FAILED")
        return app
    }

    private func pageReady(_ app: XCUIApplication) -> XCUIElement {
        let reconnect = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "正在重新连接")).firstMatch
        let failed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "连接失败")).firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: reconnect)], timeout: 20),
            .completed, "HARNESS_UI_RECONNECT_STUCK")
        XCTAssertFalse(failed.exists, "HARNESS_UI_CONNECTION_FAILED")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), "HARNESS_UI_WEBVIEW_MISSING")
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "HARNESS_UI_INPUT_MISSING")
        XCTAssertTrue(input.isEnabled, "HARNESS_UI_INPUT_DISABLED")
        return input
    }

    func testInspectExistingPage() throws {
        let app = try attach()
        let start = Date()
        _ = pageReady(app)
        print("HARNESS_UI_SAFE:existingPageInteractive observedSeconds=\(Date().timeIntervalSince(start))")
    }

    func testReadOnlySettings() throws {
        let app = try attach()
        _ = pageReady(app)
        let tools = app.buttons["项目工具"]
        XCTAssertTrue(tools.waitForExistence(timeout: 10), "HARNESS_UI_TOOLS_MISSING")
        tools.tap()
        app.buttons["iPad 应用设置…"].tap()
        XCTAssertTrue(app.staticTexts["容量上限"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["已占 iPad 空间"].exists)
        XCTAssertTrue(app.staticTexts["iPad 剩余空间"].exists)
        XCTAssertTrue(app.buttons["导出完整备份…"].exists)
        if !app.buttons["恢复备份…"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["恢复备份…"].exists)
        app.buttons["完成"].tap()
        _ = pageReady(app)
        print("HARNESS_UI_SAFE:settingsEntriesPresent=true")
    }

    /// Explicit opt-in only. A Home switch is not a physical lock test.
    func testAttachAndShortBackgroundSwitch() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["HARNESS_ACCEPTANCE_CHECK"] != "short-background",
                      "HARNESS_UI_EXPLICIT_SHORT_SWITCH_REQUIRED")
        let app = try attach()
        let input = pageReady(app)
        let previous = input.value as? String
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3) || app.state == .runningBackgroundSuspended)
        Thread.sleep(forTimeInterval: 3)
        let start = Date()
        guard [.runningBackground, .runningBackgroundSuspended, .runningForeground].contains(app.state) else {
            XCTFail("HARNESS_UI_APP_EXITED_DO_NOT_AUTO_RELAUNCH")
            throw AttachError.appUnavailable
        }
        app.activate()
        let returnedInput = pageReady(app)
        XCTAssertEqual(previous, returnedInput.value as? String, "HARNESS_UI_DRAFT_CHANGED")
        print("HARNESS_UI_SAFE:shortSwitchInteractive observedSeconds=\(Date().timeIntervalSince(start))")
        print("HARNESS_UI_SAFE:existingInputValueEqual=true")
    }

    /// Explicit opt-in. Skips rather than overwriting a draft or sending twice.
    func testExistingSessionReplyAfterRecovery() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["HARNESS_ACCEPTANCE_CHECK"] != "session-reply",
                      "HARNESS_UI_EXPLICIT_REQUEST_REQUIRED")
        let app = try attach()
        let input = pageReady(app)
        let value = (input.value as? String) ?? ""
        try XCTSkipIf(!value.isEmpty && value != input.placeholderValue, "HARNESS_UI_PRESERVE_EXISTING_DRAFT")
        let send = app.buttons.matching(NSPredicate(format: "label IN %@",
            ["发送", "发送消息", "Send", "Send message", "Send Message", "Submit", "提交"])).firstMatch
        try XCTSkipIf(!send.exists, "HARNESS_UI_SEND_CONTROL_UNIDENTIFIED")
        let answer = app.staticTexts.matching(NSPredicate(format: "label == %@", "RECOVERY_OK")).firstMatch
        try XCTSkipIf(answer.exists, "HARNESS_UI_EXISTING_REPLY_MARKER")
        input.tap()
        input.typeText("后台恢复验收：只回复英文单词 RECOVERY_OK，不要加解释。")
        XCTAssertTrue(send.isEnabled, "HARNESS_UI_SEND_DISABLED_TEST_DRAFT_REMAINS")
        let start = Date()
        send.tap()
        let stop = app.buttons.matching(NSPredicate(format: "label IN %@",
            ["停止", "停止生成", "Stop", "Stop generating", "Stop Generation"])).firstMatch
        print("HARNESS_UI_SAFE:streamingStopControlSeen=\(stop.waitForExistence(timeout: 5))")
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "HARNESS_UI_REPLY_MARKER_NOT_OBSERVED")
        print("HARNESS_UI_SAFE:existingSessionExpectedReplySeen responseSeconds=\(Date().timeIntervalSince(start))")
    }
}
