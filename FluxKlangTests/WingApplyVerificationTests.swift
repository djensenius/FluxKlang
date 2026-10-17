import Testing
@testable import FluxKlang

struct WingApplyVerificationTests {
    @Test func reportsMissingAndMismatchedValuesAsPending() {
        let expected = [
            WingSetting(address: "/one", value: .int(1)),
            WingSetting(address: "/two", value: .float(0.25)),
            WingSetting(address: "/three", value: .string("BUS"))
        ]

        let pending = WingApplyVerifier.pendingSettings(
            expected: expected,
            confirmedValues: [
                "/one": .int(1),
                "/two": .float(0.5)
            ]
        )

        #expect(pending.map(\.address) == ["/two", "/three"])
    }

    @Test func acceptsSmallHardwareFloatRounding() {
        let expected = [WingSetting(address: "/fader", value: .float(0.25))]

        let result = WingApplyVerifier.result(
            expected: expected,
            confirmedValues: ["/fader": .float(0.2505)],
            sendFailed: false
        )

        #expect(result.state == .verified)
    }
}
