//
//  SetupFlowSourcesTests.swift
//  FluxKlangTests
//
//  The mappers that derive the setup flow's facts from the permission status, the device lifecycles, the rig
//  choice, the mapping review and its decisions. Pure values: no registry, probe, clock or file system.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = RigMappingReviewFixture

@Suite("Setup flow sources")
struct SetupFlowSourcesTests {
    private static func rig(_ raw: String) throws -> RigProfileID { try RigProfileID(raw) }

    private static func flowRig(_ raw: String) throws -> SetupFlowRigID { try SetupFlowRigID(raw) }

    private static func rigs(_ count: Int) throws -> [RigProfileID] {
        try (0..<count).map { try RigProfileID("rig.\($0)") }
    }

    private static func lifecycles(present: Int = 0, lost: Int = 0) -> [DeviceLifecycle] {
        let presentOnes = Array(repeating: DeviceLifecycle.present, count: present)
        return presentOnes + Array(repeating: DeviceLifecycle.lostMuted, count: lost)
    }

    /// The refusal of `facts`, or `nil` when it succeeds.
    private static func refusal(
        lifecycles: [DeviceLifecycle] = [], choice: RigChoice = .none, decisions: RigMappingDecisions = .empty
    ) throws -> SetupFlowSourceRefusal? {
        let review = try Fixture.lostRigReview()
        do throws(SetupFlowSourceRefusal) {
            _ = try SetupFlowSources.facts(
                permission: .granted, lifecycles: lifecycles, choice: choice, review: review, decisions: decisions
            )
            return nil
        } catch {
            return error
        }
    }

    private static func leaveUnmapped(_ raw: [String]) throws -> RigMappingDecisions {
        try RigMappingDecisions.make(roles: raw.map { .leaveUnmapped(try RoleID($0)) })
    }

    // MARK: - access

    @Test
    func setupFlowSourcesAccessMapsEachOfTheEightStatusesToItsFlowAccess() {
        let granted = SetupFlowSources.access(for: .granted)
        let notDetermined = SetupFlowSources.access(for: .notDetermined)
        let unknown = SetupFlowSources.access(for: .unknown)
        let denied = SetupFlowSources.access(for: .denied)
        let possiblyDenied = SetupFlowSources.access(for: .possiblyDenied)
        let unreachable = SetupFlowSources.access(for: .unreachable)
        let restricted = SetupFlowSources.access(for: .restricted)
        let unsupported = SetupFlowSources.access(for: .unsupported)
        #expect(granted == .granted)
        #expect(notDetermined == .notDetermined)
        #expect(unknown == .notDetermined)
        #expect(denied == .denied)
        #expect(possiblyDenied == .denied)
        #expect(unreachable == .denied)
        #expect(restricted == .denied)
        #expect(unsupported == .denied)
    }

    // MARK: - device counts

    @Test
    func setupFlowSourcesDeviceCountsOfNoDevicesAreZero() {
        let counts = SetupFlowSources.deviceCounts(of: [])
        #expect(counts == SetupFlowDeviceCounts(present: 0, lostMuted: 0))
    }

    @Test
    func setupFlowSourcesDeviceCountsTreatEveryStateExceptPresentAsLost() {
        let each: [DeviceLifecycle] = [.present, .lostMuted, .revalidating, .muted(.noMeasuredBaseline)]
        let counts = SetupFlowSources.deviceCounts(of: each)
        #expect(counts == SetupFlowDeviceCounts(present: 1, lostMuted: 3))
    }

    @Test
    func setupFlowSourcesDeviceCountsCountEachStateByItsOwnMultiplicity() {
        let mixed: [DeviceLifecycle] = [
            .present, .revalidating, .present, .muted(.capabilityMismatch(.layout)), .lostMuted, .present,
            .revalidating, .muted(.noMeasuredBaseline), .muted(.capabilityMismatch(.actualRate)),
            .muted(.noMeasuredBaseline)
        ]
        let counts = SetupFlowSources.deviceCounts(of: mixed)
        #expect(counts.present == 3)
        #expect(counts.lostMuted == 7)
    }

