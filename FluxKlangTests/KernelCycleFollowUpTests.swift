import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A defect a `FollowUpCase` can carry. Each one is reported by `KernelCycle.init` as the error named in its doc.
enum FollowUpDefect {
    /// `.notRenderEvents`: a fan-in consumed on control.
    case notRender
    /// `.blockCapacityOutOfRange(0)`.
    case blockCapacity
    /// `.perLaneQuotaOutOfRange(0)`.
    case perLaneQuota
    /// `.scopeCountMismatch(ownership: 2, safety: 3)`.
    case scopes
    /// `.scopeCountMismatch(ownership: 2, safety: 1)`.
    case safetyFewer
    /// `.telemetrySlotOutOfRange(slot)` for a slot outside `0..<2`; a slot inside it is valid.
    case telemetrySlot(Int)
    /// `.admissionRefusalsMismatch`: a table for one more lane than the fan-in has.
    case tableMismatch
    /// `.admissionRefusalsMismatch`: a table with the fan-in's lane count and another fan-in's identity.
    case tableForeign
    /// `.ownershipClaim(.alreadyUsed)`: `.freshFanIn` over a word a retired cycle left.
    case usedClaim
    /// `.admissionRefusalsRequired`: no table for a replacement over a retired cycle.
    case tableMissing
}

/// Parts for a `.replacingCycle` over an ownership a first cycle retired (claim word 2), carrying the given defects
/// on top of an otherwise valid set. Control side only: nothing here renders.
struct FollowUpCase {
    let rig: CycleRig
    var parts: KernelCycleParts
    var blockCapacity = 64
    var perLaneQuota = 64

    init(_ defects: [FollowUpDefect]) throws {
        rig = try CycleRig()
        _ = rig.cycle.retire()
        parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                 safety: rig.safety, ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
        for defect in defects { try apply(defect) }
    }

    /// Replaces the safety flags with ones of `scopes` scopes, keeping every other part (and so every other defect).
    private mutating func replaceSafety(scopes: Int) throws {
        parts = KernelCycleParts(events: parts.events, faults: rig.faults, ownership: rig.ownership,
                                 safety: try SafetyFlags(scopes: scopes), ramps: rig.ramps, telemetry: parts.telemetry,
                                 admissionRefusals: parts.admissionRefusals, start: parts.start)
    }

    private mutating func apply(_ defect: FollowUpDefect) throws {
        switch defect {
        case .notRender:
            parts = KernelCycleParts(
                events: try FanInHandoff<KernelEvent>(
                    policy: CycleRig.policy(consumer: .control), laneCapacity: 20, reserved: 16, faults: rig.faults,
                    criticalScope: CycleRig.criticalScope, producerSlotsScope: CycleRig.slotsScope),
                faults: rig.faults, ownership: rig.ownership, safety: rig.safety, ramps: rig.ramps,
                admissionRefusals: nil)
        case .blockCapacity: blockCapacity = 0
        case .perLaneQuota: perLaneQuota = 0
        case .scopes: try replaceSafety(scopes: 3)
        case .safetyFewer: try replaceSafety(scopes: 1)
        case .telemetrySlot(let slot):
            parts.telemetry = KernelCycleTelemetryOutput(slots: try kernelCycleTelemetrySlots(), slot: slot,
                                                         clockGeneration: 0)
        case .tableMismatch:
            parts.admissionRefusals = KernelAdmissionRefusals(laneCount: rig.events.laneCount + 1,
                                                              handoff: rig.events.identity)
        case .tableForeign:
            parts.admissionRefusals = KernelAdmissionRefusals(laneCount: rig.events.laneCount,
                                                              handoff: rig.events.identity &+ 1)
        case .usedClaim: parts.start = .freshFanIn
        case .tableMissing: parts.admissionRefusals = nil
        }
    }

    /// What `KernelCycle.init` reports for these parts; `nil` when it succeeds (and then the claim is taken).
    func outcome() throws -> KernelCycle.PreparationError? {
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
        do {
            _ = try KernelCycle(parts, pulses: gate, blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
            return nil
        } catch {
            return error
        }
    }
}

/// The order `KernelCycle.init` reports preparation defects in, tested on every adjacent pair that a fan-in the
/// type system allows can carry together (#360 ruling 2). `.deadline` is not reachable (`FanInHandoff` validates the
/// policy first) and `.ackIdentitiesExhausted` needs 2^64 prior cycles, so pairs touching them have no fixture.
@Suite(.productionAccessAudit) struct KernelCycleFollowUpTests {
    /// The error a case reports, and whether the ownership's claim word stayed what it was: a refusal claims nothing.
    static func refusal(_ defects: [FollowUpDefect]) throws -> (error: KernelCycle.PreparationError?, claimKept: Bool) {
        let fixture = try FollowUpCase(defects)
        let before = fixture.rig.ownership.cycleClaimState()
        let error = try fixture.outcome()
        return (error, fixture.rig.ownership.cycleClaimState() == before)
    }

