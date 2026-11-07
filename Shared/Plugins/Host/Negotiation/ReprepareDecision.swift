/// A live change the host observed while a plugin was prepared.
enum RenderLiveChange: String, CaseIterable, Sendable, Hashable {
    case maximumFrames
    case busLayout
    case format
    case sampleRate
    case latency
}

/// Where a `ReprepareLedger` is: rendering, waiting for an off-render prepare, or terminally silenced.
enum ReprepareStatus: String, CaseIterable, Sendable, Hashable {
    case rendering
    case preparing
    case silenced
}

/// Why a ledger went silent. One case today; the enum keeps `ReprepareDecision` closed and extensible.
enum ReprepareSilenceReason: Hashable, Sendable {
    case budgetExhausted(attempts: Int, maximum: Int)
}

/// What the owner must do after a change or a preparation result.
///
/// `keepRendering` is declared by the lane ruling but no transition produces it today (reserved).
enum ReprepareDecision: Hashable, Sendable {
    case keepRendering
    case invalidateDelayPlans
    case reprepare(attempt: Int)
    case resume
    case silence(ReprepareSilenceReason)
    case remainSilent
}

/// The ledger after a step together with the decision it produced (two members, never a tuple).
struct ReprepareTransition: Hashable, Sendable {
    let ledger: ReprepareLedger
    let decision: ReprepareDecision
}
