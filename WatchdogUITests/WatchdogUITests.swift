import XCTest

final class WatchdogUITests: XCTestCase {
    private let actionableProcess = "process.71001.9071001"

    @MainActor
    func testShippingAppShowsHeaderAndTextualAlertReasons() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let header = app.staticTexts["Watchdog"]
        XCTAssertTrue(header.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["CPU 높음"].exists)
        XCTAssertTrue(app.staticTexts["메모리 높음"].exists)
        XCTAssertTrue(app.staticTexts["고아 의심"].exists)

        let row = app.descendants(matching: .any)["\(actionableProcess).row"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        XCTAssertTrue(row.label.contains("claude"))
        XCTAssertTrue(app.staticTexts["연결된 터미널 세션을 찾을 수 없습니다"].exists)
    }

    @MainActor
    func testAboutPanelShowsVersionAndCopyright() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }

        let aboutButton = app.buttons["watchdog.about"]
        XCTAssertTrue(aboutButton.waitForExistence(timeout: 5))
        aboutButton.click()

        let version = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '0.1.0' OR value CONTAINS '0.1.0'")
        ).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 2))

        let copyright = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '2026 justn-hyeok' OR value CONTAINS '2026 justn-hyeok'")
        ).firstMatch
        XCTAssertTrue(copyright.exists)
    }

    @MainActor
    func testSearchShowsNoMatchState() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        let searchField = app.textFields["watchdog.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.click()
        searchField.typeText("fixture-with-no-matching-process")

        XCTAssertTrue(app.staticTexts["검색 결과가 없습니다"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["다른 프로세스 이름, PID 또는 프로젝트를 검색해보세요."].exists)
    }

    @MainActor
    func testStaleFixtureDisablesControlsAndExplainsWhy() {
        let app = launch(arguments: ["--ui-test-stale-fixture"])
        defer { app.terminate() }

        let row = app.descendants(matching: .any)["\(actionableProcess).row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("claude"))
        XCTAssertTrue(app.staticTexts["관찰 정보가 오래되어 새로고침 후 제어할 수 있습니다"].exists)

        let suspend = app.descendants(matching: .any)["\(actionableProcess).suspend"]
        XCTAssertTrue(suspend.exists)
        XCTAssertEqual(suspend.label, "프로세스 일시 정지")
        XCTAssertFalse(suspend.isEnabled)

        let actions = app.descendants(matching: .any)["\(actionableProcess).actions"]
        XCTAssertTrue(actions.exists)
        XCTAssertFalse(actions.isEnabled)
    }

    @MainActor
    func testAuthoritativeOutcomeWordingDoesNotClaimExit() {
        let app = launch(arguments: ["--ui-test-outcome-fixture"])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["종료 여부를 확인하지 못함"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["종료 확인됨"].exists)
    }

    @MainActor
    func testIgnoreAndUndoAreVisibleAndReversible() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        openActionMenu(in: app)
        XCTAssertTrue(app.menuItems["종료할 때까지 무시"].waitForExistence(timeout: 2))
        app.menuItems["종료할 때까지 무시"].click()
        let agentsScope = app.radioButtons["에이전트"]
        XCTAssertTrue(agentsScope.waitForExistence(timeout: 2))
        agentsScope.click()
        XCTAssertTrue(app.staticTexts["무시 중"].waitForExistence(timeout: 2))

        let undoIgnore = app.buttons["\(actionableProcess).undo-ignore"]
        XCTAssertTrue(undoIgnore.waitForExistence(timeout: 2))
        undoIgnore.click()
        XCTAssertTrue(app.staticTexts["무시 중"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["CPU 높음"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testExitedAndStillRunningOutcomeWording() {
        var app = launch(arguments: ["--ui-test-exited-fixture"])
        XCTAssertTrue(app.staticTexts["종료 확인됨"].waitForExistence(timeout: 5))
        app.terminate()

        app = launch(arguments: ["--ui-test-still-running-fixture"])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["신호 후에도 실행 중"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["종료 확인됨"].exists)
    }

    @MainActor
    func testTerminateConfirmationCanBeReachedAndCancelledWithoutSendingSignal() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        openActionMenu(in: app)
        let terminate = app.menuItems["\(actionableProcess).terminate"]
        XCTAssertTrue(terminate.waitForExistence(timeout: 2))
        terminate.click()

        let title = app.staticTexts["프로세스를 종료할까요?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["종료"].exists)
        app.windows.firstMatch.buttons["취소"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '신호를 전달했습니다'")).firstMatch.exists)
    }

    @MainActor
    func testForceQuitHasSeparateStrongerConfirmationAndCanBeCancelled() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        openActionMenu(in: app)
        let forceQuit = app.menuItems["\(actionableProcess).force-quit"]
        XCTAssertTrue(forceQuit.waitForExistence(timeout: 2))
        forceQuit.click()

        let title = app.staticTexts["프로세스를 강제 종료할까요?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["강제 종료"].exists)
        app.windows.firstMatch.buttons["취소"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '신호를 전달했습니다'")).firstMatch.exists)
    }

    @MainActor
    private func openActionMenu(in app: XCUIApplication) {
        let actions = app.descendants(matching: .any)["\(actionableProcess).actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isEnabled)
        actions.click()
        XCTAssertTrue(app.menuItems["종료…"].waitForExistence(timeout: 2))
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }
}
