import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigIdentityMatchTests {
    @Test func uidMatchUnderTheSameDeviceIDIsMatched() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a")])
        let report = try Fixture.match(rig, [Fixture.device("dev.a")])
        #expect(report.rig == (try RigProfileID("rig.a")))
        #expect(try Fixture.outcome(report, "dev.a") == .matched(DeviceID("dev.a")))
        #expect(report.mode == .full)
    }

    @Test func uidMatchUnderAnotherDeviceIDIsReportedRenumbered() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1")])
        let report = try Fixture.match(rig, [Fixture.device("dev.z", uid: "uid-1")])
        #expect(try Fixture.outcome(report, "dev.a") == .renumbered(from: DeviceID("dev.a"), to: DeviceID("dev.z")))
    }

    @Test func sameDeviceIDWithAnotherUIDIsNotAMatch() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1")])
        let report = try Fixture.match(rig, [Fixture.device("dev.a", uid: "uid-2")])
        #expect(try Fixture.outcome(report, "dev.a") == .missing)
        #expect(report.mode == .manualRemote)
    }

    @Test func swappedDeviceIDsAreBothRenumberedNotMatched() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1"), Fixture.saved("dev.b", uid: "uid-2")])
        let report = try Fixture.match(rig, [Fixture.device("dev.a", uid: "uid-2"),
                                             Fixture.device("dev.b", uid: "uid-1")])
        #expect(try Fixture.outcome(report, "dev.a") == .renumbered(from: DeviceID("dev.a"), to: DeviceID("dev.b")))
        #expect(try Fixture.outcome(report, "dev.b") == .renumbered(from: DeviceID("dev.b"), to: DeviceID("dev.a")))
        #expect(report.mode == .full)
    }

    @Test func unknownUIDWithOtherObservedDevicesIsMissing() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-wanted")])
        let report = try Fixture.match(rig, [Fixture.device("dev.a"), Fixture.device("dev.b")])
        #expect(try Fixture.outcome(report, "dev.a") == .missing)
    }

    @Test func identicalModelDevicesStayDistinctByUID() throws {
        let evidence: Set<IdentityEvidence> = [.deviceUID, .modelUID, .transport, .channelLayout]
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1"), Fixture.saved("dev.b", uid: "uid-2")])
        let observed = try [Fixture.device("dev.x", uid: "uid-2", evidence: evidence),
                            Fixture.device("dev.y", uid: "uid-1", evidence: evidence)]
        let report = try Fixture.match(rig, observed)
        #expect(try Fixture.outcome(report, "dev.a") == .renumbered(from: DeviceID("dev.a"), to: DeviceID("dev.y")))
        #expect(try Fixture.outcome(report, "dev.b") == .renumbered(from: DeviceID("dev.b"), to: DeviceID("dev.x")))
    }

    @Test func modelOnlyEvidenceCannotBeAnIdentity() {
        let refused = [Set<IdentityEvidence>([.modelUID]), [.transport, .channelLayout, .modelUID], []]
        for evidence in refused {
            #expect(throws: (any Error).self) { try DeviceIdentity(.init(uid: "uid-1", evidence: evidence)) }
        }
    }

    @Test func endpointUIDEvidenceAloneParticipates() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1")])
        let report = try Fixture.match(rig, [Fixture.device("dev.a", uid: "uid-1", evidence: [.endpointUID])])
        #expect(try Fixture.outcome(report, "dev.a") == .matched(DeviceID("dev.a")))
    }

    @Test func canonicallyEquivalentUIDsDoNotMatch() throws {
        #expect(Fixture.precomposed == Fixture.decomposed)
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: Fixture.precomposed)])
        let report = try Fixture.match(rig, [Fixture.device("dev.a", uid: Fixture.decomposed)])
        #expect(try Fixture.outcome(report, "dev.a") == .missing)
        let both = try Fixture.match(rig, [Fixture.device("dev.p", uid: Fixture.precomposed),
                                           Fixture.device("dev.q", uid: Fixture.decomposed)])
        #expect(try Fixture.outcome(both, "dev.a") == .renumbered(from: DeviceID("dev.a"), to: DeviceID("dev.p")))
    }

    @Test func uidsDifferingOnlyInTheLastScalarStayDistinct() throws {
        let long = String(repeating: "u", count: 1_023)
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: long + "1")])
        let report = try Fixture.match(rig, [Fixture.device("dev.a", uid: long + "2"),
                                             Fixture.device("dev.b", uid: long)])
        #expect(try Fixture.outcome(report, "dev.a") == .missing)
        let exact = try Fixture.match(rig, [Fixture.device("dev.a", uid: long + "1")])
        #expect(try Fixture.outcome(exact, "dev.a") == .matched(DeviceID("dev.a")))
    }

    @Test func twoPresentDescriptorsAreAmbiguousAndNeitherIsPicked() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.z", uid: "uid-1")])
        let observed = try [Fixture.device("dev.z", uid: "uid-1"), Fixture.device("dev.a", uid: "uid-1")]
        for order in [observed, Array(observed.reversed())] {
            let report = try Fixture.match(rig, order)
            #expect(try Fixture.outcome(report, "dev.z") == .ambiguous([DeviceID("dev.a"), DeviceID("dev.z")]))
            #expect(report.mode == .manualRemote)
        }
    }

    @Test func ambiguityOutranksAnAbsentDescriptorWithTheSameUID() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1")])
        let observed = try [Fixture.device("dev.m", uid: "uid-1", presence: .missing),
                            Fixture.device("dev.p", uid: "uid-1"), Fixture.device("dev.q", uid: "uid-1")]
        let report = try Fixture.match(rig, observed)
        #expect(try Fixture.outcome(report, "dev.a") == .ambiguous([DeviceID("dev.p"), DeviceID("dev.q")]))
    }

    @Test func onePresentDescriptorOutranksAbsentDescriptorsWithTheSameUID() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1")])
        let observed = try [Fixture.device("dev.m", uid: "uid-1", presence: .missing),
                            Fixture.device("dev.s", uid: "uid-1", presence: .stale),
                            Fixture.device("dev.a", uid: "uid-1")]
        let report = try Fixture.match(rig, observed)
        #expect(try Fixture.outcome(report, "dev.a") == .matched(DeviceID("dev.a")))
    }

    @Test func onlyPresentDescriptorsCountTowardAmbiguity() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1")])
        let observed = try [Fixture.device("dev.a", uid: "uid-1"),
                            Fixture.device("dev.s", uid: "uid-1", presence: .stale)]
        #expect(try Fixture.outcome(Fixture.match(rig, observed), "dev.a") == .matched(DeviceID("dev.a")))
    }

    @Test func absentDescriptorsReportTheirPresenceAndNeverMatch() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1"), Fixture.saved("dev.b", uid: "uid-2"),
                                            Fixture.saved("dev.c", uid: "uid-3")])
        let observed = try [Fixture.device("dev.a", uid: "uid-1", presence: .missing),
                            Fixture.device("dev.b", uid: "uid-2", presence: .stale)]
        let report = try Fixture.match(rig, observed)
        #expect(try Fixture.outcome(report, "dev.a") == .absentPresence(.missing))
        #expect(try Fixture.outcome(report, "dev.b") == .absentPresence(.stale))
        #expect(try Fixture.outcome(report, "dev.c") == .missing)
        #expect(report.mode == .manualRemote)
    }

    @Test func missingOutranksStaleWhateverTheOrder() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1")])
        let observed = try [Fixture.device("dev.1", uid: "uid-1", presence: .stale),
                            Fixture.device("dev.2", uid: "uid-1", presence: .missing)]
        for order in [observed, Array(observed.reversed())] {
            #expect(try Fixture.outcome(Fixture.match(rig, order), "dev.a") == .absentPresence(.missing))
        }
    }

    @Test func rowsAreSortedBySavedDeviceID() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.c"), Fixture.saved("dev.a"), Fixture.saved("dev.b")])
        let report = try Fixture.match(rig, [])
        #expect(report.rows.map(\.saved.id.rawValue) == ["dev.a", "dev.b", "dev.c"])
    }

    @Test func reportsAreEqualForShuffledSavedAndObservedOrder() throws {
        let saved = try [Fixture.saved("dev.a"), Fixture.saved("dev.b"), Fixture.saved("dev.c", uid: "uid-9"),
                         Fixture.saved("dev.d", uid: "uid-8", required: false)]
        let observed = try [Fixture.device("dev.a"), Fixture.device("dev.y", uid: "uid-9"),
                            Fixture.device("dev.m", uid: "uid-8", presence: .missing),
                            Fixture.device("dev.b"), Fixture.device("dev.n", uid: "uid-b")]
        let forward = try Fixture.match(Fixture.rig("rig.a", saved), observed)
        let reversed = try Fixture.match(Fixture.rig("rig.a", saved.reversed()), observed.reversed())
        #expect(forward == reversed)
        #expect(forward.mode == .full)
    }

    @Test func matchingKeepsTheSavedDeviceInEveryRow() throws {
        let device = try Fixture.saved("dev.a", uid: "uid-1", required: false, role: "rol.keys")
        let report = try Fixture.match(Fixture.rig("rig.a", [device]), [])
        let row = try #require(report.rows.first)
        #expect(report.rows.count == 1 && row.saved == device && row.outcome == .missing)
    }

    @Test func a1024ObservedListStillMatchesItsLastDescriptor() throws {
        var observed = try Fixture.observedRun(1_023)
        observed.append(try Fixture.device("dev.target", uid: "uid-target"))
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.old", uid: "uid-target")])
        let report = try Fixture.match(rig, observed)
        let expected = try RigMatchOutcome.renumbered(from: DeviceID("dev.old"), to: DeviceID("dev.target"))
        #expect(try Fixture.outcome(report, "dev.old") == expected)
    }
}
