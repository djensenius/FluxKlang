//
//  LatencyChangePolicy.swift
//  FluxKlang
//
//  What to do when a plugin reports a new latency while rendering (#78, slice PLG6).
//  Variable latency is NOT rejected: any new latency inside its range is accepted, and
//  the only consequence is that delay plans must be rebuilt when the value changed.
//  A pure function of three numbers: no clock, no scan, no plugin load.
//

enum LatencyDecision: Equatable, Sendable {
    /// The new latency is in range. `invalidateDelayPlans` is true exactly when it differs from
    /// the previous one; an unchanged latency is accepted without invalidating anything.
    case accept(invalidateDelayPlans: Bool)
    case refuse(LatencyChangeRefusal)
}

enum LatencyChangePolicy {
    /// All three numbers are frames and all are required (the policy keeps no state of its own).
    /// Checked in this order: `framesBound` in `1...RenderNegotiationLimits.maximumFrames`,
    /// `previous` in `0...RenderNegotiationLimits.maximumFrames` (the global cap, not
    /// `framesBound`, because the bound may have shrunk since the previous latency was valid),
    /// then `next` in `0...framesBound`.
    ///
    /// For a latency that changed, `accept(invalidateDelayPlans: true)` is the same outcome as
    /// `ReprepareLedger.observing(.latency)`, which is never told the values and always answers
    /// `.invalidateDelayPlans` without re-preparing or silencing.
    static func decide(previous: Int, next: Int, framesBound: Int) -> LatencyDecision {
        guard (1...RenderNegotiationLimits.maximumFrames).contains(framesBound) else {
            return .refuse(.invalidBound(framesBound))
        }
        guard (0...RenderNegotiationLimits.maximumFrames).contains(previous) else {
            return .refuse(.previousOutOfRange(previous))
        }
        guard (0...framesBound).contains(next) else {
            return .refuse(.outOfRange(next: next, bound: framesBound))
        }
        return .accept(invalidateDelayPlans: next != previous)
    }
}
