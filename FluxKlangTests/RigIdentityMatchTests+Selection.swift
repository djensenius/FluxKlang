import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigIdentityMatchTests {
    /// Required saved devices `dev.a`, `dev.b`, `dev.c` (UIDs `uid-<id>`); `observed` names the ids that appear.
    private func makeReport(required: [String], optional: [String] = [], observed: [String]) throws -> RigMatchReport {
        let saved = try required.map { try Fixture.saved($0) } + optional.map { try Fixture.saved($0, required: false) }
        return try Fixture.match(Fixture.rig("rig.a", saved), observed.map { try Fixture.device($0) })
    }

    @Test func modeIsFullWhenEveryRequiredDeviceMatches() throws {
        let report = try makeReport(required: ["dev.a", "dev.b"], observed: ["dev.a", "dev.b", "dev.x"])
        #expect(report.mode == .full)
    }

    @Test func modeIsPartialWithTheSortedSavedIDsOfUnmatchedRequiredDevices() throws {
        let saved = try [Fixture.saved("dev.d"), Fixture.saved("dev.c", uid: "uid-dup"), Fixture.saved("dev.b"),
                         Fixture.saved("dev.a", uid: "uid-ren")]
        let observed = try [Fixture.device("dev.d"), Fixture.device("dev.x", uid: "uid-dup"),
                            Fixture.device("dev.y", uid: "uid-dup"), Fixture.device("dev.r", uid: "uid-ren")]
        let report = try Fixture.match(Fixture.rig("rig.a", saved), observed)
        #expect(report.mode == .partial(missing: [try DeviceID("dev.b"), try DeviceID("dev.c")]))
    }

    @Test func modeIsManualRemoteWhenNoRequiredDeviceMatches() throws {
        let report = try makeReport(required: ["dev.a", "dev.b"], observed: ["dev.x"])
        #expect(report.mode == .manualRemote)
    }

    @Test func partialMissingListsEveryUnmatchedRequiredDeviceIncludingAbsentOnes() throws {
        let saved = try [Fixture.saved("dev.e"), Fixture.saved("dev.d"), Fixture.saved("dev.c"),
                         Fixture.saved("dev.b"), Fixture.saved("dev.a")]
        let observed = try [Fixture.device("dev.a"), Fixture.device("dev.b", presence: .stale),
                            Fixture.device("dev.c", presence: .missing)]
        let report = try Fixture.match(Fixture.rig("rig.a", saved), observed)
        #expect(try Fixture.outcome(report, "dev.b") == .absentPresence(.stale))
        #expect(try Fixture.outcome(report, "dev.c") == .absentPresence(.missing))
        let expected = try ["dev.b", "dev.c", "dev.d", "dev.e"].map { try DeviceID($0) }
        #expect(report.mode == .partial(missing: expected))
    }

    @Test func modeIsManualRemoteWhenEveryRequiredDeviceIsAmbiguous() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1"), Fixture.saved("dev.b", uid: "uid-2")])
        let observed = try [Fixture.device("dev.p", uid: "uid-1"), Fixture.device("dev.q", uid: "uid-1"),
                            Fixture.device("dev.r", uid: "uid-2"), Fixture.device("dev.s", uid: "uid-2")]
        #expect(try Fixture.match(rig, observed).mode == .manualRemote)
    }

    @Test func aRenumberedRequiredDeviceCountsAsMatched() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "uid-1"), Fixture.saved("dev.b")])
        let observed = try [Fixture.device("dev.r", uid: "uid-1")]
        #expect(try Fixture.match(rig, observed).mode == .partial(missing: [try DeviceID("dev.b")]))
    }

    @Test func optionalDevicesNeverLowerTheMode() throws {
        let report = try makeReport(required: ["dev.a"], optional: ["dev.o1", "dev.o2"], observed: ["dev.a"])
        #expect(report.mode == .full)
        let none = try makeReport(required: ["dev.a", "dev.b"], optional: ["dev.o1"], observed: ["dev.a"])
        #expect(none.mode == .partial(missing: [try DeviceID("dev.b")]))
    }

    @Test func aMatchedOptionalDeviceNeverLiftsManualRemote() throws {
        let report = try makeReport(required: ["dev.a"], optional: ["dev.o1"], observed: ["dev.o1"])
        #expect(report.mode == .manualRemote)
        #expect(try Fixture.outcome(report, "dev.o1") == .matched(DeviceID("dev.o1")))
    }

    @Test func aRigWithOnlyOptionalDevicesIsFullEvenWithNothingObserved() throws {
        let report = try makeReport(required: [], optional: ["dev.o1", "dev.o2"], observed: [])
        #expect(report.mode == .full)
        #expect(report.rows.count == 2)
    }

    @Test func oneFullRigIsSelected() throws {
        let rigs = try [Fixture.rig("rig.b", [Fixture.saved("dev.b")]), Fixture.rig("rig.a", [Fixture.saved("dev.a")])]
        let result = try RigSelection.choose(rigs: rigs, observed: [Fixture.device("dev.a")])
        #expect(result.choice == .selected(try RigProfileID("rig.a")))
    }

    @Test func twoFullRigsAreAmbiguousSortedAndNeverTheFirst() throws {
        let rigs = try [Fixture.rig("rig.z", [Fixture.saved("dev.a")]), Fixture.rig("rig.m", [Fixture.saved("dev.a")]),
                        Fixture.rig("rig.c", [Fixture.saved("dev.q")])]
        let observed = try [Fixture.device("dev.a")]
        let expected = RigChoice.ambiguous([try RigProfileID("rig.m"), try RigProfileID("rig.z")])
        #expect(try RigSelection.choose(rigs: rigs, observed: observed).choice == expected)
        #expect(try RigSelection.choose(rigs: rigs.reversed(), observed: observed).choice == expected)
    }

    @Test func noFullRigChoosesNoneAndKeepsEveryPartialReport() throws {
        let rigs = try [Fixture.rig("rig.b", [Fixture.saved("dev.a"), Fixture.saved("dev.b")]),
                        Fixture.rig("rig.a", [Fixture.saved("dev.z")])]
        let result = try RigSelection.choose(rigs: rigs, observed: [Fixture.device("dev.a")])
        #expect(result.choice == .none)
        #expect(result.reports.map(\.rig.rawValue) == ["rig.a", "rig.b"])
        #expect(result.reports.map(\.mode) == [.manualRemote, .partial(missing: [try DeviceID("dev.b")])])
    }

    @Test func aPartialRigDoesNotCompeteWithAFullRig() throws {
        let rigs = try [Fixture.rig("rig.a", [Fixture.saved("dev.a"), Fixture.saved("dev.b")]),
                        Fixture.rig("rig.b", [Fixture.saved("dev.a")])]
        let result = try RigSelection.choose(rigs: rigs, observed: [Fixture.device("dev.a")])
        #expect(result.choice == .selected(try RigProfileID("rig.b")))
    }

    @Test func selectionReportsEqualEachRigsOwnMatch() throws {
        let first = try Fixture.rig("rig.a", [Fixture.saved("dev.a"), Fixture.saved("dev.b", uid: "uid-r")])
        let second = try Fixture.rig("rig.b", [Fixture.saved("dev.c")])
        let observed = try [Fixture.device("dev.a"), Fixture.device("dev.n", uid: "uid-r")]
        let result = try RigSelection.choose(rigs: [second, first], observed: observed)
        #expect(result.reports == [try Fixture.match(first, observed), try Fixture.match(second, observed)])
    }

    @Test func selectionAccepts16RigsAndRefuses17() throws {
        let rigs = try (0..<17).map { try Fixture.rig("rig.\(Fixture.pad($0))", []) }
        let accepted = try RigSelection.choose(rigs: Array(rigs.prefix(16)), observed: [])
        #expect(accepted.reports.count == 16)
        let refusal = Fixture.refusal { try RigSelection.choose(rigs: rigs, observed: []) }
        #expect(refusal == .tooManyRigs(count: 17, maximum: 16))
    }

    @Test func observedListAccepts1024AndRefuses1025ForMatchAndChoose() throws {
        let rig = try Fixture.rig("rig.a", [])
        let observed = try Fixture.observedRun(1_025)
        _ = try Fixture.match(rig, Array(observed.prefix(1_024)))
        _ = try RigSelection.choose(rigs: [rig], observed: Array(observed.prefix(1_024)))
        let expected = RigIdentityRefusal.tooManyObserved(count: 1_025, maximum: 1_024)
        #expect(Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: observed) } == expected)
        #expect(Fixture.refusal { try RigSelection.choose(rigs: [rig], observed: observed) } == expected)
    }

    @Test func repeatedObservedDeviceIDRefusesTheSmallestInEitherOrder() throws {
        let observed = try [Fixture.device("dev.c", uid: "u1"), Fixture.device("dev.b", uid: "u2"),
                            Fixture.device("dev.c", uid: "u3"), Fixture.device("dev.b", uid: "u4"),
                            Fixture.device("dev.a", uid: "u5")]
        let rig = try Fixture.rig("rig.a", [])
        for order in [observed, Array(observed.reversed())] {
            let expected = RigIdentityRefusal.duplicateObservedDevice(try DeviceID("dev.b"))
            #expect(Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: order) } == expected)
            #expect(Fixture.refusal { try RigSelection.choose(rigs: [rig], observed: order) } == expected)
        }
    }

    @Test func observedCountIsRefusedBeforeARepeatedObservedID() throws {
        var observed = try Fixture.observedRun(1_025)
        observed[1_024] = try Fixture.device("dev.0000", uid: "uid-other")
        let rig = try Fixture.rig("rig.a", [])
        let expected = RigIdentityRefusal.tooManyObserved(count: 1_025, maximum: 1_024)
        #expect(Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: observed) } == expected)
    }

    @Test func matchRefusesTheObservedListBeforeTheRig() throws {
        let observed = try Fixture.observedRun(1_025)
        let rig = try Fixture.handBuilt("rig.a", Fixture.savedRun(65))
        let expected = RigIdentityRefusal.tooManyObserved(count: 1_025, maximum: 1_024)
        #expect(Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: observed) } == expected)
        let repeated = try [Fixture.device("dev.a", uid: "u1"), Fixture.device("dev.a", uid: "u2")]
        let second = Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: repeated) }
        #expect(second == .duplicateObservedDevice(try DeviceID("dev.a")))
    }

    @Test func chooseRefusesTheRigCountBeforeTheObservedCount() throws {
        let rigs = try (0..<17).map { try Fixture.rig("rig.\(Fixture.pad($0))", []) }
        let observed = try Fixture.observedRun(1_025)
        let refusal = Fixture.refusal { try RigSelection.choose(rigs: rigs, observed: observed) }
        #expect(refusal == .tooManyRigs(count: 17, maximum: 16))
    }

    @Test func chooseRefusesRepeatedObservedIDBeforeARepeatedRig() throws {
        let rig = try Fixture.rig("rig.a", [])
        let observed = try [Fixture.device("dev.a", uid: "u1"), Fixture.device("dev.a", uid: "u2")]
        let refusal = Fixture.refusal { try RigSelection.choose(rigs: [rig, rig], observed: observed) }
        #expect(refusal == .duplicateObservedDevice(try DeviceID("dev.a")))
    }

    @Test func chooseRefusesARepeatedRigBeforeAnyRigContent() throws {
        let bad = try Fixture.handBuilt("rig.a", Fixture.savedRun(65))
        let other = try Fixture.rig("rig.b", [])
        let repeated = try Fixture.rig("rig.b", [Fixture.saved("dev.a")])
        for order in [[bad, other, repeated], [repeated, other, bad]] {
            let refusal = Fixture.refusal { try RigSelection.choose(rigs: order, observed: []) }
            #expect(refusal == .duplicateRig(try RigProfileID("rig.b")))
        }
    }

    @Test func chooseValidatesRigsInAscendingIDOrder() throws {
        let tooMany = try Fixture.handBuilt("rig.b", Fixture.savedRun(65))
        let repeated = try Fixture.handBuilt("rig.a", [Fixture.saved("dev.a"), Fixture.saved("dev.a", uid: "other")])
        for order in [[tooMany, repeated], [repeated, tooMany]] {
            let refusal = Fixture.refusal { try RigSelection.choose(rigs: order, observed: []) }
            #expect(refusal == .duplicateDevice(try DeviceID("dev.a")))
        }
    }
}
