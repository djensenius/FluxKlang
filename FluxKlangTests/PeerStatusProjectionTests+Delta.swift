import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerStatusProjectionTests {
    private static func refusal(_ base: PeerStatusProjection, _ target: PeerStatusProjection,
                                limits: PeerSyncLimits = .standard) -> PeerStatusError? {
        do {
            _ = try base.delta(to: target, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    @Test func anAddedEntryIsAnUpsertStampedWithTheTargetAndNeedsACapabilityAdvance() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let added = try Fixture.entry(Fixture.bravo, writable: true)
        let target = try Fixture.projection([Fixture.entry(Fixture.alpha), added], sequence: 2,
                                            revisions: Fixture.revisions(capability: 1), session: Fixture.session())
        let delta = try base.delta(to: target, limits: .standard)
        #expect(delta.upserts == [added])
        #expect(delta.removals.isEmpty)
        #expect(delta.session == target.session)
        #expect(delta.sequence == (try Fixture.sequence(2)))
        #expect(delta.revisions == target.revisions)
    }

    @Test func aRemovedEntryIsARemovalWhenThePermissionRevisionAdvanced() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)])
        let target = try Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 2,
                                            revisions: Fixture.revisions(permission: 1))
        let delta = try base.delta(to: target, limits: .standard)
        #expect(delta.removals == [Fixture.bravo])
        #expect(delta.upserts.isEmpty)
    }

    @Test func aChangedDisplayFieldIsAnUpsertWithoutAnyPermissionOrCapabilityAdvance() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let changed = try [
            Fixture.entry(Fixture.alpha, upper: 0.5), Fixture.entry(Fixture.alpha, lower: 0.25),
            Fixture.entry(Fixture.alpha, verification: .measured), Fixture.entry(Fixture.alpha, unit: .percent)
        ]
        for entry in changed {
            let target = try Fixture.projection([entry], sequence: 2, revisions: Fixture.revisions(parameter: 1))
            #expect(try base.delta(to: target, limits: .standard).upserts == [entry])
        }
    }

    @Test func aChangedWritableFlagIsAnUpsertOnlyWhenPermissionOrCapabilityAdvanced() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha, writable: false)])
        let flipped = try Fixture.entry(Fixture.alpha, writable: true)
        for revisions in try [Fixture.revisions(permission: 1), Fixture.revisions(capability: 1)] {
            let target = try Fixture.projection([flipped], sequence: 2, revisions: revisions)
            #expect(try base.delta(to: target, limits: .standard).upserts == [flipped])
        }
        let unversioned = try Fixture.projection([flipped], sequence: 2)
        #expect(Self.refusal(base, unversioned) == .permissionChangeWithoutRevision)
    }

    @Test func otherRevisionAdvancesDoNotExplainAVisibilityOrWritableChange() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha, writable: true)])
        let others = try [
            Fixture.revisions(patch: 1), Fixture.revisions(parameter: 1), Fixture.revisions(graph: 1),
            Fixture.revisions(patch: 3, parameter: 4, graph: 5)
        ]
        for revisions in others {
            let narrowed = try Fixture.projection([Fixture.entry(Fixture.alpha, writable: false)], sequence: 2,
                                                  revisions: revisions)
            #expect(Self.refusal(base, narrowed) == .permissionChangeWithoutRevision)
            let removed = try Fixture.projection([], sequence: 2, revisions: revisions)
            #expect(Self.refusal(base, removed) == .permissionChangeWithoutRevision)
        }
    }

    @Test func anAddedOrRemovedEntryWithoutAnAdvanceIsRefusedInBothDirections() throws {
        let small = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let large = try Fixture.projection([Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)], sequence: 2)
        #expect(Self.refusal(small, large) == .permissionChangeWithoutRevision)
        let wide = try Fixture.projection([Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)])
        let narrow = try Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 2)
        #expect(Self.refusal(wide, narrow) == .permissionChangeWithoutRevision)
    }

    @Test func aSwappedEntryWithTheSameSizeAndNoAdvanceIsStillAVisibilityChange() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let swapped = try Fixture.projection([Fixture.entry(Fixture.bravo)], sequence: 2)
        #expect(Self.refusal(base, swapped) == .permissionChangeWithoutRevision)
    }

    @Test func aRevisionOnlyAdvanceWithUnchangedEntriesIsADeltaWithNoChanges() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let revisions = try Fixture.revisions(permission: 1)
        let target = try Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 2, revisions: revisions)
        let delta = try base.delta(to: target, limits: .standard)
        #expect(delta.changeCount == 0)
        #expect(delta.revisions == revisions)
        let other = try Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 2,
                                           revisions: Fixture.revisions(graph: 1))
        #expect(try base.delta(to: other, limits: .standard).changeCount == 0)
    }

    @Test func noChangeAndEqualRevisionsIsAnEmptyDelta() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let target = try Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 2)
        #expect(Self.refusal(base, target) == .emptyDelta)
        #expect(Self.refusal(try Fixture.projection([]), try Fixture.projection([], sequence: 2)) == .emptyDelta)
    }

    @Test func aRegressedRevisionComponentIsRefusedForEveryComponent() throws {
        let high = try Fixture.revisions(patch: 2, capability: 2, permission: 2, parameter: 2, graph: 2)
        let base = try Fixture.projection([], revisions: high)
        let lowered = try [
            Fixture.revisions(patch: 1, capability: 2, permission: 2, parameter: 2, graph: 2),
            Fixture.revisions(patch: 2, capability: 1, permission: 2, parameter: 2, graph: 2),
            Fixture.revisions(patch: 2, capability: 2, permission: 1, parameter: 2, graph: 2),
            Fixture.revisions(patch: 2, capability: 2, permission: 2, parameter: 1, graph: 2),
            Fixture.revisions(patch: 2, capability: 2, permission: 2, parameter: 2, graph: 1)
        ]
        for revisions in lowered {
            let target = try Fixture.projection([], sequence: 2, revisions: revisions)
            #expect(Self.refusal(base, target) == .revisionRegressed)
        }
    }

    @Test func aDifferentHostOrConnectionEpochIsASessionMismatchNamingTheFirstDifference() throws {
        let base = try Fixture.projection([])
        let otherHost = try Fixture.projection([], sequence: 2, revisions: Fixture.revisions(parameter: 1),
                                               session: Fixture.session(host: 2))
        #expect(Self.refusal(base, otherHost) == .sessionMismatch(.hostEpoch))
        let otherConnection = try Fixture.projection([], sequence: 2, revisions: Fixture.revisions(parameter: 1),
                                                     session: Fixture.session(connection: 2))
        #expect(Self.refusal(base, otherConnection) == .sessionMismatch(.connectionEpoch))
        let both = try Fixture.projection([], sequence: 2, revisions: Fixture.revisions(parameter: 1),
                                          session: Fixture.session(host: 3, connection: 3))
        #expect(Self.refusal(base, both) == .sessionMismatch(.hostEpoch))
    }

    @Test func aSequenceGapARepeatAndAnOlderSequenceAreRefusedWithTheirPositions() throws {
        let base = try Fixture.projection([], sequence: 4)
        let revisions = try Fixture.revisions(parameter: 1)
        let gap = try Fixture.projection([], sequence: 6, revisions: revisions)
        #expect(Self.refusal(base, gap)
            == .sequenceGap(expected: try Fixture.sequence(5), found: try Fixture.sequence(6)))
        let repeated = try Fixture.projection([], sequence: 4, revisions: revisions)
        #expect(Self.refusal(base, repeated)
            == .staleSequence(current: try Fixture.sequence(4), found: try Fixture.sequence(4)))
        let older = try Fixture.projection([], sequence: 2, revisions: revisions)
        #expect(Self.refusal(base, older)
            == .staleSequence(current: try Fixture.sequence(4), found: try Fixture.sequence(2)))
        let next = try Fixture.projection([], sequence: 5, revisions: revisions)
        #expect(try base.delta(to: next, limits: .standard).sequence == (try Fixture.sequence(5)))
    }

    @Test func aProjectionAtTheLastSequenceCannotAdvance() throws {
        let last = PeerSequence.maximumValue
        let base = try Fixture.projection([], sequence: last)
        let target = try Fixture.projection([], sequence: last, revisions: Fixture.revisions(parameter: 1))
        #expect(Self.refusal(base, target) == .sequenceExhausted)
        let beforeLast = try Fixture.projection([], sequence: last - 1)
        #expect(try beforeLast.delta(to: target, limits: .standard).sequence == target.sequence)
    }

    @Test func theSessionIsCheckedBeforeTheSequenceWhateverTheRevisionsAre() throws {
        let base = try Fixture.projection([], sequence: 1, revisions: Fixture.revisions(graph: 2))
        let both = try Fixture.projection([], sequence: 5, revisions: Fixture.revisions(graph: 1),
                                          session: Fixture.session(connection: 2))
        #expect(Self.refusal(base, both) == .sessionMismatch(.connectionEpoch))
    }

    @Test func theSequenceIsCheckedBeforeRevisionRegression() throws {
        let base = try Fixture.projection([], sequence: 1, revisions: Fixture.revisions(graph: 2))
        let both = try Fixture.projection([], sequence: 1, revisions: Fixture.revisions(graph: 1))
        #expect(Self.refusal(base, both)
            == .staleSequence(current: try Fixture.sequence(1), found: try Fixture.sequence(1)))
    }

    @Test func revisionRegressionIsCheckedBeforeEntryCountAndVisibilityChange() throws {
        let tight = try Fixture.limits(snapshot: 1, delta: 4)
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)], revisions: Fixture.revisions(graph: 2))
        let both = try Fixture.projection([Fixture.entry(Fixture.bravo), Fixture.entry(Fixture.charlie)], sequence: 2,
                                          revisions: Fixture.revisions(graph: 1))
        #expect(Self.refusal(base, both, limits: tight) == .revisionRegressed)
        #expect(Self.refusal(base, both) == .revisionRegressed)
    }

    @Test func theEntryCountIsCheckedBeforeAVisibilityChangeWithoutAnAdvance() throws {
        let tight = try Fixture.limits(snapshot: 1, delta: 4)
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let both = try Fixture.projection([Fixture.entry(Fixture.bravo), Fixture.entry(Fixture.charlie)], sequence: 2)
        #expect(Self.refusal(base, both, limits: tight) == .tooManyEntries(count: 2, limit: 1))
        #expect(Self.refusal(base, both) == .permissionChangeWithoutRevision)
    }

    @Test func aVisibilityChangeWithoutAnAdvanceIsRefusedBeforeTheDeltaSizeIsConsidered() throws {
        let tight = try Fixture.limits(snapshot: 8, delta: 1)
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let both = try Fixture.projection([Fixture.entry(Fixture.bravo), Fixture.entry(Fixture.charlie)], sequence: 2)
        #expect(Self.refusal(base, both, limits: tight) == .permissionChangeWithoutRevision)
        let versioned = try Fixture.projection([Fixture.entry(Fixture.bravo), Fixture.entry(Fixture.charlie)],
                                               sequence: 2, revisions: Fixture.revisions(permission: 1))
        #expect(Self.refusal(base, versioned, limits: tight) == .requiresSnapshot(changeCount: 3, limit: 1))
    }

    @Test func aRefusedDeltaLeavesBothProjectionsEqualToTheirCopies() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 3)
        let target = try Fixture.projection([Fixture.entry(Fixture.bravo)], sequence: 9)
        let baseCopy = base
        let targetCopy = target
        #expect(Self.refusal(base, target) != nil)
        #expect(base == baseCopy)
        #expect(target == targetCopy)
        #expect(base.entries.map(\.id) == [Fixture.alpha])
    }

    @Test func theDeltaDoesNotDependOnTheOrderTheEntriesWereGivenIn() throws {
        let entries = try [Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)]
        let revisions = try Fixture.revisions(capability: 1)
        let base = try Fixture.projection([])
        let forward = try base.delta(to: Fixture.projection(entries, sequence: 2, revisions: revisions),
                                     limits: .standard)
        let backward = try base.delta(to: Fixture.projection(entries.reversed(), sequence: 2, revisions: revisions),
                                      limits: .standard)
        #expect(forward == backward)
        #expect(forward.upserts.map(\.id) == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
    }

    @Test func aDeltaFromADifferentGrantViewIsUpsertsAndRemovalsOnlyForTheDifference() throws {
        let catalog = try Fixture.standardCatalog()
        let before = try Fixture.published(catalog, grants: Fixture.controller([Fixture.alpha, Fixture.bravo]))
        let after = try PeerStatusProjection.make(
            stamp: Fixture.stamp(sequence: 2, revisions: Fixture.revisions(permission: 1)),
            catalog: catalog, grants: Fixture.controller([Fixture.bravo, Fixture.charlie]), limits: .standard)
        let delta = try before.delta(to: after, limits: .standard)
        #expect(delta.removals == [Fixture.alpha])
        #expect(delta.upserts == [try Fixture.entry(Fixture.charlie, writable: true)])
    }

    @Test func aChangeBetweenZeroAndNegativeZeroIsNotAChangeAndLeavesTheResidentEntryAsHeld() throws {
        let zero = try Fixture.entry(Fixture.alpha, lower: 0)
        let negative = try Fixture.entry(Fixture.alpha, lower: -0.0)
        #expect(zero == negative)
        #expect(negative.lower.sign == .minus)
        let base = try Fixture.projection([negative, Fixture.entry(Fixture.bravo)])
        let alone = try Fixture.projection([zero, Fixture.entry(Fixture.bravo)], sequence: 2)
        #expect(Self.refusal(base, alone) == .emptyDelta)
        let changed = try Fixture.entry(Fixture.bravo, upper: 0.5)
        let mixed = try Fixture.projection([zero, changed], sequence: 2)
        let delta = try base.delta(to: mixed, limits: .standard)
        #expect(delta.upserts == [changed])
        #expect(delta.removals.isEmpty)
        let applied = try base.applying(delta, limits: .standard)
        let held = try #require(applied.entries.first)
        #expect(held.id == Fixture.alpha)
        #expect(held.lower.sign == .minus)
        #expect(applied.entries == [negative, changed])
    }
}
