/// The send phases of a grant-gated `applyAndVerify` (#62 AU6), in order: the
/// safety send and its retry, then the remaining send and the final retry.
enum WingDirectApplyPhase: Hashable, Sendable, CaseIterable {
    case safety
    case safetyRetry
    case remaining
    case retry
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
