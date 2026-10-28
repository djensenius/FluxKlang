import XCTest

@MainActor
final class StudioCanvasUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    func testBlankCanvasPansToControlsAndLastAddedNodeCanBeRemoved() {
        launchPatch()
        showActions()
        for _ in 0..<12 {
            app.buttons["studio.addControl"].tap()
            app.buttons["Mix Control"].tap()
        }

        showCanvas()
        let canvas = element("studio.canvas")
        panToControls(canvas)
        let lastNode = app.buttons["Remove Mix Control 13 from patch"]
        for _ in 0..<12 where !lastNode.isHittable {
            // Start in the blank gutter, not on any node's move/output handle.
            swipe(canvas, from: CGVector(dx: 0.06, dy: 0.85), to: CGVector(dx: 0.06, dy: 0.2))
        }
        XCTAssertTrue(lastNode.isHittable, "The complete last card must be reachable beyond the old 900pt extent")
        XCTAssertGreaterThanOrEqual(lastNode.frame.width, 44)
        XCTAssertGreaterThanOrEqual(lastNode.frame.height, 44)
        lastNode.tap()
        XCTAssertFalse(lastNode.exists)
    }

    func testDeleteWhileRoutingDeletesConnectedNodeInsteadOfDrawingAnotherEdge() {
        launchPatch()
        showCanvas()
        let draw = app.buttons["Draw connection from OP-1 Field"]
        XCTAssertTrue(draw.isHittable)
        XCTAssertGreaterThanOrEqual(draw.frame.width, 44)
        XCTAssertGreaterThanOrEqual(draw.frame.height, 44)
        draw.tap()
        XCTAssertTrue(app.buttons["Cancel connection"].exists)
        app.buttons["Remove OP-1 Field from patch"].tap()

        XCTAssertFalse(app.buttons["Remove OP-1 Field from patch"].exists)
        XCTAssertFalse(app.buttons["Cancel connection"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "studio.edge.")
        ).count, 0, "Deleting a connected node must also remove its edges")

        showActions()
        app.buttons["studio.addGear"].tap()
        XCTAssertTrue(app.buttons["OP-1 Field"].exists, "Removing from the patch must not delete library gear")
    }

    func testRerouteCanFinishWithHereAfterHorizontalCanvasScroll() {
        launchPatch()
        showActions()
        let reroute = app.buttons["Reroute"].firstMatch
        XCTAssertTrue(reroute.isHittable)
        reroute.tap()
        showCanvas()
        panToControls(element("studio.canvas"))
        let here = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connect to ")).firstMatch
        XCTAssertTrue(here.isHittable)
        XCTAssertGreaterThanOrEqual(here.frame.width, 44)
        XCTAssertGreaterThanOrEqual(here.frame.height, 44)
        here.tap()
        XCTAssertFalse(app.buttons["Cancel connection"].exists)
        showActions()
        XCTAssertTrue(app.buttons["Reroute"].firstMatch.exists)
    }

    func testMoveHandlePersistsAndBlankTapCancelsRouting() {
        launchPatch()
        showCanvas()
        let canvas = element("studio.canvas")
        let move = elementWithLabel("Move OP-1 Field")
        XCTAssertTrue(move.isHittable)
        let original = move.frame
        let start = move.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 24, dy: 80)))
        XCTAssertEqual(move.frame.midX - original.midX, 24, accuracy: 5)
        XCTAssertEqual(move.frame.midY - original.midY, 80, accuracy: 5)
        let movedOffset = move.frame.midY - canvas.frame.minY

        app.tabBars.buttons["Assistant"].tap()
        app.tabBars.buttons["Studio"].tap()
        showCanvas()
        XCTAssertEqual(move.frame.midY - canvas.frame.minY, movedOffset, accuracy: 5)
        app.buttons["Draw connection from OP-1 Field"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertFalse(app.buttons["Cancel connection"].exists)
        XCTAssertTrue(app.buttons["Draw connection from OP-1 Field"].exists)
    }

    func testActionsKeepFullLabelsAtDefaultAndAccessibilitySizes() {
        for accessibilitySize in [false, true] {
            launchPatch(accessibilitySize: accessibilitySize)
            showActions()
            for (identifier, title) in [
                ("studio.addGear", "Add Gear"),
                ("studio.newGear", "New Gear"),
                ("studio.addControl", "Add Control"),
                ("studio.connectNodes", "Connect Nodes")
            ] {
                let button = app.buttons[identifier]
                revealOnPage(button)
                XCTAssertTrue(button.isHittable)
                XCTAssertTrue(button.label.contains(title))
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                XCTAssertGreaterThanOrEqual(button.frame.width, 160, "Actions must not become fragment columns")
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = accessibilitySize ? "Studio actions AX XXXL" : "Studio actions default"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func launchPatch(accessibilitySize: Bool = false) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-ui-testing", "-ui-test-force-fallback", "-ui-test-seed-acceptance", "-ui-test-demo"
        ]
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let review = app.buttons["assistant.pendingDraft.review"]
        _ = review.waitForExistence(timeout: 10)
        revealOnPage(review)
        review.tap()
        let accept = app.buttons["assistant.pendingDraft.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: accept)
        wait(for: [enabled], timeout: 10)
        accept.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: accept)
        wait(for: [dismissed], timeout: 10)
        revealOnPage(element("studio.canvas"))
    }

    private func showActions() {
        revealOnPage(app.buttons["studio.addGear"])
    }

    private func revealOnPage(_ target: XCUIElement) {
        for _ in 0..<12 where !target.isHittable {
            swipePage(upward: true)
        }
        XCTAssertTrue(target.isHittable)
    }

    private func showCanvas() {
        let canvas = element("studio.canvas")
        let top = max(app.navigationBars.firstMatch.frame.maxY, app.buttons["connection.status"].frame.maxY) + 12
        for _ in 0..<12 {
            let distance = top - canvas.frame.minY
            if abs(distance) < 12 { break }
            let step = min(abs(distance), 180) * (distance < 0 ? -1.0 : 1.0)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: 6, dy: app.frame.midY)
            )
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: step)),
                withVelocity: .slow,
                thenHoldForDuration: 0.1
            )
        }
        XCTAssertTrue(canvas.isHittable)
    }

    private func panToControls(_ canvas: XCUIElement) {
        for _ in 0..<5 {
            swipe(canvas, from: CGVector(dx: 0.85, dy: 0.85), to: CGVector(dx: 0.15, dy: 0.85))
        }
    }

    private func swipePage(upward: Bool) {
        // The outer page's padding is outside the nested canvas ScrollView.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: upward ? 0.75 : 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: upward ? 0.3 : 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func swipe(_ view: XCUIElement, from start: CGVector, to end: CGVector) {
        view.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: view.coordinate(withNormalizedOffset: end)
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elementWithLabel(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
