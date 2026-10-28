import XCTest

@MainActor
final class AssistantMultiRouteUITests: XCTestCase {
    private lazy var app = XCUIApplication()
    private let osmose = "Expressive E Osmose"
    private let solar = "Elta SOLAR 42F"
    private let evilPet = "Endorphin.es EviL Pet"

    func testReviewKeepsThreeSourceSpecificBranchesAndConfiguredDesktopCables() {
        launchFixture()
        openReview()
        XCTAssertEqual(element("assistant.pendingDraft.applicationMode").label, "Append to current Studio graph")
        assertOwnerPaths()
        assertFixtureHasNotWritten()
        assertCable(output: 1, destination: "Desk Speakers L")
        assertCable(output: 2, destination: "Desk Speakers R")
        assertCable(output: 7, destination: "Main Speakers L")
        assertCable(output: 8, destination: "Main Speakers R")
        XCTAssertTrue(app.buttons["assistant.pendingDraft.accept"].isEnabled)
        capture("Three named branches and configured desktop output cables")

        // Opening the production review triggers revalidation; closing and
        // reopening must not collapse its graph or summary to the primary route.
        app.buttons["assistant.pendingDraft.close"].tap()
        openReview()
        assertOwnerPaths()
        assertFixtureHasNotWritten()
    }

    func testAcceptPreservesAllBranchesLocallyAndDoesNotAutomaticallyListen() {
        launchFixture()
        openReview()
        assertOwnerPaths()
        assertFixtureHasNotWritten()
        app.buttons["assistant.pendingDraft.accept"].tap()
        waitForReviewToClose()
        XCTAssertFalse(app.buttons["assistant.pendingDraft.review"].exists)
        assertNotSentYet()
        assertConnection("\(osmose) -> Main Speakers")
        assertConnection("\(solar) -> \(evilPet)")
        assertConnection("\(evilPet) -> Main Speakers")
        assertConnection("OP-XY -> Desk Speakers")
        XCTAssertFalse(app.staticTexts["\(solar) -> Main Speakers"].exists, "No unintended Solar dry path")
        XCTAssertFalse(app.staticTexts["\(osmose) -> \(evilPet)"].exists)
        XCTAssertFalse(app.staticTexts["OP-XY -> Main Speakers"].exists)
        assertWireCount(4)
        capture("Accepted graph retains source-specific routing without Listen")
    }

    func testDiscardLeavesPriorLocalGraphUnchanged() {
        launchFixture()
        openReview()
        assertOwnerPaths()
        assertFixtureHasNotWritten()
        let graph = element("assistant.multiRoute.localGraph")
        reveal(graph)
        XCTAssertEqual(graph.label, "Current local graph: 2 nodes · 1 wires")
        app.buttons["assistant.pendingDraft.discardReview"].tap()
        waitForReviewToClose()
        XCTAssertFalse(app.buttons["assistant.pendingDraft.review"].exists)
        assertNotSentYet()
        assertConnection("\(osmose) -> Main Speakers")
        XCTAssertFalse(app.staticTexts["\(solar) -> \(evilPet)"].exists)
        XCTAssertFalse(app.staticTexts["OP-XY -> Desk Speakers"].exists)
        assertWireCount(1)
        capture("Discard keeps the prior Osmose graph")
    }

    func testExplicitDryParallelShowsFourPathsAndAcceptsTheDryWire() {
        launchFixture(extraArguments: ["-ui-test-multi-route-dry-parallel"])
        openReview()
        let count = element("assistant.pendingDraft.routingCount")
        reveal(count)
        XCTAssertEqual(count.label, "3 branches · 4 logical paths")
        assertPath(1, "\(osmose) → Main Speakers")
        assertPath(2, "\(solar) → Main Speakers")
        assertPath(2, "\(solar) → \(evilPet) → Main Speakers", path: 2)
        assertPath(3, "OP-XY → Desk Speakers")
        let dryPolicy = element("assistant.pendingDraft.branch.2.path.1.signalPolicy")
        reveal(dryPolicy, upwards: false)
        XCTAssertTrue(dryPolicy.label.contains("Dry path · parallel"))
        let wetPolicy = element("assistant.pendingDraft.branch.2.path.2.signalPolicy")
        reveal(wetPolicy)
        XCTAssertTrue(wetPolicy.label.contains("Processed (wet) path · parallel"))
        assertFixtureHasNotWritten()
        app.buttons["assistant.pendingDraft.accept"].tap()
        waitForReviewToClose()
        assertNotSentYet()
        assertConnection("\(solar) -> Main Speakers")
        assertConnection("\(solar) -> \(evilPet)")
        assertConnection("\(evilPet) -> Main Speakers")
        assertConnection("OP-XY -> Desk Speakers")
        assertWireCount(5)
    }

