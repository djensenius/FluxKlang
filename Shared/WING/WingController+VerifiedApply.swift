import Foundation

extension WingController {
    /// Applies a batch in a paced, verified transaction. Safety settings are
    /// confirmed before any remaining routing is sent.
    func applyAndVerify(
        _ settings: [WingSetting],
        safetySettings: [WingSetting] = []
    ) async -> WingApplyVerification {
        let expected = uniqueSettings(settings)
        let safety = uniqueSettings(safetySettings).filter(expected.contains)
        let safetyAddresses = Set(safety.map(\.address))
        let remaining = expected.filter { !safetyAddresses.contains($0.address) }

        var sendFailed = !(await applyPaced(safety))
        if !safety.isEmpty {
            let safetyResult = await verifyAndRetry(safety, sendFailed: sendFailed)
            guard safetyResult.state == .verified else {
                return WingApplyVerification(
                    state: .failed,
                    settings: expected,
                    confirmedCount: safetyResult.confirmedCount,
                    details: "Safe endpoint levels could not be confirmed. Routing was not sent."
                )
            }
        }

        sendFailed = !(await applyPaced(remaining)) || sendFailed
        return await verifyAndRetry(expected, sendFailed: sendFailed)
    }

    private func applyPaced(_ settings: [WingSetting]) async -> Bool {
        var succeeded = true
        for setting in settings {
            if Task.isCancelled { return false }
            succeeded = await apply([setting]) && succeeded
            try? await Task.sleep(for: WingNetwork.applyWriteDelay)
        }
        return succeeded
    }

    private func verifyAndRetry(
        _ expected: [WingSetting],
        sendFailed: Bool
    ) async -> WingApplyVerification {
        await refreshForVerification(expected.map(\.address))
        try? await Task.sleep(for: WingNetwork.applyVerificationDelay)
        let pending = WingApplyVerifier.pendingSettings(
            expected: expected,
            confirmedValues: confirmedValues
        )
        var retryFailed = false
        if !pending.isEmpty {
            retryFailed = !(await applyPaced(pending))
            await refreshForVerification(pending.map(\.address))
            try? await Task.sleep(for: WingNetwork.applyVerificationDelay)
        }
        return WingApplyVerifier.result(
            expected: expected,
            confirmedValues: confirmedValues,
            sendFailed: sendFailed || retryFailed
        )
    }

    private func uniqueSettings(_ settings: [WingSetting]) -> [WingSetting] {
        var latest: [String: WingSetting] = [:]
        var order: [String] = []
        for setting in settings {
            if latest[setting.address] == nil {
                order.append(setting.address)
            }
            latest[setting.address] = setting
        }
        return order.compactMap { latest[$0] }
    }
}
