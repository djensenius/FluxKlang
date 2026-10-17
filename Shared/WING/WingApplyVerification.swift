import Foundation

enum WingApplyVerificationState: Hashable, Sendable {
    case verified
    case partiallyVerified
    case failed
}

struct WingApplyVerification: Hashable, Sendable {
    var state: WingApplyVerificationState
    var settings: [WingSetting]
    var confirmedCount: Int
    var details: String
}

enum WingApplyVerifier {
    static func pendingSettings(
        expected: [WingSetting],
        confirmedValues: [String: WingValue]
    ) -> [WingSetting] {
        expected.filter { setting in
            guard let confirmed = confirmedValues[setting.address] else { return true }
            return !matches(expected: setting.value, confirmed: confirmed)
        }
    }

    static func result(
        expected: [WingSetting],
        confirmedValues: [String: WingValue],
        sendFailed: Bool
    ) -> WingApplyVerification {
        let pending = pendingSettings(expected: expected, confirmedValues: confirmedValues)
        let confirmedCount = expected.count - pending.count
        let state: WingApplyVerificationState
        let details: String
        if sendFailed {
            state = .failed
            details = "The WING transport rejected one or more settings."
        } else if pending.isEmpty {
            state = .verified
            details = "All \(expected.count) settings were confirmed by the WING."
        } else {
            state = .partiallyVerified
            details = """
            \(confirmedCount) of \(expected.count) settings were confirmed; \(pending.count) remain unverified.
            """
        }
        return WingApplyVerification(
            state: state,
            settings: expected,
            confirmedCount: confirmedCount,
            details: details
        )
    }

    private static func matches(expected: WingValue, confirmed: WingValue) -> Bool {
        switch (expected, confirmed) {
        case let (.float(expectedValue), .float(confirmedValue)):
            return abs(expectedValue - confirmedValue) <= 0.001
        default:
            return expected == confirmed
        }
    }
}