    @Test
    func setupFlowSourcesDeviceCountsDoNotCapAtTheFactLimitAndMakeRefusesAboveIt() throws {
        let present = SetupFlowSources.deviceCounts(of: Self.lifecycles(present: 1_025))
        let lost = SetupFlowSources.deviceCounts(of: Self.lifecycles(lost: 1_025))
        #expect(present == SetupFlowDeviceCounts(present: 1_025, lostMuted: 0))
        #expect(lost == SetupFlowDeviceCounts(present: 0, lostMuted: 1_025))
        let atMaximumPresent = try Self.refusal(lifecycles: Self.lifecycles(present: 1_024))
        let atMaximumLost = try Self.refusal(lifecycles: Self.lifecycles(lost: 1_024))
        #expect(atMaximumPresent == nil)
        #expect(atMaximumLost == nil)
        let overPresent = try Self.refusal(lifecycles: Self.lifecycles(present: 1_025))
        let overLost = try Self.refusal(lifecycles: Self.lifecycles(lost: 1_025))
        let expectedPresent: SetupFlowSourceRefusal = .facts(.factOutOfRange(.presentDevices, 1_025))
        let expectedLost: SetupFlowSourceRefusal = .facts(.factOutOfRange(.lostMuted, 1_025))
        #expect(overPresent == expectedPresent)
        #expect(overLost == expectedLost)
    }

    // MARK: - offered rigs

    @Test
    func setupFlowSourcesNoRigChoiceOffersNoRig() throws {
        let offered = try SetupFlowSources.offeredRigs(for: .none)
        #expect(offered.isEmpty)
    }

    @Test
    func setupFlowSourcesASelectedRigIsOfferedAsOneIdAndNotPicked() throws {
        let offered = try SetupFlowSources.offeredRigs(for: .selected(Self.rig("rig.only")))
        let expected = try [Self.flowRig("rig.only")]
        #expect(offered == expected)
    }

    @Test
    func setupFlowSourcesAmbiguousRigsKeepTheOrderGiven() throws {
        let offered = try SetupFlowSources.offeredRigs(for: .ambiguous([Self.rig("rig.b"), Self.rig("rig.a")]))
        let expected = try [Self.flowRig("rig.b"), Self.flowRig("rig.a")]
        #expect(offered == expected)
    }

    @Test
    func setupFlowSourcesSixteenAmbiguousRigsAreOfferedAndSeventeenAreRefusedByMakeWithTheirCount() throws {
        let sixteen = try SetupFlowSources.offeredRigs(for: .ambiguous(Self.rigs(16)))
        #expect(sixteen.count == 16)
        let accepted = try Self.refusal(choice: .ambiguous(Self.rigs(16)))
        #expect(accepted == nil)
        let refused = try Self.refusal(choice: .ambiguous(Self.rigs(17)))
        let expected: SetupFlowSourceRefusal = .facts(.tooManyRigs(17))
        #expect(refused == expected)
    }

    @Test
    func setupFlowSourcesRigIdsOfOneAndOfOneHundredTwentyEightBytesAreConverted() throws {
        let longest = String(repeating: "r", count: 128)
        let offered = try SetupFlowSources.offeredRigs(for: .ambiguous([Self.rig("r"), Self.rig(longest)]))
        let expected = try [Self.flowRig("r"), Self.flowRig(longest)]
        #expect(offered == expected)
    }

    // MARK: - undecided roles

    @Test
    func setupFlowSourcesWithNoDecisionEveryPendingRoleIsUndecided() throws {
        let review = try Fixture.lostRigReview()
        let pending = review.pendingChoices
        #expect(pending == (try Fixture.roles(["rol.cue", "rol.space"])))
        let undecided = SetupFlowSources.undecidedRoles(review: review, decisions: .empty)
        #expect(undecided == 2)
    }

