import Foundation

/// The send phases of a grant-gated `applyAndVerify` (#62 AU6), in order: the
/// safety send and its retry, then the remaining send and the final retry.
enum WingDirectApplyPhase: Hashable, Sendable, CaseIterable {
    case safety
    case safetyRetry
    case remaining
    case retry
}

/// Mints one direct-send grant for one apply phase, bound to exactly `targets`.
/// The controller cannot admit commands itself; the composition root does. Each
/// call spends its own ticket, refused or not.
protocol WingDirectGrantMinting: Sendable {
    func grant(for phase: WingDirectApplyPhase,
               targets: [DirectSendTarget]) async -> Result<DirectWriteAuthorization, DirectWriteRefusal>
}

/// What one gated phase did: every entry sent, stopped at a failed entry, or the
/// mint was refused and nothing was sent.
private enum DirectPhaseOutcome {
    case sent
    case failed
    case refused
}

extension WingController {
    /// Grant-gated `applyAndVerify` (#62 AU6; no app callers yet). Same phases,
    /// pacing and verdicts, but each send phase mints a fresh grant just before it
    /// sends, binding only that phase's addresses, and spends it before verifying.
    /// A phase with nothing to send mints nothing. A refused mint sends nothing in
    /// that phase or any later one, and the verdict is `.failed`.
    func applyAndVerify(
        _ settings: [WingSetting],
        safetySettings: [WingSetting] = [],
        session: UUID,
        minting: some WingDirectGrantMinting
    ) async -> WingApplyVerification {
        let expected = uniqueSettings(settings)
        let safety = uniqueSettings(safetySettings).filter(expected.contains)
        let safetyAddresses = Set(safety.map(\.address))
        let remaining = expected.filter { !safetyAddresses.contains($0.address) }

        if !safety.isEmpty {
            let sent = await sendDirectPhase(.safety, session: session, minting: minting) { safety }
            let safetyResult = sent == .refused ? nil : await verifyAndRetryDirect(
                safety, sendFailed: sent == .failed, retry: .safetyRetry, session: session, minting: minting
            )
            guard let safetyResult, safetyResult.state == .verified else {
                return WingApplyVerification(
                    state: .failed,
                    settings: expected,
                    confirmedCount: safetyResult?.confirmedCount ?? 0,
                    details: "Safe endpoint levels could not be confirmed. Routing was not sent."
                )
            }
        }

        let sent = await sendDirectPhase(.remaining, session: session, minting: minting) { remaining }
        guard sent != .refused else { return directRefusal(expected) }
        return await verifyAndRetryDirect(
            expected, sendFailed: sent == .failed, retry: .retry, session: session, minting: minting
        )
    }

    private func verifyAndRetryDirect(
        _ expected: [WingSetting],
        sendFailed: Bool,
        retry: WingDirectApplyPhase,
        session: UUID,
        minting: some WingDirectGrantMinting
    ) async -> WingApplyVerification {
        await refreshForVerification(expected.map(\.address))
        try? await Task.sleep(for: WingNetwork.applyVerificationDelay)
        var retried: [String] = []
        let sent = await sendDirectPhase(retry, session: session, minting: minting) {
            WingApplyVerifier.pendingSettings(expected: expected, confirmedValues: confirmedValues)
        } didSend: { retried = $0.map(\.address) }
        guard sent != .refused else { return directRefusal(expected) }
        if !retried.isEmpty {
            await refreshForVerification(retried)
            try? await Task.sleep(for: WingNetwork.applyVerificationDelay)
        }
        return WingApplyVerifier.result(
            expected: expected,
            confirmedValues: confirmedValues,
            sendFailed: sendFailed || sent == .failed
        )
    }

    /// One gated, paced phase. `pending` is read once to bind the grant and again
    /// after the mint, since confirmations can arrive meanwhile; only bound
    /// settings still pending are sent, and `didSend` receives them. Stops at the
    /// first failed entry and always relinquishes the grant, so none stays armed
    /// once the phase returns.
    private func sendDirectPhase(
        _ phase: WingDirectApplyPhase,
        session: UUID,
        minting: some WingDirectGrantMinting,
        pending: () -> [WingSetting],
        didSend: ([WingSetting]) -> Void = { _ in }
    ) async -> DirectPhaseOutcome {
        let planned = pending()
        guard !planned.isEmpty else { return .sent }
        let minted = await minting.grant(for: phase, targets: planned.map { DirectSendTarget($0.address) })
        guard case .success(let grant) = minted else { return .refused }
        defer { grant.relinquish() }
        let bound = Set(planned.map(\.address))
        let settings = pending().filter { bound.contains($0.address) }
        didSend(settings)
        for (index, setting) in settings.enumerated() {
            if index > 0 { try? await Task.sleep(for: WingNetwork.applyWriteDelay) }
            guard await sendDirectEntry(setting, session: session, authorization: grant) else { return .failed }
        }
        return .sent
    }

    /// A refused mint confirms nothing: cached values were not verified by this apply.
    private func directRefusal(_ expected: [WingSetting]) -> WingApplyVerification {
        WingApplyVerification(
            state: .failed,
            settings: expected,
            confirmedCount: 0,
            details: "The host did not authorize the WING write. Nothing more was sent."
        )
    }
}
