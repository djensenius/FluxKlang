import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #360 rulings 3 and 4: the lost-claim refusal and the claim word's wear-out.
extension KernelCycleFollowUpTests {
    /// What `KernelCycle.init` reports for `parts`; `nil` when it succeeds.
    private static func outcome(_ parts: KernelCycleParts) throws -> KernelCycle.PreparationError? {
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
        do {
            _ = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
            return nil
        } catch {
            return error
        }
    }

    private static func refusal(_ ownership: NoteOwnership, _ state: NoteOwnership.CycleClaimState)
        -> NoteOwnership.CycleClaimRefusal? {
        do {
            _ = try ownership.claimForCycle(fresh: false, from: state)
            return nil
        } catch {
            return error
        }
    }

    /// Kills: `.claimRaced` reported for a live predecessor (an odd word is `.predecessorNotRetired`); a stale-state
    /// claim that succeeds or changes the word; the compare-exchange that ignores the state it was given.
    @Test func followUpClaimFromStaleStateIsRefusedAsRacedOnlyWhenWordIsFree() throws {
        let rig = try CycleRig()
        _ = rig.cycle.retire()
        let stale = rig.ownership.cycleClaimState()
        let table = rig.cycle.admissionRefusals
        let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                     safety: rig.safety, ramps: rig.ramps, admissionRefusals: table)
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
        let second = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
        var current = rig.ownership.cycleClaimState()
        #expect(current != stale)
        #expect(Self.refusal(rig.ownership, stale) == .predecessorNotRetired)
        #expect(rig.ownership.cycleClaimState() == current)
        _ = second.retire()
        current = rig.ownership.cycleClaimState()
        #expect(Self.refusal(rig.ownership, stale) == .claimRaced)
        #expect(rig.ownership.cycleClaimState() == current)
        #expect(Self.refusal(rig.ownership, current) == nil)
        #expect(rig.ownership.cycleClaimState() != current)
    }

    /// Kills: a claim state that is not a retired cycle's when the word is nonzero and even; a never-claimed
    /// word that counts as retired; a live one that does.
    @Test func followUpClaimStateReportsRetiredCycleOnlyForNonzeroEvenWord() throws {
        let rig = try CycleRig()
        let never = try NoteOwnership(scopes: 2).cycleClaimState()
        #expect(never.hasRetiredCycle == false)
        #expect(rig.ownership.cycleClaimState().hasRetiredCycle == false)
        _ = rig.cycle.retire()
        #expect(rig.ownership.cycleClaimState().hasRetiredCycle)
    }

#if DEBUG
    /// A first cycle over a seeded ownership: the claim word starts at `word`.
    private static func parts(_ rig: CycleRig, seeded word: UInt64, table: KernelAdmissionRefusals?) throws
        -> KernelCycleParts {
        KernelCycleParts(events: rig.events, faults: rig.faults,
                         ownership: try NoteOwnership(scopes: 2, seedingClaimWord: word),
                         safety: rig.safety, ramps: rig.ramps, admissionRefusals: table)
    }

    /// Kills: a seeding initializer that stores a different word, skips the store, or skips the scope check.
    @Test func followUpSeededWordIsTheOneTheClaimReads() throws {
        let rig = try CycleRig()
        #expect(try NoteOwnership(scopes: 2, seedingClaimWord: 0).cycleClaimState().hasRetiredCycle == false)
        #expect(try NoteOwnership(scopes: 2, seedingClaimWord: 2).cycleClaimState().hasRetiredCycle)
        #expect(try NoteOwnership(scopes: 2, seedingClaimWord: 3).cycleClaimState().hasRetiredCycle == false)
        #expect(throws: NoteOwnership.PreparationError.scopeCountOutOfRange(0)) {
            _ = try NoteOwnership(scopes: 0, seedingClaimWord: 2)
        }
        let seeded = try Self.parts(rig, seeded: 4, table: nil)
        #expect(try Self.outcome(seeded) == .admissionRefusalsRequired)
    }

    /// The claim word wears out: from `max - 3` exactly one more cycle is built (N), the next preparation (N + 1) is
    /// refused `.alreadyUsed` for ever, even with a table and under `.replacingCycle`.
    /// Kills: a wear-out bound that allows one cycle too many (the word wrapping to 0) or one too few.
    @Test func followUpClaimWordWearsOutAfterTheLastCycle() throws {
        let rig = try CycleRig()
        let table = rig.cycle.admissionRefusals
        let parts = try Self.parts(rig, seeded: UInt64.max - 3, table: table)
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
        let last = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
        #expect(try Self.outcome(parts) == .ownershipClaim(.predecessorNotRetired))
        _ = last.retire()
        var worn = parts.ownership.cycleClaimState()
        #expect(try Self.outcome(parts) == .ownershipClaim(.alreadyUsed))
        #expect(parts.ownership.cycleClaimState() == worn)
        worn = parts.ownership.cycleClaimState()
        #expect(try Self.outcome(parts) == .ownershipClaim(.alreadyUsed))
        #expect(parts.ownership.cycleClaimState() == worn)
    }

    /// Kills: a wear-out threshold off by one either way: `max - 3` is claimable, `max - 2` and `max` (odd) are held,
    /// `max - 1` is used up whether or not a table is given (the claim refusal outranks the table).
    @Test func followUpSeededWordsNearTheLimitAreRefusedAtTheBound() throws {
        let rig = try CycleRig()
        let table = rig.cycle.admissionRefusals
        let cases: [(UInt64, KernelCycle.PreparationError?)] = [
            (UInt64.max - 3, nil), (UInt64.max - 2, .ownershipClaim(.predecessorNotRetired)),
            (UInt64.max - 1, .ownershipClaim(.alreadyUsed)), (UInt64.max, .ownershipClaim(.predecessorNotRetired))
        ]
        for (word, expected) in cases {
            #expect(try Self.outcome(Self.parts(rig, seeded: word, table: table)) == expected)
        }
        #expect(try Self.outcome(Self.parts(rig, seeded: UInt64.max - 1, table: nil)) == .ownershipClaim(.alreadyUsed))
    }
#endif
}
