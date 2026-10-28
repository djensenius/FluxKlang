import XCTest

@MainActor
final class AssistantActionReviewUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    func testCandidateSelectionRefreshesReviewAndDisclosesSuggestedAmount() {
        launchReview("candidate")
        let candidate = app.buttons["assistant.action.candidate.astrolab-7"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        XCTAssertTrue(candidate.label.contains("Channel 7"))
        XCTAssertTrue(candidate.label.contains("AstroLab"))
        XCTAssertTrue(candidate.label.contains("LOCAL 4"))
        XCTAssertTrue(candidate.label.contains("Unlinked to saved Equipment"))
        XCTAssertTrue(app.buttons["assistant.action.candidate.astrolab-9"].exists)
        XCTAssertFalse(app.buttons["assistant.action.confirm"].exists)
        assertConfirmCalls(0)

        candidate.tap()
        let suggested = element("assistant.action.suggestedAmount")
        XCTAssertTrue(suggested.waitForExistence(timeout: 5))
        XCTAssertTrue(suggested.label.contains("lower by 3 dB"))
        XCTAssertTrue(suggested.label.contains("amount not specified"))
        XCTAssertTrue(app.buttons["assistant.action.confirm"].isEnabled)
        XCTAssertFalse(app.buttons["assistant.action.candidate.astrolab-9"].exists)
        assertConfirmCalls(0)
        capture("Candidate refreshed to suggested 3 dB review")
    }

    func testReadyReviewShowsExactStereoBeforeAfterAndHardwareConfirmation() {
        launchReview("ready")
        let confirm = app.buttons["assistant.action.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.label.contains("Write to WING Hardware"))
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        let left = element("assistant.action.change.channel-7")
        let right = element("assistant.action.change.channel-8")
        reveal(left)
        XCTAssertTrue(left.label.contains("Left"))
        XCTAssertTrue(left.label.contains("Channel 7"))
        XCTAssertTrue(left.label.contains("Mother-32 L"))
        XCTAssertTrue(left.label.contains("Before: 0.0 dB"))
        XCTAssertTrue(left.label.contains("After: -10.0 dB"))
        XCTAssertTrue(left.label.contains("50.0% travel"))
        reveal(right)
        XCTAssertTrue(right.label.contains("Right"))
        XCTAssertTrue(right.label.contains("Channel 8"))
        XCTAssertTrue(right.label.contains("Mother-32 R"))
        XCTAssertTrue(right.label.contains("After: -10.0 dB"))
        assertConfirmCalls(0)
        capture("Explicit left right fader review")
    }

    func testExpiredReviewCannotConfirm() {
        launchReview("expired")
        let confirm = app.buttons["assistant.action.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        let expired = element("assistant.action.expired")
        reveal(expired)
        XCTAssertTrue(expired.label.contains("Review expired"))
        assertConfirmCalls(0)
    }

    func testRestoredCardHasNoReviewOrConfirmationCapability() {
        launchReview("restored")
        let inert = element("assistant.action.inertCard")
        XCTAssertTrue(inert.waitForExistence(timeout: 5))
        XCTAssertTrue(inert.label.contains("cannot confirm"))
        XCTAssertFalse(app.buttons["assistant.action.showReview"].exists)
        XCTAssertFalse(app.buttons["assistant.action.confirm"].exists)
        assertConfirmCalls(0)
        capture("Restored inert action card")
    }

    func testPartialResultReportsLocalAndPerMemberOutcome() {
        launchReview("partial")
        XCTAssertTrue(app.staticTexts["Partial outcome"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("assistant.action.localResult").label, "Shortcut: added locally")
        XCTAssertTrue(element("assistant.action.memberResult.channel-7").label.contains("Confirmed by readback"))
        XCTAssertTrue(element("assistant.action.memberResult.channel-8").label.contains("Not sent"))
        XCTAssertFalse(app.buttons["assistant.action.confirm"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "No automatic rollback or retry"
        )).firstMatch.exists)
        capture("Truthful local and partial stereo result")
    }

    func testConsumedReviewRemainsVisibleAndCancelRevokesQueuedFixtureChanges() {
        launchReview("confirming")
        let confirm = app.buttons["assistant.action.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Tap the same location again while the actual control is disabled.
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(element("assistant.action.review").exists, "Consuming pendingReview must not dismiss the sheet")
        XCTAssertFalse(confirm.isEnabled)
        assertConfirmCalls(1)
        let cancel = app.buttons["assistant.action.cancel"]
        XCTAssertEqual(cancel.label, "Stop Remaining Changes")
        cancel.tap()
        XCTAssertTrue(element("assistant.action.result").waitForExistence(timeout: 8))
        XCTAssertTrue(element("assistant.action.memberResult.channel-7").label.contains("Not sent"))
        XCTAssertTrue(element("assistant.action.memberResult.channel-8").label.contains("Not sent"))
        XCTAssertEqual(element("assistant.action.localResult").label, "Shortcut: not attempted")
        assertConfirmCalls(1)
        XCTAssertFalse(confirm.exists)
    }

    private func launchReview(_ mode: String) {
        continueAfterFailure = false
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-ui-testing", "-ui-test-force-fallback", "-ui-test-action-review", mode]
        app.launch()
        let assistant = app.tabBars.buttons["Assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 10))
        assistant.tap()
    }

    private func assertConfirmCalls(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let counter = element("assistant.action.fixtureConfirmCalls")
        XCTAssertTrue(counter.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(counter.label, "Fixture confirm calls: \(count)", file: file, line: line)
    }

    private func reveal(_ target: XCUIElement) {
        for _ in 0..<8 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.exists)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
