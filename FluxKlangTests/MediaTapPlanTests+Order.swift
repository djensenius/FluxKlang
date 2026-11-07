import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Refusal order and input-order independence of plans. Each order claim uses a fixture holding both defects at once.
extension MediaTapPlanTests {
    @Test
    func aDuplicateRoleIsReportedBeforeAPolicyFailureInBothInputOrders() throws {
        let playback = try Self.spec(.playback)
        let recorderA = try Self.spec(.recorder, capacity: 3)
        let recorderB = try Self.spec(.recorder, capacity: 4)
        let expected = MediaTapRefusal.duplicateRole(.recorder)
        for specs in [[playback, recorderA, recorderB], [recorderB, recorderA, playback]] {
            let found = try Self.alteredPlan(roles: [.playback], specs: specs) { $0.consumers = 2 }
            #expect(found == expected)
        }
    }

    @Test
    func theLowestDuplicatedRoleIsReportedInEveryInputOrder() throws {
        let playbackA = try Self.spec(.playback, capacity: 2)
        let playbackB = try Self.spec(.playback, capacity: 3)
        let tunerA = try Self.spec(.tuner, capacity: 4)
        let tunerB = try Self.spec(.tuner, capacity: 5)
        let orders = [
            [playbackA, playbackB, tunerA, tunerB],
            [tunerA, tunerB, playbackA, playbackB],
            [tunerA, playbackA, tunerB, playbackB],
            [playbackB, tunerB, playbackA, tunerA]
        ]
        for specs in orders {
            let found = Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: specs) }
            #expect(found == .duplicateRole(.playback))
        }
    }

    @Test
    func theFirstFailingPolicyInRoleOrderIsReportedInEveryInputOrder() throws {
        let specs = try Self.threeSpecs()
        try #require(specs.count == 3)
        let orders = [specs, specs.reversed(), [specs[1], specs[2], specs[0]], [specs[2], specs[0], specs[1]]]
        for order in orders {
            let found = Self.refusal {
                try MediaTapPlan.make(tap: Self.tap(), specs: order) { role, policy in
                    var draft = PolicyDraft(policy)
                    if role == .recorder { draft.consumers = 2 }
                    if role == .tuner { draft.capacity = 0 }
                    return draft.policy
                }
            }
            #expect(found == .policy(.recorder, .violates(.r1SingleConsumer)))
        }
    }

    @Test
    func aPolicyFailureOnTheLastRoleAloneIsStillReported() throws {
        let found = try Self.alteredPlan(roles: [.tuner]) { $0.capacity = 65_537 }
        #expect(found == .policy(.tuner, .violates(.r3Capacity)))
    }

    @Test
    func plansBuiltFromEverySpecOrderAreEqual() throws {
        let specs = try Self.threeSpecs()
        let permutations = [
            [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]
        ]
        try #require(specs.count == 3)
        let expected = try MediaTapPlan.make(tap: Self.tap(), specs: specs)
        for permutation in permutations {
            let plan = try MediaTapPlan.make(tap: Self.tap(), specs: permutation.map { specs[$0] })
            #expect(plan == expected)
            #expect(plan.roles == [.playback, .recorder, .tuner])
        }
    }

    @Test
    func policiesFollowRoleOrderNotInputOrder() throws {
        let specs = try [
            Self.spec(.tuner, capacity: 7),
            Self.spec(.recorder, capacity: 5),
            Self.spec(.playback, capacity: 3)
        ]
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: specs)
        #expect(plan.policies.map(\.capacity) == [3, 5, 7])
        #expect(plan.roles == [.playback, .recorder, .tuner])
    }
}