    func testReplacementReviewAtAccessibilitySizeNamesEveryBranchAndSeparateListen() {
        launchFixture(extraArguments: [
            "-ui-test-multi-route-replace",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openReview()
        let mode = element("assistant.pendingDraft.applicationMode")
        reveal(mode)
        XCTAssertEqual(mode.label, "Replace current Studio graph")
        let safety = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Listen remains a separate action"
        )).firstMatch
        reveal(safety)
        XCTAssertTrue(safety.label.contains("does not write to the WING"))
        assertOwnerPaths()
        assertFixtureHasNotWritten()
        assertCable(output: 1, destination: "Desk Speakers L")
        assertCable(output: 2, destination: "Desk Speakers R")
        XCTAssertEqual(app.buttons["assistant.pendingDraft.accept"].label, "Replace Studio")
        XCTAssertTrue(app.buttons["assistant.pendingDraft.accept"].isEnabled)
        capture("Accessibility size replacement review with three complete paths")
    }

    private func launchFixture(extraArguments: [String] = []) {
        continueAfterFailure = false
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        // No -ui-test-demo: the new DEBUG seed must force a simulated transport itself.
        app.launchArguments = ["-ui-testing", "-ui-test-force-fallback", "-ui-test-multi-route"] + extraArguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Studio"].waitForExistence(timeout: 10))
    }

    private func openReview() {
        let review = app.buttons["assistant.pendingDraft.review"]
        reveal(review)
        review.tap()
        XCTAssertTrue(app.navigationBars["Review Studio Draft"].waitForExistence(timeout: 5))
    }

    private func assertOwnerPaths(file: StaticString = #filePath, line: UInt = #line) {
        let count = element("assistant.pendingDraft.routingCount")
        reveal(count)
        XCTAssertEqual(count.label, "3 branches · 3 logical paths", file: file, line: line)
        assertPath(1, "\(osmose) → Main Speakers", file: file, line: line)
        assertPath(2, "\(solar) → \(evilPet) → Main Speakers", file: file, line: line)
        let policy = element("assistant.pendingDraft.branch.2.path.1.signalPolicy")
        reveal(policy)
        XCTAssertTrue(policy.label.contains("Processed-only (wet) · no parallel dry path"), file: file, line: line)
        assertPath(3, "OP-XY → Desk Speakers", file: file, line: line)
        let extraDryPath = element("assistant.pendingDraft.branch.2.path.2.source-to-destination")
        XCTAssertFalse(extraDryPath.exists, file: file, line: line)
    }

    private func assertPath(
        _ branch: Int, _ expected: String, path: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let summary = element("assistant.pendingDraft.branch.\(branch).path.\(path).source-to-destination")
        reveal(summary)
        XCTAssertEqual(summary.label, expected, file: file, line: line)
    }

    private func assertFixtureHasNotWritten(file: StaticString = #filePath, line: UInt = #line) {
        let mode = element("assistant.multiRoute.fixtureMode")
        reveal(mode)
        XCTAssertEqual(mode.label, "Demo fixture · no live WING transport", file: file, line: line)
        let count = element("assistant.multiRoute.transportWriteCount")
        reveal(count)
        XCTAssertEqual(count.label, "Transport SET attempts: 0", file: file, line: line)
    }

    private func assertCable(output: Int, destination: String, file: StaticString = #filePath, line: UInt = #line) {
        let cable = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "assistant.pendingDraft.cable.", "LCL \(output)", destination
        )).firstMatch
        reveal(cable)
        XCTAssertTrue(cable.exists, "Missing configured output cable for \(destination)", file: file, line: line)
    }

    private func assertConnection(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let connection = app.staticTexts[label]
        reveal(connection)
        XCTAssertTrue(connection.exists, "Missing local graph wire: \(label)", file: file, line: line)
    }

    private func assertWireCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let wires = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "studio.edge."
        ))
        XCTAssertEqual(wires.count, count, file: file, line: line)
    }

    private func assertNotSentYet(file: StaticString = #filePath, line: UInt = #line) {
        let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not sent yet")).firstMatch
        reveal(status)
        XCTAssertTrue(status.exists, file: file, line: line)
        XCTAssertEqual(app.buttons["studio.listenPrimary"].label, "Listen on WING", file: file, line: line)
    }

    private func waitForReviewToClose() {
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Review Studio Draft"]
        )
        wait(for: [closed], timeout: 10)
    }

    private func reveal(_ target: XCUIElement, upwards: Bool = true) {
        for _ in 0..<18 where !target.isHittable {
            // Pan at the outer margin, not inside the independently scrollable canvas.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upwards ? 0.78 : 0.25))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upwards ? 0.25 : 0.78))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable, "Expected readable on-screen content: \(target)")
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
