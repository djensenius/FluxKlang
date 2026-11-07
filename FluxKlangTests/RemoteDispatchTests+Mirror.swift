import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteDispatchTests {
    /// The refusal `make` throws, or nil when it builds a mirror.
    static func refusal(making receiver: PeerSyncReceiver, catalog: ParameterCatalog) -> RemoteDispatchRefusal? {
        do throws(RemoteDispatchRefusal) {
            _ = try RemoteMirror.make(receiver: receiver, catalog: catalog)
            return nil
        } catch {
            return error
        }
    }

    static func bulkID(_ index: Int) throws -> ParameterID {
        try ParameterID("par.rr2.bulk-\(index)")
    }

    /// `count` normalized parameters `par.rr2.bulk-0`, `par.rr2.bulk-1`, ...
    static func bulkCatalog(_ count: Int) throws -> ParameterCatalog {
        try ParameterCatalog((0..<count).map { try descriptor(bulkID($0)) })
    }

    static func bulkValues(_ count: Int) throws -> [ParameterID: ParameterValue] {
        var values: [ParameterID: ParameterValue] = [:]
        for index in 0..<count { values[try bulkID(index)] = normalized(0.5) }
        return values
    }

    @Test func mirrorHoldsTheSyncedValuesRevisionsSequenceAndSession() throws {
        let session = try Self.session()
        let catalog = try Self.catalog()
        let mirror = try RemoteMirror.make(receiver: Self.syncedReceiver(session), catalog: catalog)
        let revisions = try Self.deltaRevisions()
        let sequence = try PeerSequence(6)
        #expect(mirror.truth.values == Self.hostValues)
        #expect(mirror.truth.catalog == catalog)
        #expect(mirror.revisions == revisions)
        #expect(mirror.sequence == sequence)
        #expect(mirror.session == session)
    }

    @Test func mirrorKeepsACatalogParameterWhoseValueWasRemoved() throws {
        let mirror = try Self.mirror()
        #expect(mirror.truth.catalog[Self.noValue] != nil)
        #expect(mirror.truth.values[Self.noValue] == nil)
        #expect(mirror.truth.values.count == 6)
    }

    @Test func mirrorsBuiltTwiceFromEqualReceiversAreEqual() throws {
        #expect(try Self.mirror() == Self.mirror())
        #expect(try Self.mirror(hostGeneration: 4) != Self.mirror(hostGeneration: 5))
    }

    @Test func mirrorOfAnAwaitingReceiverIsUnavailable() throws {
        let receiver = try PeerSyncReceiver(session: Self.session())
        let phase = receiver.phase
        #expect(Self.refusal(making: receiver, catalog: try Self.catalog()) == .mirrorUnavailable)
        #expect(receiver.phase == phase)
        #expect(phase == .awaitingSnapshot)
    }

    @Test func mirrorOfAResyncLatchedReceiverIsUnavailableAndAnEarlierMirrorKeepsItsValues() throws {
        let session = try Self.session()
        let catalog = try Self.catalog()
        var receiver = try Self.syncedReceiver(session)
        let earlier = try RemoteMirror.make(receiver: receiver, catalog: catalog)
        let gap = try PeerSyncDelta(
            session: session, sequence: PeerSequence(8), revisions: Self.deltaRevisions(),
            updates: [Self.levelA: Self.normalized(0.6)], removals: []
        )
        let request = try PeerResyncRequest(
            session: session, lastApplied: PeerSequence(6),
            reason: .gap(expected: PeerSequence(7), found: PeerSequence(8))
        )
        let event = receiver.receive(gap)
        #expect(event == .resyncRequested(request))
        #expect(receiver.state == nil)
        let latched = receiver.phase
        #expect(Self.refusal(making: receiver, catalog: catalog) == .mirrorUnavailable)
        #expect(receiver.phase == latched)
        #expect(earlier.truth.values == Self.hostValues)
        #expect(try earlier.sequence == PeerSequence(6))
    }

    @Test func mirrorAcceptsExactlyTheMaximumNumberOfValues() throws {
        let receiver = try Self.snapshotReceiver(Self.session(), values: Self.bulkValues(4096))
        let mirror = try RemoteMirror.make(receiver: receiver, catalog: Self.bulkCatalog(4096))
        #expect(mirror.truth.values.count == 4096)
        #expect(mirror.truth.catalog.parameters.count == 4096)
    }

    @Test func mirrorRefusesOneValueBeyondTheMaximumWithTheReceivedCount() throws {
        var values = try Self.bulkValues(4096)
        values[Self.missing] = Self.normalized(0.5)
        let limits = try #require(PeerSyncLimits(maximumSnapshotValues: 4097, maximumDeltaChanges: 1))
        let receiver = try Self.snapshotReceiver(Self.session(), values: values, limits: limits)
        let phase = receiver.phase
        #expect(receiver.state?.values.count == 4097)
        #expect(Self.refusal(making: receiver, catalog: try Self.bulkCatalog(4096)) == .tooManyValues(4097))
        #expect(receiver.phase == phase)
    }

    @Test func mirrorNamesTheSmallestUnknownParameter() throws {
        let low = try ParameterID("par.rr2.aa-unknown")
        let high = try ParameterID("par.rr2.zz-unknown")
        var values = Self.snapshotValues
        values[high] = Self.normalized(0.1)
        values[low] = Self.normalized(0.2)
        let receiver = try Self.snapshotReceiver(Self.session(), values: values)
        let phase = receiver.phase
        #expect(Self.refusal(making: receiver, catalog: try Self.catalog()) == .unknownParameter(low))
        #expect(receiver.phase == phase)
    }

    @Test func mirrorRefusesASingleUnknownParameterAmongKnownOnes() throws {
        var values = Self.snapshotValues
        values[Self.missing] = Self.normalized(0.3)
        let receiver = try Self.snapshotReceiver(Self.session(), values: values)
        #expect(Self.refusal(making: receiver, catalog: try Self.catalog()) == .unknownParameter(Self.missing))
    }

    @Test func mirrorAcceptsAnEmptyValueSet() throws {
        let receiver = try Self.snapshotReceiver(Self.session(), values: [:])
        let mirror = try RemoteMirror.make(receiver: receiver, catalog: Self.catalog())
        #expect(mirror.truth.values.isEmpty)
        #expect(mirror.truth.catalog.parameters.count == 7)
        #expect(try mirror.sequence == PeerSequence(5))
    }
}
