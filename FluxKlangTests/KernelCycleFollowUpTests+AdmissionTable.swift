import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #360 ruling 1: a replacement over a retired cycle must pass the admission refusal table.
extension KernelCycleFollowUpTests {
    /// A cycle over `rig`'s parts with a new ownership (claim word 0), so it is the first cycle built over it.
    private static func firstCycle(_ rig: CycleRig, start: KernelCycleStart,
                                   table: KernelAdmissionRefusals?) throws -> KernelCycle {
        let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: try NoteOwnership(scopes: 2),
                                     safety: rig.safety, ramps: rig.ramps, admissionRefusals: table, start: start)
        return try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                               blockCapacity: 64, perLaneQuota: 64)
    }

    /// Kills: a missing table accepted over a retired word; a refusal that claims the ownership or counts a
    /// refusal; a table that, once supplied, is still refused (the refusal is about the table, not the word).
    @Test func followUpMissingTableOverRetiredWordClaimsAndCountsNothing() throws {
        var fixture = try FollowUpCase([.tableMissing])
        let table = fixture.rig.cycle.admissionRefusals
        var claim = fixture.rig.ownership.cycleClaimState()
        var late = table.total(.beyondLookahead)
        var unordered = table.total(.nonMonotonic)
        var foreign = table.unattributed
        #expect(try fixture.outcome() == .admissionRefusalsRequired)
        #expect(fixture.rig.ownership.cycleClaimState() == claim)
        #expect(table.total(.beyondLookahead) == late && table.total(.nonMonotonic) == unordered)
        #expect(table.unattributed == foreign)
        fixture.parts.admissionRefusals = table
        #expect(try fixture.outcome() == nil)
        #expect(fixture.rig.ownership.cycleClaimState() != claim)
        claim = fixture.rig.ownership.cycleClaimState()
        late = table.total(.beyondLookahead)
        unordered = table.total(.nonMonotonic)
        foreign = table.unattributed
        #expect(try fixture.outcome() == .ownershipClaim(.predecessorNotRetired))
        #expect(fixture.rig.ownership.cycleClaimState() == claim)
        #expect(table.total(.beyondLookahead) == late && table.total(.nonMonotonic) == unordered)
        #expect(table.unattributed == foreign)
    }

    /// Kills: the table required of a first cycle (claim word 0) under either start; a new table that is not the
    /// fan-in's (identity or lane count).
    @Test func followUpFirstCycleMayOmitTableUnderBothStarts() throws {
        for start in [KernelCycleStart.freshFanIn, .replacingCycle] {
            let rig = try CycleRig()
            let cycle = try Self.firstCycle(rig, start: start, table: nil)
            #expect(cycle.admissionRefusals !== rig.cycle.admissionRefusals)
            #expect(cycle.admissionRefusals.laneCount == rig.events.laneCount)
            #expect(cycle.admissionRefusals.handoff == rig.events.identity)
        }
    }

    /// Kills: a replacement that makes a new table although it was given the retired cycle's (producers admitted
    /// before it keep counting into the old one).
    @Test func followUpReplacementKeepsTheTableItWasGiven() throws {
        let fixture = try FollowUpCase([])
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
        let replacement = try KernelCycle(fixture.parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
        #expect(replacement.admissionRefusals === fixture.rig.cycle.admissionRefusals)
    }

    /// Kills: the missing-table refusal applied to a never-claimed word (only a retired cycle's word needs a table);
    /// a table accepted on a live (odd) word.
    @Test func followUpMissingTableIsRefusedOnlyOverARetiredWord() throws {
        let rig = try CycleRig()
        var parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                     safety: rig.safety, ramps: rig.ramps)
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
        func prepare() throws -> KernelCycle.PreparationError? {
            do {
                _ = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
                return nil
            } catch {
                return error
            }
        }
        #expect(try prepare() == .ownershipClaim(.predecessorNotRetired))
        _ = rig.cycle.retire()
        #expect(try prepare() == .admissionRefusalsRequired)
        parts.start = .freshFanIn
        #expect(try prepare() == .ownershipClaim(.alreadyUsed))
    }
}
