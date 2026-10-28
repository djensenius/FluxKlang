import XCTest
import UIKit

@MainActor
final class AssistantKeyboardUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    func testCompactPrimaryNavigationIsReachableWhileKeyboardIsVisible() throws {
        try launchAssistant()

        for destination in ["studio", "mix", "more"] {
            let composer = element("assistant.composer")
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

            for tab in ["studio", "assistant", "mix", "more"] {
                let button = app.buttons["navigation.keyboard.\(tab)"]
                XCTAssertTrue(button.waitForExistence(timeout: 5))
                XCTAssertTrue(button.isHittable, "\(tab) must be reachable without dismissing the keyboard")
                assertMinimumHitSize(button)
                XCTAssertLessThanOrEqual(button.frame.maxY, keyboard.frame.minY + 1)
            }
            // There must not be a second, conflicting set of visible primary tabs.
            XCTAssertFalse(app.tabBars.buttons["Assistant"].isHittable)

            // Navigate directly, without using Hide Keyboard or tapping outside the composer.
            XCTAssertTrue(keyboard.exists)
            app.buttons["navigation.keyboard.\(destination)"].tap()
            switch destination {
            case "studio":
                XCTAssertTrue(app.navigationBars["Studio"].waitForExistence(timeout: 5))
            case "mix":
                XCTAssertTrue(app.staticTexts["Faders"].waitForExistence(timeout: 5))
            default:
                XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
            }
            waitUntilHidden(keyboard)

            let assistantTab = app.tabBars.buttons["Assistant"]
            waitUntilHittable(assistantTab)
            assistantTab.tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Returning must not refocus the composer")
        }

        // The keyboard strip must use the existing More navigation stack, not a second destination list.
        element("assistant.composer").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["navigation.keyboard.more"].tap()
        let settings = app.buttons["more.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testMultilineComposerSendTargetAndDismissalInPortraitAndLandscape() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            try launchAssistant()
            XCUIDevice.shared.orientation = orientation

            let composer = element("assistant.composer")
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            XCTAssertTrue(element("assistant.spokenReplies").exists)
            assertNoAppMicrophone()
            let send = app.buttons["assistant.send"]
            XCTAssertFalse(send.isEnabled)

            composer.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            composer.typeText("First line\nSecond line")
            let multiline = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "First line\nSecond line"),
                object: composer
            )
            wait(for: [multiline], timeout: 5)
            XCTAssertTrue(send.isEnabled, "Return inserts a newline; only Send submits the message")
            XCTAssertTrue(send.isHittable)
            assertMinimumHitSize(send)
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1)
            assertNoAppMicrophone()

            let dismiss = app.buttons["assistant.hideKeyboard"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
            XCTAssertTrue(dismiss.isHittable)
            dismiss.tap()
            waitUntilHidden(keyboard)
            XCTAssertTrue(element("assistant.spokenReplies").waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    private func launchAssistant() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "Compact navigation coverage requires an iPhone destination"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-ui-testing",
            "-ui-test-force-fallback",
            "-ui-test-seed-acceptance",
            "-ui-test-demo"
        ]
        app.launch()
        let assistantTab = app.tabBars.buttons["Assistant"]
        XCTAssertTrue(assistantTab.waitForExistence(timeout: 10))
        assistantTab.tap()
        XCTAssertTrue(element("assistant.composer").waitForExistence(timeout: 5))
    }

    private func assertNoAppMicrophone(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.buttons["assistant.mic"].exists, file: file, line: line)
        for label in ["Start dictation", "Finish dictation", "Cancel dictation"] {
            XCTAssertFalse(app.buttons[label].exists, file: file, line: line)
        }
        XCTAssertEqual(
            app.alerts.count, 0, "Text entry must not prompt for app microphone access", file: file, line: line
        )
    }

    private func assertMinimumHitSize(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(button.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, file: file, line: line)
    }

    private func waitUntilHidden(_ keyboard: XCUIElement) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        wait(for: [hidden], timeout: 5)
    }

    private func waitUntilHittable(_ button: XCUIElement) {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
        wait(for: [hittable], timeout: 5)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
