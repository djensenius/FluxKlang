import XCTest

@MainActor
func makeIsolatedUITestApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["FLUXKLANG_ISOLATED_TESTING"] = "1"
    app.launchEnvironment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] = "0"
    app.launchEnvironment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] = "0"
    return app
}

@MainActor
func launchIsolatedUITestApplication(
    _ app: XCUIApplication,
    testCase: XCTestCase,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    testCase.continueAfterFailure = false
    app.launch()
    let element = app.descendants(matching: .any)
        .matching(identifier: "startup.isolation.observation").firstMatch
    guard element.waitForExistence(timeout: 10) else {
        XCTFail("Missing app-side startup observation", file: file, line: line)
        return
    }
    guard let initial = decodeStartupObservation(element, file: file, line: line) else { return }
    assertConstruction(initial.construction, file: file, line: line)
    if initial.rootAwaitedWork == nil {
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "\"rootAwaitedWork\":"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [returned], timeout: 10), .completed,
            "The root's awaited work did not return", file: file, line: line
        )
    }
    guard let completed = decodeStartupObservation(element, file: file, line: line) else { return }
    XCTAssertEqual(completed.construction, initial.construction, file: file, line: line)
    guard let rootWork = completed.rootAwaitedWork else {
        XCTFail("Missing post-await root observation", file: file, line: line)
        return
    }
    XCTAssertFalse(rootWork.cancelled, "The observed root task was cancelled", file: file, line: line)
    assertForbiddenCounts(
        rootWork.counts, operationCount: initial.construction.operationCount, file: file, line: line
    )
}

private struct UITestStartupObservation: Decodable {
    struct Counts: Decodable, Equatable {
        let operation: Int
        let factoryEvaluated: UInt64
        let apiEntered: UInt64
    }

    struct Construction: Decodable, Equatable {
        let environment: [String: String]?
        let checkpointPresent: Bool
        let operationCount: Int
        let before: [Counts]?
        let after: [Counts]?
    }

    struct RootWork: Decodable {
        let cancelled: Bool
        let counts: [Counts]
    }

    let construction: Construction
    let rootAwaitedWork: RootWork?
}

@MainActor
private func decodeStartupObservation(
    _ element: XCUIElement, file: StaticString, line: UInt
) -> UITestStartupObservation? {
    guard let value = element.value as? String,
          let data = value.data(using: .utf8),
          let observation = try? JSONDecoder().decode(UITestStartupObservation.self, from: data) else {
        XCTFail("Malformed app-side startup observation", file: file, line: line)
        return nil
    }
    return observation
}

private func assertConstruction(
    _ observation: UITestStartupObservation.Construction, file: StaticString, line: UInt
) {
    XCTAssertTrue(observation.checkpointPresent, "Shared construction was absent", file: file, line: line)
    XCTAssertEqual(observation.environment, [
        "FLUXKLANG_ISOLATED_TESTING": "1",
        "FLUXKLANG_QUALIFY_APPLE_ROUTING": "0",
        "FLUXKLANG_RUN_APPLE_MODEL_TESTS": "0"
    ], file: file, line: line)
    guard let before = observation.before, let after = observation.after else {
        XCTFail("Missing construction checkpoint counts", file: file, line: line)
        return
    }
    assertForbiddenCounts(before, operationCount: observation.operationCount, file: file, line: line)
    assertForbiddenCounts(after, operationCount: observation.operationCount, file: file, line: line)
}

private func assertForbiddenCounts(
    _ counts: [UITestStartupObservation.Counts], operationCount: Int, file: StaticString, line: UInt
) {
    guard operationCount > 0, counts.count == operationCount else {
        XCTFail("Missing or invalid audit operation counts", file: file, line: line)
        return
    }
    XCTAssertEqual(Set(counts.map(\.operation)), Set(0..<operationCount), file: file, line: line)
    for count in counts {
        XCTAssertEqual(count.factoryEvaluated, 0, "Factory operation \(count.operation)", file: file, line: line)
        XCTAssertEqual(count.apiEntered, 0, "API operation \(count.operation)", file: file, line: line)
    }
}