    /// Kills: a defect that is not reported when it is the only one (so a both-defects test would prove nothing).
    @Test func followUpEachDefectAloneIsReportedAsItself() throws {
        let expected: [(FollowUpDefect, KernelCycle.PreparationError)] = [
            (.notRender, .notRenderEvents), (.blockCapacity, .blockCapacityOutOfRange(0)),
            (.perLaneQuota, .perLaneQuotaOutOfRange(0)), (.scopes, .scopeCountMismatch(ownership: 2, safety: 3)),
            (.safetyFewer, .scopeCountMismatch(ownership: 2, safety: 1)),
            (.telemetrySlot(2), .telemetrySlotOutOfRange(2)), (.telemetrySlot(-1), .telemetrySlotOutOfRange(-1)),
            (.tableMismatch, .admissionRefusalsMismatch), (.tableForeign, .admissionRefusalsMismatch),
            (.usedClaim, .ownershipClaim(.alreadyUsed)), (.tableMissing, .admissionRefusalsRequired)
        ]
        for (defect, error) in expected {
            let result = try Self.refusal([defect])
            #expect(result.error == error)
            #expect(result.claimKept)
        }
    }

    /// Kills: a valid set that is refused, which would hide every order test.
    @Test func followUpValidReplacementOverRetiredCycleIsAcceptedAndClaims() throws {
        let fixture = try FollowUpCase([])
        var before = fixture.rig.ownership.cycleClaimState()
        #expect(try fixture.outcome() == nil)
        #expect(fixture.rig.ownership.cycleClaimState() != before)
        before = fixture.rig.ownership.cycleClaimState()
        #expect(try fixture.outcome() == .ownershipClaim(.predecessorNotRetired))
        #expect(fixture.rig.ownership.cycleClaimState() == before)
    }

    /// Kills: a telemetry slot bound off by one at either end: the slots 0 and 1 (N) are accepted, -1 and 2 (N + 1)
    /// are refused.
    @Test func followUpTelemetrySlotsZeroAndOneAreAcceptedAndMinusOneAndTwoAreRefused() throws {
        for slot in [0, 1] {
            #expect(try FollowUpCase([.telemetrySlot(slot)]).outcome() == nil)
        }
        for slot in [-1, 2] {
            #expect(try FollowUpCase([.telemetrySlot(slot)]).outcome() == .telemetrySlotOutOfRange(slot))
        }
    }

    /// Kills: the notRender check after the block capacity check.
    @Test func followUpNotRenderIsReportedBeforeBlockCapacity() throws {
        let result = try Self.refusal([.blockCapacity, .notRender])
        #expect(result.error == .notRenderEvents)
        #expect(result.claimKept)
    }

    /// Kills: the block capacity check after the per-lane quota check.
    @Test func followUpBlockCapacityIsReportedBeforePerLaneQuota() throws {
        let result = try Self.refusal([.perLaneQuota, .blockCapacity])
        #expect(result.error == .blockCapacityOutOfRange(0))
        #expect(result.claimKept)
    }

    /// Kills: the per-lane quota check after the scope count check.
    @Test func followUpPerLaneQuotaIsReportedBeforeScopeCount() throws {
        let result = try Self.refusal([.scopes, .perLaneQuota])
        #expect(result.error == .perLaneQuotaOutOfRange(0))
        #expect(result.claimKept)
    }

    /// Kills: the scope count check after the telemetry slot check.
    @Test func followUpScopeCountIsReportedBeforeTelemetrySlot() throws {
        let result = try Self.refusal([.telemetrySlot(2), .scopes])
        #expect(result.error == .scopeCountMismatch(ownership: 2, safety: 3))
        #expect(result.claimKept)
    }

    /// Kills: the telemetry slot check after the admission table mismatch check.
    @Test func followUpTelemetrySlotIsReportedBeforeTableMismatch() throws {
        let result = try Self.refusal([.tableMismatch, .telemetrySlot(2)])
        #expect(result.error == .telemetrySlotOutOfRange(2))
        #expect(result.claimKept)
    }

    /// Kills: the admission table mismatch check after the ownership claim check.
    @Test func followUpTableMismatchIsReportedBeforeOwnershipClaim() throws {
        let result = try Self.refusal([.usedClaim, .tableMismatch])
        #expect(result.error == .admissionRefusalsMismatch)
        #expect(result.claimKept)
    }

    /// Kills: the missing-table check before the ownership claim check (a used word with no table is `.alreadyUsed`).
    @Test func followUpOwnershipClaimIsReportedBeforeMissingTable() throws {
        let result = try Self.refusal([.tableMissing, .usedClaim])
        #expect(result.error == .ownershipClaim(.alreadyUsed))
        #expect(result.claimKept)
    }
}
