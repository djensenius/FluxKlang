import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("PeerStatusProjectionTests")
struct PeerStatusProjectionTests {
    enum FixtureError: Error { case invalid }

    enum Fixture {
        static let alpha = ParameterID(validated: "par.a")
        static let bravo = ParameterID(validated: "par.b")
        static let charlie = ParameterID(validated: "par.c")
        static let delta = ParameterID(validated: "par.d")
        static let structural = ParameterID(validated: "par.s")
        static let hazardous = ParameterID(validated: "par.h")

        static func descriptor(
            _ id: ParameterID, unit: ParameterUnit = .normalized, lower: Double = 0, upper: Double = 1,
            controlClass: ControlClass = .live, verification: MeasurementStatus = .reported,
            ceiling: Double? = nil, defaultValue: Double? = nil
        ) throws -> ParameterDescriptor {
            try ParameterDescriptor(.init(
                id: id, unit: unit, lower: lower, upper: upper, defaultValue: defaultValue ?? lower,
                ceiling: ceiling, curve: .linear, ramp: .step, controlClass: controlClass,
                verification: verification
            ))
        }

        static func standardCatalog() throws -> ParameterCatalog {
            try ParameterCatalog([
                descriptor(alpha), descriptor(bravo), descriptor(charlie),
                descriptor(structural, controlClass: .structural), descriptor(hazardous, controlClass: .hazardous)
            ])
        }

        static func generation(_ value: Int) throws -> Generation { try Generation(value) }

        static func revision(_ value: Int) throws -> ContractRevision { try ContractRevision(value) }

        static func sequence(_ value: Int) throws -> PeerSequence { try PeerSequence(value) }

        static func revisions(patch: Int = 0, capability: Int = 0, permission: Int = 0,
                              parameter: Int = 0, graph: Int = 0) throws -> CommandRevisions {
            try CommandRevisions(patch: revision(patch), capability: revision(capability),
                                 permission: revision(permission), parameter: revision(parameter),
                                 graph: revision(graph))
        }

        static func session(host hostGeneration: Int = 1,
                            connection connectionGeneration: Int = 1) throws -> PeerSyncSession {
            let host = HostID(validated: "host.c1")
            let epoch = try ConnectionEpoch(connection: ConnectionID(validated: "connection.c1"), host: host,
                                            generation: generation(connectionGeneration))
            let hostEpoch = try HostEpoch(host: host, generation: generation(hostGeneration))
            guard let session = PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: epoch) else {
                throw FixtureError.invalid
            }
            return session
        }

        static func stamp(session: PeerSyncSession? = nil, sequence: Int = 1,
                          revisions: CommandRevisions? = nil) throws -> PeerStatusStamp {
            try PeerStatusStamp(session: session ?? self.session(), sequence: self.sequence(sequence),
                                revisions: revisions ?? self.revisions())
        }

        static func limits(snapshot: Int, delta: Int) throws -> PeerSyncLimits {
            guard let limits = PeerSyncLimits(maximumSnapshotValues: snapshot, maximumDeltaChanges: delta) else {
                throw FixtureError.invalid
            }
            return limits
        }

        static func observer() throws -> PeerGrantSet {
            try PeerGrantSet(role: .observer, commands: [], reads: [.statusRead])
        }

        static func controller(_ ids: [ParameterID], statusRead: Bool = false) throws -> PeerGrantSet {
            try PeerGrantSet(role: .remoteController,
                             commands: Set(ids.map { PeerCommandGrant(controlClass: .live, scope: .parameter($0)) }),
                             reads: statusRead ? [.statusRead] : [])
        }

        static func entry(
            _ id: ParameterID, writable: Bool = false, unit: ParameterUnit = .normalized, lower: Double = 0,
            upper: Double = 1, verification: MeasurementStatus = .reported
        ) throws -> PeerStatusEntry {
            try PeerStatusEntry.make(.init(id: id, unit: unit, lower: lower, upper: upper, controlClass: .live,
                                           verification: verification, writable: writable))
        }

