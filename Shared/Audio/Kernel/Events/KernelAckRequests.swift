// #64 E5b acknowledgement-request epoch: control's explicit request that render report a faulted cycle begun after
// control's `FaultLatch.observe`, so a stale telemetry sample can only delay an acknowledgement, never approve one.
// Reference model; not RT-certified.

import Synchronization

/// An acknowledgement request: the epoch control published after its `observe`, bound to the identity of the
/// `KernelAckRequests` (so the `KernelCycle`) that issued it and to the `FaultObservation` it was requested for.
/// Only `KernelAckRequests.request(for:)` makes one, and only for an observation of its cycle's own latch and
/// critical scope. `~Copyable`: `KernelCycle.acknowledgeCritical` consumes it,
/// so one ticket can never be presented twice, and that call refuses it for any other observation (a re-raise
/// after the request makes a new observation, which needs a new request). Reference model; not RT-certified.
struct KernelAckTicket: ~Copyable, Sendable {
    /// The issuing `KernelAckRequests.identity`; a sample from any other cycle never approves this ticket.
    let cycle: UInt64
    let epoch: UInt64
    /// The observation's scope, `FaultObservation.tally` and `FaultObservation.epoch`: the words
    /// `FaultLatch.acknowledge` compares, so equal words mean the same latched state.
    let scope: FaultScope
    let observedTally: UInt64
    let observedEpoch: UInt64

    fileprivate init(cycle: UInt64, epoch: UInt64, for observation: FaultObservation) {
        self.cycle = cycle
        self.epoch = epoch
        scope = observation.record.scope
        observedTally = observation.tally
        observedEpoch = observation.epoch
    }

    /// `true` when this ticket was requested for `observation` (the same scope and latched state).
    func isBound(to observation: FaultObservation) -> Bool {
        scope == observation.record.scope && observedTally == observation.tally
            && observedEpoch == observation.epoch
    }
}

/// Issues each `KernelAckRequests` a distinct identity, starting at 1 and never reused or wrapped.
private let ackRequestIdentities = Atomic<UInt64>(0)

/// The acknowledgement-request epoch of one `KernelCycle`: a single atomic word, allocated in `init`.
///
/// Happens-before chain (sequential argument; the formal model-check of this handshake is tracked in #190):
/// 1. control: a raise reaches `FaultLatch.observe`, then `request(for:)` increments the epoch with a releasing
///    compare-exchange, publishing epoch `e`;
/// 2. render: `loadForRender()` acquire-loads the epoch at the start of `KernelCycle.run`, before
///    `FaultLatch.isLatched`; reading `e` or later makes the raise (and every push before it) visible to that
///    load and to the cycle's drain;
/// 3. render: a cycle that then reads the scope latched arms the flush watermark, drains, and publishes
///    `KernelCycleTelemetry.lastFaultedAckEpoch` = the epoch it loaded through `TelemetrySlots.publish` (release);
/// 4. control: a `TelemetrySlots.latest` read (acquire) showing `lastFaultedAckEpoch >= e` lets it acknowledge.
/// A sample published before step 2 carries an older epoch, so a stale cached sample cannot approve a newer
/// request. Every update is a compare-exchange (a read-modify-write), so a later epoch continues `e`'s release
/// sequence for several requesters. Reference model; not RT-certified.
final class KernelAckRequests: Sendable {
    enum RequestError: Error, Equatable, Sendable {
        /// `UInt64.max` epochs were requested; the epoch never wraps, so no acknowledgement can be requested again
        /// until the cycle is replaced while quiescent.
        case epochExhausted
        /// The observation is not of this cycle's `FaultLatch` (`FaultObservation.isObservation(of:)`) or not of its
        /// critical scope. Checked before the epoch moves, so nothing changes.
        case foreignObservation
    }

    /// This instance's process-unique identity (never 0). `KernelCycle` publishes it with every sample as
    /// `KernelCycleTelemetry.ackCycle`, so a replacement cycle on the same telemetry slots, whose epochs restart
    /// at 0, cannot approve a ticket of the cycle it replaced.
    let identity: UInt64
    private let epoch: Atomic<UInt64>
    /// The cycle's latch and critical scope: `request(for:)` accepts only their observations. Control-side only;
    /// render never touches them.
    private let faults: FaultLatch
    private let criticalScope: FaultScope

    /// Control-side preparation for `faults`' `criticalScope`, with no epoch requested yet; `nil` once every
    /// identity was issued.
    convenience init?(faults: FaultLatch, criticalScope: FaultScope) {
        self.init(faults: faults, criticalScope: criticalScope, lastRequestedForTesting: 0)
    }

    /// Test-only (SwiftLint source policy, not compiler isolation): seeds the epoch at `lastRequestedForTesting`,
    /// for exhaustion tests. Production prepares through `init(faults:criticalScope:)`. `nil` once every identity
    /// was issued.
    init?(faults: FaultLatch, criticalScope: FaultScope, lastRequestedForTesting lastRequested: UInt64) {
        var current = ackRequestIdentities.load(ordering: .relaxed)
        var issued: UInt64?
        while issued == nil, current < .max {
            let (exchanged, original) = ackRequestIdentities.compareExchange(
                expected: current, desired: current &+ 1, ordering: .relaxed)
            if exchanged { issued = current &+ 1 } else { current = original }
        }
        guard let issued else { return nil }
        identity = issued
        epoch = Atomic(lastRequested)
        self.faults = faults
        self.criticalScope = criticalScope
    }

    /// The last epoch requested, or 0 before the first. Any thread; diagnostic only, carries no ordering.
    var lastRequested: UInt64 { epoch.load(ordering: .relaxed) }

    /// Control only, with the `observation` this request is for (so after `FaultLatch.observe`). Publishes the next
    /// epoch with a releasing compare-exchange and returns it bound to `observation`; refuses another latch's or
    /// scope's observation, and (never wraps) once `UInt64.max` was requested, changing nothing. Lock-free,
    /// allocation-free; retries only when another requester raced it.
    func request(for observation: FaultObservation) throws(RequestError) -> KernelAckTicket {
        guard observation.isObservation(of: faults), observation.record.scope == criticalScope else {
            throw .foreignObservation
        }
        var current = epoch.load(ordering: .relaxed)
        while current < .max {
            let (exchanged, original) = epoch.compareExchange(
                expected: current, desired: current &+ 1, successOrdering: .releasing, failureOrdering: .relaxed)
            if exchanged { return KernelAckTicket(cycle: identity, epoch: current &+ 1, for: observation) }
            current = original
        }
        throw .epochExhausted
    }

    /// Render only, first in `KernelCycle.run`: the latest requested epoch, acquire-loaded before the latch.
    func loadForRender() -> UInt64 {
        epoch.load(ordering: .acquiring)
    }
}
