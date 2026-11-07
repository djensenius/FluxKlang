import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerStatusProjectionTests {
    private static func ids(_ count: Int) throws -> [ParameterID] {
        try (0..<count).map { try ParameterID("par.n" + String(1_000_000 + $0)) }
    }

    private static func entries(_ count: Int) throws -> [PeerStatusEntry] {
        try ids(count).map { try Fixture.entry($0) }
    }

    private static func catalog(_ count: Int) throws -> ParameterCatalog {
        try ParameterCatalog(Self.ids(count).map { try Fixture.descriptor($0) })
    }

    @Test func aCatalogProjectionAtTheSnapshotLimitIsAcceptedAndOneMoreIsRefused() throws {
        let limits = try Fixture.limits(snapshot: 3, delta: 1)
        let atLimit = try Fixture.published(Self.catalog(3), grants: Fixture.observer(), limits: limits)
        #expect(atLimit.entries.count == 3)
        #expect(throws: PeerStatusError.tooManyEntries(count: 4, limit: 3)) {
            try Fixture.published(Self.catalog(4), grants: Fixture.observer(), limits: limits)
        }
    }

    @Test func onlyVisibleEntriesCountTowardTheSnapshotLimit() throws {
        let limits = try Fixture.limits(snapshot: 2, delta: 1)
        let projection = try Fixture.published(Fixture.standardCatalog(), grants: Fixture.controller([Fixture.bravo]),
                                               limits: limits)
        #expect(projection.entries.count == 1)
        #expect(throws: PeerStatusError.tooManyEntries(count: 3, limit: 2)) {
            try Fixture.published(Fixture.standardCatalog(), grants: Fixture.observer(), limits: limits)
        }
    }

    @Test func theStandardLimitAcceptsAFullCatalogOfFourThousandAndNinetySixLiveEntries() throws {
        let projection = try Fixture.published(Self.catalog(4_096), grants: Fixture.observer())
        #expect(projection.entries.count == 4_096)
        #expect(PeerSyncLimits.standard.maximumSnapshotValues == 4_096)
        #expect(projection.entries.first?.id == ParameterID(validated: "par.n1000000"))
        #expect(projection.entries.last?.id == ParameterID(validated: "par.n1004095"))
    }

    @Test func anEntryBaselineAtTheSnapshotLimitIsAcceptedAndOneMoreIsRefused() throws {
        let limits = try Fixture.limits(snapshot: 3, delta: 1)
        #expect(try Fixture.projection(Self.entries(3), limits: limits).entries.count == 3)
        #expect(throws: PeerStatusError.tooManyEntries(count: 4, limit: 3)) {
            try Fixture.projection(Self.entries(4), limits: limits)
        }
    }

    @Test func tooManyEntriesIsReportedBeforeADuplicate() throws {
        let limits = try Fixture.limits(snapshot: 2, delta: 1)
        let both = try [Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)]
        #expect(throws: PeerStatusError.tooManyEntries(count: 3, limit: 2)) {
            try Fixture.projection(both, limits: limits)
        }
        #expect(throws: PeerStatusError.tooManyEntries(count: 3, limit: 2)) {
            try Fixture.projection(both.reversed(), limits: limits)
        }
    }

    @Test func aDeltaFactoryAcceptsExactlyTheDeltaLimitAndRefusesOneMore() throws {
        let limits = try Fixture.limits(snapshot: 8, delta: 2)
        let stamp = try Fixture.stamp(sequence: 2)
        let two = try PeerStatusDelta.make(
            stamp: stamp, upserts: [Fixture.entry(Fixture.alpha)], removals: [Fixture.bravo], limits: limits)
        #expect(two.changeCount == 2)
        #expect(throws: PeerStatusError.deltaTooLarge(count: 3, limit: 2)) {
            try PeerStatusDelta.make(
                stamp: stamp, upserts: [Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)],
                removals: [Fixture.charlie], limits: limits)
        }
    }

    @Test func theDeltaSizeIsCountedBeforeDuplicatesAreLookedFor() throws {
        let limits = try Fixture.limits(snapshot: 8, delta: 2)
        let upserts = try [Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)]
        for ordered in [upserts, upserts.reversed()] {
            #expect(throws: PeerStatusError.deltaTooLarge(count: 3, limit: 2)) {
                try PeerStatusDelta.make(stamp: Fixture.stamp(sequence: 2), upserts: ordered, removals: [],
                                         limits: limits)
            }
        }
    }

    @Test func aDeltaBetweenProjectionsAtTheDeltaLimitIsReturnedAndOneMoreRequiresASnapshot() throws {
        let limits = try Fixture.limits(snapshot: 8, delta: 2)
        let revisions = try Fixture.revisions(capability: 1)
        let base = try Fixture.projection(Self.entries(3), limits: limits)
        let atLimit = try Fixture.projection(Self.entries(2) + [Fixture.entry(Fixture.alpha)], sequence: 2,
                                             revisions: revisions, limits: limits)
        #expect(try base.delta(to: atLimit, limits: limits).changeCount == 2)
        let overEntries = try Self.entries(1) + [Fixture.entry(Fixture.alpha), Fixture.entry(Fixture.bravo)]
        let over = try Fixture.projection(overEntries, sequence: 2, revisions: revisions, limits: limits)
        #expect(throws: PeerStatusError.requiresSnapshot(changeCount: 4, limit: 2)) {
            try base.delta(to: over, limits: limits)
        }
    }

    @Test func removalsCountTowardTheDeltaLimitAndASingleChangeFitsTheMinimumLimit() throws {
        let limits = try Fixture.limits(snapshot: 8, delta: 1)
        let revisions = try Fixture.revisions(permission: 1)
        let base = try Fixture.projection(Self.entries(2), limits: limits)
        let one = try Fixture.projection(Self.entries(1), sequence: 2, revisions: revisions, limits: limits)
        #expect(try base.delta(to: one, limits: limits).removals == [Self.ids(2)[1]])
        let none = try Fixture.projection([], sequence: 2, revisions: revisions, limits: limits)
        #expect(throws: PeerStatusError.requiresSnapshot(changeCount: 2, limit: 1)) {
            try base.delta(to: none, limits: limits)
        }
    }

    @Test func aWiderProjectionThanTheSnapshotLimitIsRefusedByTheDeltaStepOnEitherSide() throws {
        let narrow = try Fixture.limits(snapshot: 2, delta: 4)
        let revisions = try Fixture.revisions(capability: 1)
        let three = try Fixture.projection(Self.entries(3), sequence: 2, revisions: revisions)
        let one = try Fixture.projection(Self.entries(1))
        #expect(throws: PeerStatusError.tooManyEntries(count: 3, limit: 2)) { try one.delta(to: three, limits: narrow) }
        let before = try Fixture.projection(Self.entries(3))
        let after = try Fixture.projection(Self.entries(1), sequence: 2, revisions: revisions)
        #expect(throws: PeerStatusError.tooManyEntries(count: 3, limit: 2)) {
            try before.delta(to: after, limits: narrow)
        }
    }

    @Test func applyingRefusesADeltaAboveTheReceiversOwnDeltaLimit() throws {
        let wide = try Fixture.limits(snapshot: 8, delta: 3)
        let narrow = try Fixture.limits(snapshot: 8, delta: 2)
        let delta = try PeerStatusDelta.make(
            stamp: Fixture.stamp(sequence: 2, revisions: Fixture.revisions(capability: 1)),
            upserts: Self.entries(3), removals: [], limits: wide)
        let base = try Fixture.projection([])
        #expect(try base.applying(delta, limits: wide).entries.count == 3)
        #expect(throws: PeerStatusError.deltaTooLarge(count: 3, limit: 2)) { try base.applying(delta, limits: narrow) }
    }

    @Test func applyingKeepsTheResultAtTheSnapshotLimitAndRefusesOneMore() throws {
        let limits = try Fixture.limits(snapshot: 3, delta: 4)
        let base = try Fixture.projection(Self.entries(2), limits: limits)
        let revisions = try Fixture.revisions(capability: 1)
        let extra = try Self.ids(4)
        let fits = try PeerStatusDelta.make(
            stamp: Fixture.stamp(sequence: 2, revisions: revisions),
            upserts: [Fixture.entry(extra[2])], removals: [], limits: limits)
        #expect(try base.applying(fits, limits: limits).entries.count == 3)
        let over = try PeerStatusDelta.make(
            stamp: Fixture.stamp(sequence: 2, revisions: revisions),
            upserts: [Fixture.entry(extra[2]), Fixture.entry(extra[3])], removals: [], limits: limits)
        #expect(throws: PeerStatusError.tooManyEntries(count: 4, limit: 3)) { try base.applying(over, limits: limits) }
    }

    @Test func aRemovalFreesRoomForAnUpsertAtTheSnapshotLimit() throws {
        let limits = try Fixture.limits(snapshot: 2, delta: 4)
        let base = try Fixture.projection(Self.entries(2), limits: limits)
        let delta = try PeerStatusDelta.make(
            stamp: Fixture.stamp(sequence: 2, revisions: Fixture.revisions(capability: 1)),
            upserts: [Fixture.entry(Self.ids(3)[2])], removals: [Self.ids(2)[0]], limits: limits)
        #expect(try base.applying(delta, limits: limits).entries.map(\.id) == [Self.ids(2)[1], Self.ids(3)[2]])
    }
}
