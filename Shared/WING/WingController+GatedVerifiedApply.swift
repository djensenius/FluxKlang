import Foundation

/// The send phases of a grant-gated `applyAndVerify` (#62 AU6), in order: the
/// safety send and its retry, then the remaining send and the final retry.
enum WingDirectApplyPhase: Hashable, Sendable, CaseIterable {
    case safety
    case safetyRetry
    case remaining
    case retry
}

/// A gated apply's unique settings, the safety ones among them, and the rest.
struct WingDirectApplyPlan {
    let expected: [WingSetting]
    let safety: [WingSetting]
    let remaining: [WingSetting]
}

/// Mints one direct-send grant for one chunk of at most
/// `HostAuthority.directSendBatchLimit` targets of an apply phase, bound to
/// exactly `targets`, so a phase mints once per chunk. The controller cannot
/// admit commands itself; the composition root does. Each call spends its own
/// ticket, refused or not.
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
    /// pacing and verdicts, but each send phase mints a fresh grant per chunk of at
    /// most `HostAuthority.directSendBatchLimit` addresses, just before sending that
    /// chunk, and spends it before the next chunk mints or verification starts. A
    /// phase with nothing to send mints nothing. A refused mint sends nothing more
    /// in that phase or any later one, and the verdict is `.failed`. A WING session
    /// that changed during the apply fails it with `confirmedCount` 0.
    func applyAndVerify(
        _ settings: [WingSetting],
        safetySettings: [WingSetting] = [],
        session: UUID,
        minting: some WingDirectGrantMinting
    ) async -> WingApplyVerification {
        let plan = directApplyPlan(settings, safetySettings: safetySettings)
        let (expected, safety, remaining) = (plan.expected, plan.safety, plan.remaining)

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

    /// The settings of a gated apply: every unique setting, the safety ones among
    /// them, and the rest, which are sent only once the safety ones verify.
    func directApplyPlan(_ settings: [WingSetting], safetySettings: [WingSetting]) -> WingDirectApplyPlan {
        let expected = uniqueSettings(settings)
        let safety = uniqueSettings(safetySettings).filter(expected.contains)
        let safetyAddresses = Set(safety.map(\.address))
        let remaining = expected.filter { !safetyAddresses.contains($0.address) }
        return WingDirectApplyPlan(expected: expected, safety: safety, remaining: remaining)
    }

    /// Verifies `expected`, then retries what is still pending in `retry`. A
    /// session that changed during either verification delay fails with
    /// `confirmedCount` 0, before the retry mints or the verdict is computed, since
    /// another session's replies do not confirm this apply.
    private func verifyAndRetryDirect(
        _ expected: [WingSetting],
        sendFailed: Bool,
        retry: WingDirectApplyPhase,
        session: UUID,
        minting: some WingDirectGrantMinting
    ) async -> WingApplyVerification {
        await refreshForVerification(expected.map(\.address))
        try? await Task.sleep(for: WingNetwork.applyVerificationDelay)
        guard sessionID == session else { return directSessionChanged(expected) }
        var retried: [String] = []
        let sent = await sendDirectPhase(retry, session: session, minting: minting) {
            WingApplyVerifier.pendingSettings(expected: expected, confirmedValues: confirmedValues)
        } didSend: { retried += $0.map(\.address) }
        guard sent != .refused else { return directRefusal(expected) }
        if !retried.isEmpty {
            await refreshForVerification(retried)
            try? await Task.sleep(for: WingNetwork.applyVerificationDelay)
        }
        guard sessionID == session else { return directSessionChanged(expected) }
        return WingApplyVerifier.result(
            expected: expected,
            confirmedValues: confirmedValues,
            sendFailed: sendFailed || sent == .failed
        )
    }

    /// One gated, paced phase. `pending` is read once and split, in order, into
    /// consecutive chunks of at most `HostAuthority.directSendBatchLimit`, the most
    /// one grant may bind. Each chunk mints its own grant, then re-reads `pending`,
    /// since confirmations can arrive meanwhile; only settings of that chunk still
    /// pending are sent, and `didSend` receives them. Writes are paced across
    /// chunks. Each chunk's grant is relinquished before the next chunk mints, so at
    /// most one is armed and none stays armed once the phase returns. Stops at a
    /// refused mint or the first failed entry; no later chunk mints.
    private func sendDirectPhase(
        _ phase: WingDirectApplyPhase,
        session: UUID,
        minting: some WingDirectGrantMinting,
        pending: () -> [WingSetting],
        didSend: ([WingSetting]) -> Void = { _ in }
    ) async -> DirectPhaseOutcome {
        let planned = pending()
        let limit = HostAuthority.directSendBatchLimit
        var paced = false
        for start in stride(from: 0, to: planned.count, by: limit) {
            let chunk = planned[start..<min(start + limit, planned.count)]
            let minted = await minting.grant(for: phase, targets: chunk.map { DirectSendTarget($0.address) })
            guard case .success(let grant) = minted else { return .refused }
            defer { grant.relinquish() }
            let bound = Set(chunk.map(\.address))
            let settings = pending().filter { bound.contains($0.address) }
            didSend(settings)
            for setting in settings {
                if paced { try? await Task.sleep(for: WingNetwork.applyWriteDelay) }
                paced = true
                guard await sendDirectEntry(setting, session: session, authorization: grant) else { return .failed }
            }
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

    /// Replies from a replacement session do not confirm this apply.
    private func directSessionChanged(_ expected: [WingSetting]) -> WingApplyVerification {
        WingApplyVerification(
            state: .failed,
            settings: expected,
            confirmedCount: 0,
            details: "The WING session changed during the apply. Nothing was confirmed."
        )
    }
}
