import XCTest
import UIKit

@MainActor
final class AssistantKeyboardUITests: XCTestCase {
    private lazy var app = XCUIApplication()
    private lazy var springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testCompactPrimaryNavigationIsReachableWhileKeyboardIsVisible() throws {
        try launchAssistant()

        for destination in ["studio", "mix", "more"] {
            let composer = element("assistant.composer")
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            captureKeyboardLayout("Keyboard open before navigating to \(destination)")

            for tab in ["studio", "assistant", "mix", "more"] {
                let button = app.buttons["navigation.keyboard.\(tab)"]
                XCTAssertTrue(button.waitForExistence(timeout: 5))
                XCTAssertTrue(button.isHittable, "\(tab) must be reachable without dismissing the keyboard")
                assertMinimumHitSize(button)
                XCTAssertLessThanOrEqual(button.frame.maxY, keyboard.frame.minY + 1)
            }
            let strip = app.buttons["navigation.keyboard.studio"]
            let send = app.buttons["assistant.send"]
            XCTAssertLessThanOrEqual(send.frame.maxY, strip.frame.minY + 1, "Composer must not overlap navigation")
            XCTAssertLessThanOrEqual(strip.frame.minY - send.frame.maxY, 24, "Composer must stay beside navigation")
            // There must not be a second, conflicting set of visible primary tabs.
            let nativeAssistantTab = app.tabBars.buttons["Assistant"]
            XCTAssertFalse(nativeAssistantTab.exists && nativeAssistantTab.isHittable)

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
            let text = "First line \(orientation.rawValue)\nSecond line \(UUID().uuidString.prefix(4))"
            composer.typeText(text)
            captureKeyboardLayout("Multiline composer \(orientation)")
            XCTAssertTrue(send.isEnabled, "Return inserts a newline; only Send submits the message")
            XCTAssertTrue(send.isHittable)
            assertMinimumHitSize(send)
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1)
            assertNoAppMicrophone()
            XCTAssertFalse(app.staticTexts[text].exists, "Return must not submit the message")
            send.tap()

            let dismiss = app.buttons["assistant.hideKeyboard"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
            XCTAssertTrue(dismiss.isHittable)
            dismiss.tap()
            waitUntilHidden(keyboard)
            XCTAssertTrue(element("assistant.spokenReplies").waitForExistence(timeout: 5))
            // Compact landscape can devote all message space to the composer while editing.
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5), "Send preserves both lines")
            app.terminate()
        }
    }

    private func launchAssistant() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "Compact navigation coverage requires an iPhone destination"
        )
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        // Keyboard/navigation coverage needs no live mixer or continuously animated demo meters.
        app.launchArguments = ["-ui-testing", "-ui-test-force-fallback"]
        app.launch()
        let assistantTab = app.tabBars.buttons["Assistant"]
        XCTAssertTrue(assistantTab.waitForExistence(timeout: 10))
        assistantTab.tap()
        XCTAssertTrue(element("assistant.composer").waitForExistence(timeout: 5))
    }

    private func captureKeyboardLayout(_ name: String) {
        let description = app.debugDescription
        let tree = XCTAttachment(string: description)
        tree.name = "\(name) accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("KEYBOARD LAYOUT \(name)\n\(description)")
    }

    private func assertNoAppMicrophone(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.buttons["assistant.mic"].exists, file: file, line: line)
        for label in ["Start dictation", "Finish dictation", "Cancel dictation"] {
            XCTAssertFalse(app.buttons[label].exists, file: file, line: line)
        }
        XCTAssertEqual(
            springboard.alerts.count, 0, "Text entry must not prompt for app microphone access", file: file, line: line
        )
    }

    private func assertMinimumHitSize(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // Accessibility converts pixel-aligned frames to points with floating-point rounding.
        XCTAssertGreaterThanOrEqual(button.frame.width + 0.000_001, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.height + 0.000_001, 44, file: file, line: line)
    }

    private func waitUntilHidden(_ keyboard: XCUIElement) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        wait(for: [hidden], timeout: 5)
    }

    private func waitUntilHittable(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
        wait(for: [hittable], timeout: 5)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