        static func projection(
            _ entries: [PeerStatusEntry], sequence: Int = 1, revisions: CommandRevisions? = nil,
            session: PeerSyncSession? = nil, limits: PeerSyncLimits = .standard
        ) throws -> PeerStatusProjection {
            try PeerStatusProjection.make(
                stamp: stamp(session: session, sequence: sequence, revisions: revisions),
                entries: entries, limits: limits)
        }

        static func published(_ catalog: ParameterCatalog, grants: PeerGrantSet, sequence: Int = 1,
                              limits: PeerSyncLimits = .standard) throws -> PeerStatusProjection {
            try PeerStatusProjection.make(stamp: stamp(sequence: sequence), catalog: catalog, grants: grants,
                                          limits: limits)
        }
    }

    @Test func anObserverSeesEveryLiveEntryAndWritesNone() throws {
        let projection = try Fixture.published(Fixture.standardCatalog(), grants: Fixture.observer())
        #expect(projection.entries.map(\.id) == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
        #expect(projection.entries.allSatisfy { !$0.writable })
        let first = try #require(projection.entries.first)
        #expect(first == (try Fixture.entry(Fixture.alpha)))
        #expect(first.controlClass == .live)
    }

    @Test func aRemoteControllerWithoutStatusReadSeesOnlyItsGrantedParametersAsWritable() throws {
        let projection = try Fixture.published(Fixture.standardCatalog(), grants: Fixture.controller([Fixture.bravo]))
        #expect(projection.entries == [try Fixture.entry(Fixture.bravo, writable: true)])
    }

    @Test func aRemoteControllerWithStatusReadSeesEveryLiveEntryAndWritesOnlyTheGrantedOnes() throws {
        let grants = try Fixture.controller([Fixture.alpha, Fixture.charlie], statusRead: true)
        let projection = try Fixture.published(Fixture.standardCatalog(), grants: grants)
        #expect(projection.entries.map(\.id) == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
        #expect(projection.entries.map(\.writable) == [true, false, true])
    }

    @Test func structuralAndHazardousDescriptorsAreNeverProjectedEvenWhenGrantedOrObserved() throws {
        let catalog = try Fixture.standardCatalog()
        let granted = try Fixture.controller([Fixture.structural, Fixture.hazardous, Fixture.alpha], statusRead: true)
        for grants in try [Fixture.observer(), granted] {
            let ids = try Fixture.published(catalog, grants: grants).entries.map(\.id)
            #expect(!ids.contains(Fixture.structural))
            #expect(!ids.contains(Fixture.hazardous))
            #expect(ids == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
        }
        let onlyGranted = try Fixture.published(catalog, grants: Fixture.controller([Fixture.structural]))
        #expect(onlyGranted.entries.isEmpty)
    }

    @Test func aPeerWithNoMatchingGrantSeesAnEmptyProjectionWithoutError() throws {
        let grants = try Fixture.controller([ParameterID(validated: "par.unknown")])
        let projection = try Fixture.published(Fixture.standardCatalog(), grants: grants)
        #expect(projection.entries.isEmpty)
        #expect(projection.sequence == (try Fixture.sequence(1)))
    }

    @Test func aGrantForAParameterMissingFromTheCatalogAddsNothing() throws {
        let grants = try Fixture.controller([Fixture.alpha, ParameterID(validated: "par.unknown")])
        let projection = try Fixture.published(Fixture.standardCatalog(), grants: grants)
        #expect(projection.entries == [try Fixture.entry(Fixture.alpha, writable: true)])
    }

    @Test func anEntryCarriesTheBoundsAndNeverTheDefaultOrTheCeiling() throws {
        let capped = try Fixture.descriptor(Fixture.alpha, lower: 0.1, upper: 0.9, ceiling: 0.5, defaultValue: 0.3)
        let projection = try Fixture.published(ParameterCatalog([capped]), grants: Fixture.observer())
        let entry = try #require(projection.entries.first)
        #expect(entry.lower == 0.1)
        #expect(entry.upper == 0.9)
        let entryLabels = Mirror(reflecting: entry).children.compactMap(\.label)
        #expect(entryLabels == ["id", "unit", "lower", "upper", "controlClass", "verification", "writable"])
        let projectionLabels = Mirror(reflecting: projection).children.compactMap(\.label)
        #expect(projectionLabels == ["session", "sequence", "revisions", "entries"])
    }

    @Test func theVerificationStatusAndUnitAreCopiedFromTheDescriptor() throws {
        let catalog = try ParameterCatalog([
            Fixture.descriptor(Fixture.alpha, unit: .decibels, lower: -90, upper: 10, verification: .measured),
            Fixture.descriptor(Fixture.bravo, unit: .percent, lower: 0, upper: 100, verification: .unverified),
            Fixture.descriptor(Fixture.charlie, unit: .pan, lower: -1, upper: 1, verification: .reported)
        ])
        let entries = try Fixture.published(catalog, grants: Fixture.observer()).entries
        #expect(entries.map(\.verification) == [.measured, .unverified, .reported])
        #expect(entries.map(\.unit) == [.decibels, .percent, .pan])
        #expect(entries.map(\.lower) == [-90, 0, -1])
        #expect(entries.map(\.upper) == [10, 100, 1])
    }

    @Test func theProjectionKeepsTheSessionSequenceAndRevisionsOfThePublisher() throws {
        let revisions = try Fixture.revisions(patch: 1, capability: 2, permission: 3, parameter: 4, graph: 5)
        let session = try Fixture.session(host: 2, connection: 3)
        let projection = try PeerStatusProjection.make(
            stamp: Fixture.stamp(session: session, sequence: 7, revisions: revisions),
            catalog: Fixture.standardCatalog(), grants: Fixture.observer(), limits: .standard)
        #expect(projection.session == session)
        #expect(projection.sequence == (try Fixture.sequence(7)))
        #expect(projection.revisions == revisions)
    }

    @Test func reversingTheCatalogGivesAnEqualProjection() throws {
        let descriptors = try [
            Fixture.descriptor(Fixture.alpha), Fixture.descriptor(Fixture.bravo), Fixture.descriptor(Fixture.charlie),
            Fixture.descriptor(Fixture.structural, controlClass: .structural),
            Fixture.descriptor(Fixture.hazardous, controlClass: .hazardous)
        ]
        let grants = try Fixture.controller([Fixture.alpha], statusRead: true)
        let forward = try Fixture.published(ParameterCatalog(descriptors), grants: grants)
        let backward = try Fixture.published(ParameterCatalog(descriptors.reversed()), grants: grants)
        #expect(forward == backward)
        #expect(backward.entries.map(\.id) == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
    }

    @Test func grantSetsBuiltFromDifferentlyOrderedInputsGiveEqualProjections() throws {
        let ids = [Fixture.charlie, Fixture.alpha, Fixture.bravo]
        let forward = try Fixture.published(Fixture.standardCatalog(), grants: Fixture.controller(ids))
        let backward = try Fixture.published(Fixture.standardCatalog(), grants: Fixture.controller(ids.reversed()))
        #expect(forward == backward)
        #expect(forward.entries.map(\.id) == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
    }

    @Test func entriesAreOrderedByTheUTF8BytesOfTheIdNotCaselessly() throws {
        let upper = ParameterID(validated: "par.B")
        let lower = ParameterID(validated: "par.a")
        let catalog = try ParameterCatalog([Fixture.descriptor(lower), Fixture.descriptor(upper)])
        #expect(try Fixture.published(catalog, grants: Fixture.observer()).entries.map(\.id) == [upper, lower])
        let reversed = try ParameterCatalog([Fixture.descriptor(upper), Fixture.descriptor(lower)])
        #expect(try Fixture.published(reversed, grants: Fixture.observer()).entries.map(\.id) == [upper, lower])
    }

    @Test func projectionsOfDifferentGrantsDiffer() throws {
        let observer = try Fixture.published(Fixture.standardCatalog(), grants: Fixture.observer())
        let controller = try Fixture.published(
            Fixture.standardCatalog(), grants: Fixture.controller([Fixture.alpha, Fixture.bravo, Fixture.charlie]))
        #expect(observer != controller)
        #expect(observer.entries.map(\.id) == controller.entries.map(\.id))
        #expect(controller.entries.allSatisfy { $0.writable })
    }
}
