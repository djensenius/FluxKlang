//
//  MIDIClockTempoProposer.swift
//  FluxKlang
//
//  Rate-limited, deterministic external-tempo proposals. A proposal is advice:
//  the transport decides whether to apply it; nothing here writes a tempo map.
//  Pulse indices must not decrease within one transport generation; feed the
//  follower's events to `observe(_:)` so a restart or locate starts a new one.
//

/// A tempo the transport may adopt from `atTicks`, bumping `musicalMap` for `externalTempo`.
struct ExternalTempoProposal: Equatable, Sendable {
    let microsPerQuarter: Int64
    let atTicks: Int64

    var bumpReason: GenerationBumpReason { .externalTempo }

    func segment() throws -> TempoSegment {
        try TempoSegment(atTicks: atTicks, microsPerQuarter: microsPerQuarter)
    }
}

struct MIDIClockTempoProposer: Sendable {
    /// At most one proposal per this many pulses (one quarter).
    static let minimumPulsesBetweenProposals: Int64 = 24
    /// Changes below 1/1,000 of the last proposed tempo are suppressed.
    static let deadbandDivisor: Int64 = 1_000

    private struct Proposed: Sendable {
        let proposal: ExternalTempoProposal
        let pulseIndex: Int64
    }

    private var proposed: Proposed?
    private var lastOfferPulse: Int64?

    var lastProposal: ExternalTempoProposal? { proposed?.proposal }

    init() {}

    /// Starts a new transport generation when the follower restarted or located
    /// (any event with a `transportRestart` or `locate` bump reason).
    mutating func observe(_ event: MIDIClockFollowerEvent) {
        switch event.bumpReason {
        case .transportRestart?, .locate?: reset()
        default: break
        }
    }

    /// Forgets the pulse baseline and the last proposal; the next offer proposes.
    mutating func reset() {
        proposed = nil
        lastOfferPulse = nil
    }

    /// Offers the estimate measured at pulse `pulseIndex` (tick `atTicks`). Within one
    /// transport generation pulse indices never go back.
    mutating func offer(_ estimate: MIDIClockTempoEstimate, atTicks: Int64,
                        pulseIndex: Int64) throws(MIDIClockError) -> ExternalTempoProposal? {
        guard MIDIClockMath.microsPerQuarterRange.contains(estimate.microsPerQuarter) else {
            throw .tempoOutOfRange(estimate.microsPerQuarter)
        }
        guard atTicks >= 0 else { throw .negativeTicks(atTicks) }
        guard pulseIndex >= 0 else { throw .negativePulse(pulseIndex) }
        if let lastOfferPulse, pulseIndex < lastOfferPulse {
            throw .nonMonotonicPulse(previous: lastOfferPulse, current: pulseIndex)
        }
        lastOfferPulse = pulseIndex
        if let proposed {
            guard pulseIndex - proposed.pulseIndex >= Self.minimumPulsesBetweenProposals else { return nil }
            let last = proposed.proposal.microsPerQuarter
            let change = (estimate.microsPerQuarter - last).magnitude
            guard change * UInt64(Self.deadbandDivisor) >= UInt64(last) else { return nil }
        }
        let proposal = ExternalTempoProposal(microsPerQuarter: estimate.microsPerQuarter, atTicks: atTicks)
        proposed = Proposed(proposal: proposal, pulseIndex: pulseIndex)
        return proposal
    }
}
