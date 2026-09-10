import XCTest

@MainActor
final class FluxKlangAcceptanceUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    func testPrimaryNavigationDraftAndTemporaryMoveSafety() {
        launchSeededDemo()

        XCTAssertTrue(app.navigationBars["Studio"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("studio.status").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["assistant.pendingDraft.review"].waitForExistence(timeout: 10))

        app.buttons["assistant.pendingDraft.review"].tap()
        XCTAssertTrue(app.navigationBars["Review Studio Draft"].waitForExistence(timeout: 5))
        let safety = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Accept only adds valid Studio nodes")
        ).firstMatch
        XCTAssertTrue(safety.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.pendingDraft.accept"].isEnabled)
        app.buttons["assistant.pendingDraft.close"].tap()

        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(app.navigationBars["Assistant"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Mix"].tap()
        XCTAssertTrue(app.staticTexts["Faders"].waitForExistence(timeout: 5))
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))

        app.buttons["more.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings-studio-connections"].tap()
        XCTAssertTrue(app.navigationBars["Studio Connections"].waitForExistence(timeout: 5))
        app.buttons["Return OP-1 Field Home"].tap()
        XCTAssertTrue(app.navigationBars["Return Home"].waitForExistence(timeout: 5))
        app.swipeUp()
        let confirmation = element("temporary-move-return-cables-confirmed")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertEqual(confirmation.value as? String, "0")
        app.swipeUp()
        let apply = element("temporary-move-return-apply-routing")
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
    }

    func testAssistantTextEntryUsesGroundedFallback() {
        launchSeededDemo()
        app.tabBars.buttons["Assistant"].tap()

        let composer = app.textFields["assistant.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Explain this screen")
        app.buttons["assistant.send"].tap()

        XCTAssertTrue(element("assistant.availability").waitForExistence(timeout: 5))
        let response = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Current screen:")
        ).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 10))
    }

    func testConnectionFailureRecoversThroughDemoMode() {
        continueAfterFailure = false
        app.launchArguments = [
            "-ui-testing",
            "-ui-test-force-fallback",
            "-ui-test-connection-failure"
        ]
        app.launch()

        let status = app.buttons["connection.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let failedStatus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Connection failed"),
            object: status
        )
        wait(for: [failedStatus], timeout: 10)
        status.tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connection Problem"].exists)
        app.buttons["connection.demo"].tap()
        let demoStatus = app.staticTexts["Demo Mode — values are simulated and drift to feel live."]
        XCTAssertTrue(demoStatus.waitForExistence(timeout: 10))
    }

    private func launchSeededDemo() {
        continueAfterFailure = false
        app.launchArguments = [
            "-ui-testing",
            "-ui-test-force-fallback",
            "-ui-test-seed-acceptance",
            "-ui-test-demo"
        ]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
