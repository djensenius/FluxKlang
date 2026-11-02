import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct AppPersistenceSelectionTests {
    @Test func strictIsolationNeedsNoHostMarkerOrUIArgument() {
        #expect(!AppPersistence.detectsTesting(environment: [:], arguments: []))
        #expect(AppPersistence.detectsTesting(
            environment: ["FLUXKLANG_ISOLATED_TESTING": "1"], arguments: []))
    }

    @Test(arguments: ["", "0", "true", "01"])
    func otherStrictFlagValuesDoNotEnableTesting(_ value: String) {
        #expect(!AppPersistence.detectsTesting(
            environment: ["FLUXKLANG_ISOLATED_TESTING": value], arguments: []))
    }

    @Test func nonEnablingStrictFlagDoesNotDisableXCTestDetection() {
        #expect(AppPersistence.detectsTesting(
            environment: ["XCTestConfigurationFilePath": ""], arguments: []))
        #expect(AppPersistence.detectsTesting(
            environment: ["FLUXKLANG_ISOLATED_TESTING": "0", "XCTestConfigurationFilePath": ""], arguments: []))
    }

    @Test func uiTestingArgumentRemainsDebugOnly() {
        let selected = AppPersistence.detectsTesting(environment: [:], arguments: ["FluxKlang", "-ui-testing"])
        #if DEBUG
        #expect(selected)
        #else
        #expect(!selected)
        #endif
    }
}
