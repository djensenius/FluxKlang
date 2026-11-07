import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerStatusProjectionTests {
    private static func make(
        unit: ParameterUnit = .normalized, lower: Double = 0, upper: Double = 1,
        controlClass: ControlClass = .live, writable: Bool = false
    ) throws(PeerStatusError) -> PeerStatusEntry {
        try PeerStatusEntry.make(.init(id: Fixture.alpha, unit: unit, lower: lower, upper: upper,
                                       controlClass: controlClass, verification: .measured, writable: writable))
    }

    private static func fault(_ expected: PeerStatusEntryFault, _ build: () throws -> PeerStatusEntry) -> Bool {
        do {
            _ = try build()
            return false
        } catch {
            return (error as? PeerStatusError) == .invalidEntry(Fixture.alpha, expected)
        }
    }

    @Test func aValidEntryKeepsEveryField() throws {
        let entry = try PeerStatusEntry.make(.init(id: Fixture.bravo, unit: .decibels, lower: -90, upper: 10,
                                                   controlClass: .live, verification: .unverified, writable: true))
        #expect(entry.id == Fixture.bravo)
        #expect(entry.unit == .decibels)
        #expect(entry.lower == -90)
        #expect(entry.upper == 10)
        #expect(entry.controlClass == .live)
        #expect(entry.verification == .unverified)
        #expect(entry.writable)
    }

    @Test func aNonFiniteBoundIsRefusedForEveryNonFiniteValueAndSide() {
        #expect(Self.fault(.nonFiniteBound) { try Self.make(lower: .nan) })
        #expect(Self.fault(.nonFiniteBound) { try Self.make(upper: .nan) })
        #expect(Self.fault(.nonFiniteBound) { try Self.make(unit: .decibels, lower: -.infinity, upper: 1) })
        #expect(Self.fault(.nonFiniteBound) { try Self.make(unit: .decibels, lower: 0, upper: .infinity) })
    }

    @Test func invertedBoundsAreRefusedAndEqualBoundsAreAccepted() throws {
        #expect(Self.fault(.invertedBounds) { try Self.make(lower: 0.6, upper: 0.5) })
        let flat = try Self.make(lower: 0.5, upper: 0.5)
        #expect(flat.lower == flat.upper)
    }

    @Test func everyClassOtherThanLiveIsRefusedAsNotLive() {
        for controlClass in ControlClass.allCases where controlClass != .live {
            #expect(Self.fault(.notLive(controlClass)) { try Self.make(controlClass: controlClass) })
        }
    }

    @Test func theUnitBoundsOfBooleanNormalizedPercentAndIndexAreEnforced() throws {
        _ = try Self.make(unit: .boolean, lower: 0, upper: 1)
        #expect(Self.fault(.unitBounds(.boolean)) { try Self.make(unit: .boolean, lower: 0, upper: 2) })
        #expect(Self.fault(.unitBounds(.boolean)) { try Self.make(unit: .boolean, lower: 0.5, upper: 1) })
        _ = try Self.make(unit: .normalized, lower: 0, upper: 1)
        #expect(Self.fault(.unitBounds(.normalized)) { try Self.make(unit: .normalized, lower: -0.5, upper: 1) })
        #expect(Self.fault(.unitBounds(.normalized)) { try Self.make(unit: .normalized, lower: 0, upper: 1.5) })
        _ = try Self.make(unit: .percent, lower: 0, upper: 100)
        #expect(Self.fault(.unitBounds(.percent)) { try Self.make(unit: .percent, lower: 0, upper: 100.5) })
        #expect(Self.fault(.unitBounds(.percent)) { try Self.make(unit: .percent, lower: -1, upper: 100) })
        _ = try Self.make(unit: .index, lower: 1, upper: 12)
        #expect(Self.fault(.unitBounds(.index)) { try Self.make(unit: .index, lower: 1.5, upper: 12) })
        #expect(Self.fault(.unitBounds(.index)) { try Self.make(unit: .index, lower: 1, upper: 12.5) })
        _ = try Self.make(unit: .decibels, lower: -90, upper: 10)
        _ = try Self.make(unit: .pan, lower: -1, upper: 1)
    }

    @Test func entryFaultsAreCheckedNonFiniteThenInvertedThenClassThenUnit() {
        #expect(Self.fault(.nonFiniteBound) {
            try Self.make(lower: .infinity, upper: -.infinity, controlClass: .hazardous)
        })
        #expect(Self.fault(.invertedBounds) { try Self.make(lower: 1, upper: 0, controlClass: .structural) })
        #expect(Self.fault(.notLive(.structural)) {
            try Self.make(unit: .boolean, lower: 0, upper: 5, controlClass: .structural)
        })
        #expect(Self.fault(.unitBounds(.boolean)) { try Self.make(unit: .boolean, lower: 0, upper: 5) })
    }

    @Test func aFaultNamesTheIdOfTheRefusedEntry() {
        do {
            _ = try PeerStatusEntry.make(.init(id: Fixture.charlie, unit: .normalized, lower: .nan, upper: 1,
                                               controlClass: .live, verification: .reported, writable: false))
            Issue.record("a NaN bound was accepted")
        } catch {
            #expect(error == .invalidEntry(Fixture.charlie, .nonFiniteBound))
        }
    }

    @Test func projectingADescriptorEqualsMakingTheEntryFromItsFields() throws {
        let descriptor = try Fixture.descriptor(Fixture.alpha, unit: .decibels, lower: -90, upper: 10,
                                                verification: .unverified, ceiling: 0)
        let granted = try Fixture.controller([Fixture.alpha])
        let projected = try #require(PeerStatusEntry.project(descriptor, grants: granted))
        let made = try PeerStatusEntry.make(.init(id: Fixture.alpha, unit: .decibels, lower: -90, upper: 10,
                                                  controlClass: .live, verification: .unverified, writable: true))
        #expect(projected == made)
        let observed = try #require(PeerStatusEntry.project(descriptor, grants: Fixture.observer()))
        #expect(!observed.writable)
        #expect(observed.lower == projected.lower)
    }

    @Test func projectingAHazardousOrStructuralDescriptorGivesNothingEvenWithAGrant() throws {
        let grants = try Fixture.controller([Fixture.hazardous, Fixture.structural], statusRead: true)
        for controlClass in [ControlClass.hazardous, .structural] {
            let descriptor = try Fixture.descriptor(Fixture.hazardous, controlClass: controlClass)
            #expect(PeerStatusEntry.project(descriptor, grants: grants) == nil)
        }
    }

    @Test func aGrantForAnotherParameterDoesNotMakeThisOneVisibleOrWritable() throws {
        let descriptor = try Fixture.descriptor(Fixture.alpha)
        #expect(PeerStatusEntry.project(descriptor, grants: try Fixture.controller([Fixture.bravo])) == nil)
        let seen = try #require(PeerStatusEntry.project(
            descriptor, grants: Fixture.controller([Fixture.bravo], statusRead: true)))
        #expect(!seen.writable)
    }

    @Test func entriesAreSortedAndDuplicatesAreReportedByTheSmallestId() throws {
        let alpha = try Fixture.entry(Fixture.alpha)
        let bravo = try Fixture.entry(Fixture.bravo)
        let charlie = try Fixture.entry(Fixture.charlie)
        #expect([charlie, alpha, bravo].sortedByID().map(\.id) == [Fixture.alpha, Fixture.bravo, Fixture.charlie])
        #expect([bravo, charlie, charlie, bravo].smallestDuplicateID() == Fixture.bravo)
        #expect([charlie, bravo, bravo, charlie].smallestDuplicateID() == Fixture.bravo)
        #expect([alpha, bravo, charlie].smallestDuplicateID() == nil)
    }
}