    @Test
    func setupFlowSourcesALeaveUnmappedDecisionDecidesItsRole() throws {
        let review = try Fixture.lostRigReview()
        let cue = SetupFlowSources.undecidedRoles(review: review, decisions: try Self.leaveUnmapped(["rol.cue"]))
        let space = SetupFlowSources.undecidedRoles(review: review, decisions: try Self.leaveUnmapped(["rol.space"]))
        let both = SetupFlowSources.undecidedRoles(
            review: review, decisions: try Self.leaveUnmapped(["rol.cue", "rol.space"])
        )
        #expect(cue == 1)
        #expect(space == 1)
        #expect(both == 0)
    }

    @Test
    func setupFlowSourcesAChooseDecisionDecidesItsRole() throws {
        let review = try Fixture.lostRigReview()
        let pick = try Fixture.candidate(review, "rol.space", first: 0)
        let choose = try RigMappingDecisions.make(roles: [.choose(pick, id: RouteID("rte.space-a"))])
        let chosen = SetupFlowSources.undecidedRoles(review: review, decisions: choose)
        #expect(chosen == 1)
        let both = try RigMappingDecisions.make(
            roles: [.choose(pick, id: RouteID("rte.space-a")), .leaveUnmapped(RoleID("rol.cue"))]
        )
        let bothDecided = SetupFlowSources.undecidedRoles(review: review, decisions: both)
        #expect(bothDecided == 0)
    }

    @Test
    func setupFlowSourcesADecisionForARoleThatIsNotAwaitingAChoiceIsNotCounted() throws {
        let review = try Fixture.lostRigReview()
        let notPending = try Self.leaveUnmapped(["rol.mains"])
        let undecided = SetupFlowSources.undecidedRoles(review: review, decisions: notPending)
        #expect(undecided == 2)
    }

    @Test
    func setupFlowSourcesAReplaceDecisionDecidesTheRoleOfItsCandidate() throws {
        let review = try Fixture.lostRigReview()
        let offer = try Fixture.replacement(review, "rol.space", first: 0)
        let replace = try RigMappingDecisions.make(
            routes: [.replace(RouteID("rte.space"), with: offer, id: RouteID("rte.space-a"))]
        )
        let undecided = SetupFlowSources.undecidedRoles(review: review, decisions: replace)
        #expect(undecided == 1)
    }

    @Test
    func setupFlowSourcesAReplaceForARoleThatIsNoLongerPendingIsNotCounted() throws {
        let review = try Fixture.lostRigReview()
        let pick = try Fixture.candidate(review, "rol.space", first: 0)
        let chosen = try review.choosing(pick, id: RouteID("rte.space-a"))
        #expect(chosen.pendingChoices == (try Fixture.roles(["rol.cue"])))
        let offer = try Fixture.replacement(review, "rol.space", first: 1)
        let replace = try RigMappingDecisions.make(
            routes: [.replace(RouteID("rte.space"), with: offer, id: RouteID("rte.space-b"))]
        )
        let afterChoosing = SetupFlowSources.undecidedRoles(review: chosen, decisions: replace)
        #expect(afterChoosing == 1)
        let withNoDecision = SetupFlowSources.undecidedRoles(review: chosen, decisions: .empty)
        #expect(withNoDecision == 1)
    }

    // MARK: - facts

    @Test
    func setupFlowSourcesFactsOfAGrantedSetupEqualTheFactsBuiltByHand() throws {
        let review = try Fixture.lostRigReview()
        let derived = try SetupFlowSources.facts(
            permission: .granted,
            lifecycles: [.present, .lostMuted, .present],
            choice: .selected(Self.rig("rig.one")),
            review: review,
            decisions: try Self.leaveUnmapped(["rol.cue", "rol.space"])
        )
        let expected = try SetupFlowFacts.make(
            access: .granted, presentDevices: 2, lostMuted: 1, offeredRigs: [Self.flowRig("rig.one")],
            undecidedRoles: 0
        )
        #expect(derived == expected)
    }

