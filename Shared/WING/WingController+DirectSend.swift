import Foundation

/// What a grant-gated batch did, in the caller's order: `sent + [failed] + unsent`
/// is the batch. `failed` is the entry the controller or the transport refused.
struct DirectApplyOutcome: Equatable, Sendable {
    var sent: [WingSetting] = []
    var failed: WingSetting?
    var unsent: [WingSetting] = []
}

extension WingController {
    /// Grant-gated batch SET (#62 AU4; no app callers yet). Sends `settings` in
    /// order, one `sendDirectEntry` (one lock hold, one transport hop) each, so a
    /// revocation waits for at most one entry. Every entry re-checks the session and
    /// cancellation. Stops at the first refusal or failure, then always
    /// `relinquish`es the grant, so every call spends it. `authorization` must bind
    /// every setting's address; an unbound or repeated one is refused by the grant
    /// and revokes the rest. No pacing, verification or retry (see `applyAndVerify`).
    func applyDirect(_ settings: [WingSetting], session: UUID,
                     authorization: DirectWriteAuthorization) async -> DirectApplyOutcome {
        var outcome = DirectApplyOutcome()
        for (index, setting) in settings.enumerated() {
            guard await sendDirectEntry(setting, session: session, authorization: authorization) else {
                outcome.failed = setting
                outcome.unsent = Array(settings[(index + 1)...])
                break
            }
            outcome.sent.append(setting)
        }
        authorization.relinquish()
        return outcome
    }
}
