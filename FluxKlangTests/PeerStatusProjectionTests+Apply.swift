import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerStatusProjectionTests {
    private static func step(
        _ sequence: Int = 2, revisions: CommandRevisions? = nil, session: PeerSyncSession? = nil,
        upserts: [PeerStatusEntry] = [], removals: Set<ParameterID> = []
    ) throws -> PeerStatusDelta {
        try PeerStatusDelta.make(
            stamp: Fixture.stamp(session: session, sequence: sequence,
                                 revisions: revisions ?? Fixture.revisions(capability: 1)),
            upserts: upserts, removals: removals, limits: .standard)
    }

    private static func refusal(_ base: PeerStatusProjection, _ delta: PeerStatusDelta,
                                limits: PeerSyncLimits = .standard) -> PeerStatusError? {
        do {
            _ = try base.applying(delta, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    @Test func applyingTheDeltaBetweenTwoProjectionsGivesTheTargetForEveryKindOfChange() throws {
        let revisions = try Fixture.revisions(capability: 1, permission: 1)
        let base = try Fixture.projection([
            Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo, writable: true), Fixture.entry(Fixture.charlie)
        ])
        let targets = try [
            Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 2, revisions: revisions),
            Fixture.projection([
                Fixture.entry(Fixture.alpha, upper: 0.5), Fixture.entry(Fixture.bravo),
                Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.delta)
            ], sequence: 2, revisions: revisions),
            Fixture.projection([], sequence: 2, revisions: revisions),
            Fixture.projection([
                Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo, writable: true),
                Fixture.entry(Fixture.charlie)
            ], sequence: 2, revisions: revisions)
        ]
        for target in targets {
            let delta = try base.delta(to: target, limits: .standard)
            #expect(try base.applying(delta, limits: .standard) == target)
        }
    }

    @Test func applyingReturnsANewProjectionStampedWithTheDeltaAndLeavesTheBaseAlone() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let baseCopy = base
        let revisions = try Fixture.revisions(capability: 1, graph: 4)
        let delta = try Self.step(2, revisions: revisions, upserts: [Fixture.entry(Fixture.bravo)])
        let next = try base.applying(delta, limits: .standard)
        #expect(next.sequence == (try Fixture.sequence(2)))
        #expect(next.revisions == revisions)
        #expect(next.session == base.session)
        #expect(next.entries.map(\.id) == [Fixture.alpha, Fixture.bravo])
        #expect(base == baseCopy)
    }

    @Test func anUpsertReplacesTheResidentEntryWithTheChangedOne() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)])
        let changed = try Fixture.entry(Fixture.bravo, upper: 0.25, verification: .measured)
        let next = try base.applying(Self.step(upserts: [changed]), limits: .standard)
        #expect(next.entries == [try Fixture.entry(Fixture.alpha), changed])
    }

    @Test func aReplayedDeltaIsStaleAndTheFirstResultIsKept() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let delta = try Self.step(upserts: [Fixture.entry(Fixture.bravo)])
        let first = try base.applying(delta, limits: .standard)
        let firstCopy = first
        #expect(Self.refusal(first, delta)
            == .staleSequence(current: try Fixture.sequence(2), found: try Fixture.sequence(2)))
        #expect(first == firstCopy)
    }

    @Test func aDeltaOfAnotherSessionIsRefusedBeforeAnythingChanges() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let upserts = try [Fixture.entry(Fixture.bravo)]
        let otherHost = try Self.step(session: Fixture.session(host: 2), upserts: upserts)
        #expect(Self.refusal(base, otherHost) == .sessionMismatch(.hostEpoch))
        let otherConnection = try Self.step(session: Fixture.session(connection: 2), upserts: upserts)
        #expect(Self.refusal(base, otherConnection) == .sessionMismatch(.connectionEpoch))
        let both = try Self.step(session: Fixture.session(host: 2, connection: 2), upserts: upserts)
        #expect(Self.refusal(base, both) == .sessionMismatch(.hostEpoch))
    }

    @Test func applyingRefusesAGapAnOldSequenceAndAnExhaustedSession() throws {
        let base = try Fixture.projection([], sequence: 4)
        let upserts = try [Fixture.entry(Fixture.alpha)]
        #expect(Self.refusal(base, try Self.step(7, upserts: upserts))
            == .sequenceGap(expected: try Fixture.sequence(5), found: try Fixture.sequence(7)))
        #expect(Self.refusal(base, try Self.step(3, upserts: upserts))
            == .staleSequence(current: try Fixture.sequence(4), found: try Fixture.sequence(3)))
        let last = try Fixture.projection([], sequence: PeerSequence.maximumValue)
        #expect(Self.refusal(last, try Self.step(PeerSequence.maximumValue, upserts: upserts)) == .sequenceExhausted)
    }

    @Test func applyingRefusesRegressedRevisionsAndAcceptsEqualOnes() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)], revisions: Fixture.revisions(parameter: 3))
        let regressed = try Self.step(revisions: Fixture.revisions(parameter: 2),
                                      upserts: [Fixture.entry(Fixture.alpha, upper: 0.25)])
        #expect(Self.refusal(base, regressed) == .revisionRegressed)
        let equal = try Self.step(revisions: Fixture.revisions(parameter: 3),
                                  upserts: [Fixture.entry(Fixture.alpha, upper: 0.5)])
        #expect(Self.refusal(base, equal) == nil)
    }

    @Test func aDeltaWithNoChangesAndEqualRevisionsIsEmptyButARevisionAdvanceIsKept() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        #expect(Self.refusal(base, try Self.step(revisions: Fixture.revisions())) == .emptyDelta)
        let advanced = try base.applying(Self.step(revisions: Fixture.revisions(permission: 1)), limits: .standard)
        #expect(advanced.entries == base.entries)
        #expect(advanced.revisions == (try Fixture.revisions(permission: 1)))
    }

    @Test func removingAnUnknownIdIsRefusedNamingTheSmallestWhateverTheSetOrder() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let unknown: Set = [Fixture.delta, Fixture.charlie, Fixture.bravo]
        #expect(Self.refusal(base, try Self.step(removals: unknown)) == .removedUnknownEntry(Fixture.bravo))
        let known = try Self.step(removals: [Fixture.alpha, Fixture.charlie])
        #expect(Self.refusal(base, known) == .removedUnknownEntry(Fixture.charlie))
    }

    @Test func anUpsertEqualToTheResidentEntryIsRedundantNamingTheSmallest() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)])
        let both = try Self.step(upserts: [Fixture.entry(Fixture.bravo), Fixture.entry(Fixture.alpha)])
        #expect(Self.refusal(base, both) == .redundantUpsert(Fixture.alpha))
        let mixed = try Self.step(upserts: [Fixture.entry(Fixture.alpha, upper: 0.5), Fixture.entry(Fixture.bravo)])
        #expect(Self.refusal(base, mixed) == .redundantUpsert(Fixture.bravo))
    }

    @Test func anUnknownRemovalIsReportedBeforeARedundantUpsert() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let both = try Self.step(upserts: [Fixture.entry(Fixture.alpha)], removals: [Fixture.charlie])
        #expect(Self.refusal(base, both) == .removedUnknownEntry(Fixture.charlie))
    }

    @Test func aRedundantUpsertIsReportedBeforeTheResultSize() throws {
        let tight = try Fixture.limits(snapshot: 1, delta: 4)
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let both = try Self.step(upserts: [Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)])
        #expect(Self.refusal(base, both, limits: tight) == .redundantUpsert(Fixture.alpha))
    }

    @Test func theResultSizeIsReportedBeforeAVisibilityChangeWithoutAnAdvance() throws {
        let tight = try Fixture.limits(snapshot: 1, delta: 4)
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let both = try Self.step(revisions: Fixture.revisions(), upserts: [Fixture.entry(Fixture.bravo)])
        #expect(Self.refusal(base, both, limits: tight) == .tooManyEntries(count: 2, limit: 1))
        #expect(Self.refusal(base, both) == .permissionChangeWithoutRevision)
    }

    @Test func aWritableChangeWithoutAPermissionOrCapabilityAdvanceIsRefusedByTheReceiverToo() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)])
        let flipped = try Fixture.entry(Fixture.alpha, writable: true)
        let unversioned = try Self.step(revisions: Fixture.revisions(patch: 1, parameter: 1, graph: 1),
                                        upserts: [flipped])
        #expect(Self.refusal(base, unversioned) == .permissionChangeWithoutRevision)
        let versioned = try Self.step(revisions: Fixture.revisions(permission: 1), upserts: [flipped])
        #expect(try base.applying(versioned, limits: .standard).entries == [flipped])
    }

    @Test func sessionComesBeforeSequenceAndSequenceBeforeRegressionBeforeSize() throws {
        let tight = try Fixture.limits(snapshot: 8, delta: 1)
        let base = try Fixture.projection([], sequence: 3, revisions: Fixture.revisions(graph: 2))
        let upserts = try [Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)]
        let lowGraph = try Fixture.revisions(graph: 1)
        let sessionAndGap = try Self.step(9, revisions: lowGraph, session: Fixture.session(host: 2), upserts: upserts)
        #expect(Self.refusal(base, sessionAndGap, limits: tight) == .sessionMismatch(.hostEpoch))
        let gapAndRegress = try Self.step(9, revisions: lowGraph, upserts: upserts)
        #expect(Self.refusal(base, gapAndRegress, limits: tight)
            == .sequenceGap(expected: try Fixture.sequence(4), found: try Fixture.sequence(9)))
        let regressAndSize = try PeerStatusDelta.make(
            stamp: Fixture.stamp(sequence: 4, revisions: lowGraph), upserts: upserts,
            removals: [], limits: .standard)
        #expect(Self.refusal(base, regressAndSize, limits: tight) == .revisionRegressed)
        let sizeOnly = try Self.step(4, revisions: Fixture.revisions(graph: 2), upserts: upserts)
        #expect(Self.refusal(base, sizeOnly, limits: tight) == .deltaTooLarge(count: 2, limit: 1))
    }

    @Test func everyRefusedDeltaLeavesTheBaseEqualToItsCopy() throws {
        let base = try Fixture.projection([Fixture.entry(Fixture.alpha)], sequence: 4)
        let copy = base
        let refused = try [
            Self.step(9, upserts: [Fixture.entry(Fixture.bravo)]),
            Self.step(5, revisions: Fixture.revisions()),
            Self.step(5, removals: [Fixture.delta]),
            Self.step(5, upserts: [Fixture.entry(Fixture.alpha)]),
            Self.step(5, session: Fixture.session(host: 5), upserts: [Fixture.entry(Fixture.bravo)])
        ]
        for delta in refused {
            #expect(Self.refusal(base, delta) != nil)
            #expect(base == copy)
        }
    }

    @Test func aDeltaIsBuiltSortedWhateverTheOrderOfItsUpsertsAndRemovals() throws {
        let entries = try [Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)]
        let forward = try Self.step(upserts: entries, removals: [Fixture.delta, ParameterID(validated: "par.0")])
        let backward = try Self.step(upserts: entries.reversed(),
                                     removals: [ParameterID(validated: "par.0"), Fixture.delta])
        #expect(forward == backward)
        #expect(forward.upserts.map(\.id) == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
        #expect(forward.removals == [ParameterID(validated: "par.0"), Fixture.delta])
    }

    @Test func aDuplicateUpsertIsRefusedNamingTheSmallestWhateverTheOrder() throws {
        let entries = try [Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.bravo),
                           Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.bravo)]
        for ordered in [entries, entries.reversed()] {
            #expect(throws: PeerStatusError.duplicateEntry(Fixture.bravo)) { try Self.step(upserts: ordered) }
        }
    }

    @Test func anIdBothUpsertedAndRemovedIsRefusedNamingTheSmallestWhateverTheOrder() throws {
        let entries = try [Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.bravo), Fixture.entry(Fixture.delta)]
        for ordered in [entries, entries.reversed()] {
            #expect(throws: PeerStatusError.overlappingChanges(Fixture.bravo)) {
                try Self.step(upserts: ordered, removals: [Fixture.delta, Fixture.bravo])
            }
        }
    }

    @Test func aDuplicateUpsertIsReportedBeforeAnOverlappingChange() throws {
        let entries = try [Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.alpha)]
        for ordered in [entries, entries.reversed()] {
            #expect(throws: PeerStatusError.duplicateEntry(Fixture.charlie)) {
                try Self.step(upserts: ordered, removals: [Fixture.alpha])
            }
        }
    }

    @Test func aBaselineFromEntriesIsSortedAndRefusesDuplicatesNamingTheSmallest() throws {
        let entries = try [Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)]
        for ordered in [entries, entries.reversed()] {
            let sorted = try Fixture.projection(ordered).entries.map(\.id)
            #expect(sorted == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
        }
        let duplicated = try entries + [Fixture.entry(Fixture.charlie), Fixture.entry(Fixture.bravo)]
        for ordered in [duplicated, duplicated.reversed()] {
            #expect(throws: PeerStatusError.duplicateEntry(Fixture.bravo)) { try Fixture.projection(ordered) }
        }
    }
}