    @Test
    func setupFlowSourcesFactsCarryTheUndecidedRolesOfTheReview() throws {
        let review = try Fixture.lostRigReview()
        let derived = try SetupFlowSources.facts(
            permission: .granted, lifecycles: [.present], choice: .none, review: review, decisions: .empty
        )
        let expected = try SetupFlowFacts.make(
            access: .granted, presentDevices: 1, lostMuted: 0, offeredRigs: [], undecidedRoles: 2
        )
        #expect(derived == expected)
    }

    @Test
    func setupFlowSourcesFactsCarryTheAccessOfTheStatusAndDoNotRefuseADeniedOne() throws {
        let review = try Fixture.lostRigReview()
        let denied = try SetupFlowSources.facts(
            permission: .restricted, lifecycles: [], choice: .none, review: review, decisions: .empty
        )
        let notDetermined = try SetupFlowSources.facts(
            permission: .unknown, lifecycles: [], choice: .none, review: review, decisions: .empty
        )
        #expect(denied.access == .denied)
        #expect(notDetermined.access == .notDetermined)
        #expect(denied.presentDevices == 0)
    }

    @Test
    func setupFlowSourcesFactsReportTheRigCountBeforeAnOutOfRangePresentCount() throws {
        let refused = try Self.refusal(lifecycles: Self.lifecycles(present: 1_025), choice: .ambiguous(Self.rigs(17)))
        let expected: SetupFlowSourceRefusal = .facts(.tooManyRigs(17))
        #expect(refused == expected)
    }

    @Test
    func setupFlowSourcesFactsReportThePresentCountBeforeAnOutOfRangeLostCount() throws {
        let refused = try Self.refusal(lifecycles: Self.lifecycles(present: 1_025, lost: 1_026))
        let expected: SetupFlowSourceRefusal = .facts(.factOutOfRange(.presentDevices, 1_025))
        #expect(refused == expected)
    }

    @Test
    func setupFlowSourcesFactsReportTheLostCountBeforeADuplicateRig() throws {
        let duplicated: RigChoice = try .ambiguous([Self.rig("rig.a"), Self.rig("rig.a")])
        let refused = try Self.refusal(lifecycles: Self.lifecycles(lost: 1_025), choice: duplicated)
        let expected: SetupFlowSourceRefusal = .facts(.factOutOfRange(.lostMuted, 1_025))
        #expect(refused == expected)
    }

    @Test
    func setupFlowSourcesFactsRefuseDuplicateAmbiguousRigsWithTheFirstRepeatedId() throws {
        let duplicated: RigChoice = try .ambiguous([Self.rig("rig.b"), Self.rig("rig.a"), Self.rig("rig.a")])
        let refused = try Self.refusal(choice: duplicated)
        let expected: SetupFlowSourceRefusal = try .facts(.duplicateRig(Self.flowRig("rig.a")))
        #expect(refused == expected)
    }

    // MARK: - source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Rig/Setup",
            "../../Sources/FluxKlang/Shared/Rig/Setup"
        ]
        let marker = "SetupFlowSources.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Looks for each text of `SetupFlowTests.forbiddenSourceWords()` and for a static operator function in the two
    /// production files, over the raw bytes (comments included). It is skipped when the sources are not next to the
    /// tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the setup flow sources are not next to the tests"))
    func setupFlowSourcesTheTwoProductionFilesContainNoForbiddenTextAndNoStaticOperatorFunction() throws {
        let directory = try #require(Self.sourceDirectory(), "the setup flow sources are not next to the tests")
        var hits: [String] = []
        var scanned = 0
        for name in ["SetupFlowSources.swift", "SetupFlowSourceRefusal.swift"] {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            scanned += 1
            for word in SetupFlowTests.forbiddenSourceWords() where SetupFlowTests.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
            if SetupFlowTests.declaresAStaticOperatorFunction(text) { hits.append("\(name): static operator function") }
        }
        #expect(scanned == 2)
        #expect(hits.isEmpty)
    }
}
