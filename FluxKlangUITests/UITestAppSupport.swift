import XCTest

@MainActor
func makeIsolatedUITestApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["FLUXKLANG_ISOLATED_TESTING"] = "1"
    app.launchEnvironment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] = "0"
    app.launchEnvironment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] = "0"
    return app
}
