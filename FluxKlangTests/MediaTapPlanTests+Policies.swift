import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Plans, the fixed policy shape, `FanOutHandoff` preparation and the policy-validation seam.
extension MediaTapPlanTests {
    /// A mutable copy of a `HandoffPolicy`, so a test can alter one field and keep the rest.
    struct PolicyDraft {
        var purpose: HandoffPurpose
        var producer: ExecutionContext
        var producers: ProducerCardinality
        var consumer: ExecutionContext
        var consumers: Int
        var capacity: Int
        var ordering: HandoffOrdering
        var deadline: DeadlineHorizon
        var overflow: OverflowPolicy
        var lifetime: HandoffLifetime

        init(_ policy: HandoffPolicy) {
            purpose = policy.purpose
            producer = policy.producer
            producers = policy.producers
            consumer = policy.consumer
            consumers = policy.consumers
            capacity = policy.capacity
            ordering = policy.ordering
            deadline = policy.deadline
            overflow = policy.overflow
            lifetime = policy.lifetime
        }

        var policy: HandoffPolicy {
            HandoffPolicy(
                purpose: purpose,
                producer: producer,
                producers: producers,
                consumer: consumer,
                consumers: consumers,
                capacity: capacity,
                ordering: ordering,
                deadline: deadline,
                overflow: overflow,
                lifetime: lifetime
            )
        }
    }

    static func expectedPolicy(consumer: ExecutionContext, capacity: Int) -> HandoffPolicy {
        HandoffPolicy(
            purpose: .events,
            producer: .render,
            producers: ProducerCardinality(maximum: 1, evidence: .appOwned),
            consumer: consumer,
            consumers: 1,
            capacity: capacity,
            ordering: .fifo,
            deadline: .none,
            overflow: .refuseProducer,
            lifetime: .session
        )
    }

    static func threeSpecs() throws -> [MediaTapConsumerSpec] {
        try [
            spec(.playback, capacity: 8),
            spec(.recorder, capacity: 2),
            spec(.tuner, capacity: 1, context: .control)
        ]
    }

    /// Plan built through the seam with `change` applied to the policies of `roles` only.
    static func alteredPlan(
        roles: [MediaTapRole],
        specs: [MediaTapConsumerSpec]? = nil,
        change: (inout PolicyDraft) -> Void
    ) throws -> MediaTapRefusal? {
        let used = try specs ?? threeSpecs()
        return refusal {
            try MediaTapPlan.make(tap: tap(), specs: used) { role, policy in
                guard roles.contains(role) else { return policy }
                var draft = PolicyDraft(policy)
                change(&draft)
                return draft.policy
            }
        }
    }

    @Test
    func planPoliciesHaveTheExactFixedShapeInRoleOrder() throws {
        let plan = try MediaTapPlan.make(tap: Self.tap(4), specs: Self.threeSpecs())
        #expect(plan.tap == (try Self.tap(4)))
        #expect(plan.roles == [.playback, .recorder, .tuner])
        #expect(plan.policies == [
            Self.expectedPolicy(consumer: .worker, capacity: 8),
            Self.expectedPolicy(consumer: .worker, capacity: 2),
            Self.expectedPolicy(consumer: .control, capacity: 1)
        ])
    }

    @Test
    func singleDoubleAndTripleConsumerPlansHoldExactlyTheirRoles() throws {
        let one = try MediaTapPlan.make(tap: Self.tap(), specs: [Self.spec(.recorder, capacity: 3)])
        #expect(one.roles == [.recorder])
        #expect(one.policies == [Self.expectedPolicy(consumer: .worker, capacity: 3)])
        let two = try MediaTapPlan.make(tap: Self.tap(), specs: [Self.spec(.tuner), Self.spec(.playback, capacity: 5)])
        #expect(two.roles == [.playback, .tuner])
        #expect(two.policies.map(\.capacity) == [5, 8])
        let three = try MediaTapPlan.make(tap: Self.tap(), specs: Self.threeSpecs())
        #expect(three.roles.count == 3)
        #expect(three.policies.count == 3)
    }

    @Test
    func emptyPlanIsRefused() throws {
        #expect(Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: []) } == .emptyPlan)
    }

    @Test(arguments: MediaTapRole.allCases)
    func aSecondConsumerOfOneRoleIsRefusedNotMerged(role: MediaTapRole) throws {
        let first = try Self.spec(role, capacity: 4)
        let second = try Self.spec(role, capacity: 9)
        #expect(Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: [first, second]) } == .duplicateRole(role))
        #expect(Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: [second, first]) } == .duplicateRole(role))
        #expect(Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: [first, first]) } == .duplicateRole(role))
    }

    @Test
    func aDuplicateIsFoundAmongOtherRolesAtAnyPosition() throws {
        let playback = try Self.spec(.playback)
        let tunerA = try Self.spec(.tuner, capacity: 2)
        let tunerB = try Self.spec(.tuner, capacity: 3)
        for specs in [[tunerA, playback, tunerB], [tunerA, tunerB, playback], [playback, tunerA, tunerB]] {
            #expect(Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: specs) } == .duplicateRole(.tuner))
        }
    }

    @Test
    func everyPolicyPreparesAFanOutWithOneRingPerConsumerAndExactCapacities() throws {
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: Self.threeSpecs())
        let fanOut = try FanOutHandoff<UInt8>(policies: plan.policies)
        #expect(fanOut.consumerCount == 3)
        #expect(try #require(fanOut.ring(0)).capacity == 8)
        #expect(try #require(fanOut.ring(1)).capacity == 2)
        #expect(try #require(fanOut.ring(2)).capacity == 1)
        #expect(fanOut.ring(3) == nil)
    }

    @Test
    func aFullTunerRingRefusesOnlyTheTunerAndEveryConsumerDrainsItsOwnRing() throws {
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: Self.threeSpecs())
        let fanOut = try FanOutHandoff<UInt8>(policies: plan.policies)
        let tuner = try #require(plan.consumerIndex(of: .tuner))
        let recorder = try #require(plan.consumerIndex(of: .recorder))
        let playback = try #require(plan.consumerIndex(of: .playback))
        #expect(fanOut.publish(10) == FanOutResult(accepted: 0b111, refused: 0))
        #expect(fanOut.publish(20) == FanOutResult(accepted: 0b011, refused: 0b100))
        #expect(fanOut.refusedCount(consumer: tuner) == 1)
        #expect(fanOut.refusedCount(consumer: recorder) == 0)
        #expect(fanOut.refusedCount(consumer: playback) == 0)
        let tunerRing = try #require(fanOut.ring(tuner))
        let recorderRing = try #require(fanOut.ring(recorder))
        let playbackRing = try #require(fanOut.ring(playback))
        #expect(tunerRing.tryPop() == 10)
        #expect(tunerRing.tryPop() == nil)
        #expect([recorderRing.tryPop(), recorderRing.tryPop(), recorderRing.tryPop()] == [10, 20, nil])
        #expect([playbackRing.tryPop(), playbackRing.tryPop(), playbackRing.tryPop()] == [10, 20, nil])
    }

    @Test
    func consumerIndexAndPolicyLookupFollowTheRolesThePlanHolds() throws {
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: [Self.spec(.tuner, capacity: 6), Self.spec(.recorder)])
        #expect(plan.consumerIndex(of: .playback) == nil)
        #expect(plan.consumerIndex(of: .recorder) == 0)
        #expect(plan.consumerIndex(of: .tuner) == 1)
        #expect(plan.policy(for: .playback) == nil)
        #expect(plan.policy(for: .recorder) == Self.expectedPolicy(consumer: .worker, capacity: 8))
        #expect(plan.policy(for: .tuner) == Self.expectedPolicy(consumer: .worker, capacity: 6))
    }

    @Test
    func validatedPoliciesReturnsTheStoredPoliciesInRoleOrder() throws {
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: Self.threeSpecs())
        #expect(try plan.validatedPolicies() == plan.policies)
    }

    @Test
    func aHandBuiltTwoConsumerPolicyIsRefusedThroughThePlanPath() throws {
        let refused = try Self.alteredPlan(roles: [.recorder]) { $0.consumers = 2 }
        #expect(refused == .policy(.recorder, .violates(.r1SingleConsumer)))
    }

    @Test
    func everyHandBuiltRuleViolationMapsToThePolicyRefusalWithTheRole() throws {
        let consumers = try Self.alteredPlan(roles: [.tuner]) { $0.consumers = 0 }
        #expect(consumers == .policy(.tuner, .violates(.r1SingleConsumer)))
        let producers = try Self.alteredPlan(roles: [.playback]) {
            $0.producers = ProducerCardinality(maximum: 0, evidence: .appOwned)
        }
        #expect(producers == .policy(.playback, .violates(.r2Cardinality)))
        let tooLarge = try Self.alteredPlan(roles: [.recorder]) { $0.capacity = 65_537 }
        #expect(tooLarge == .policy(.recorder, .violates(.r3Capacity)))
        let zero = try Self.alteredPlan(roles: [.recorder]) { $0.capacity = 0 }
        #expect(zero == .policy(.recorder, .violates(.r3Capacity)))
        let purpose = try Self.alteredPlan(roles: [.tuner]) { $0.purpose = .telemetry }
        #expect(purpose == .policy(.tuner, .violates(.r4LatestOnly)))
        let render = try Self.alteredPlan(roles: [.playback]) { $0.consumer = .render }
        #expect(render == .policy(.playback, .violates(.r6RenderDeadline)))
    }

    @Test
    func theSeamSeesEachBuiltPolicyOnceInRoleOrderAndAnIdentityAdjustmentChangesNothing() throws {
        var seen: [MediaTapRole] = []
        var policies: [HandoffPolicy] = []
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: Self.threeSpecs().reversed()) { role, policy in
            seen.append(role)
            policies.append(policy)
            return policy
        }
        #expect(seen == [.playback, .recorder, .tuner])
        #expect(policies == plan.policies)
        #expect(plan == (try MediaTapPlan.make(tap: Self.tap(), specs: Self.threeSpecs())))
    }

    @Test
    func aValidAdjustmentIsStoredNotTheOriginalPolicy() throws {
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: Self.threeSpecs()) { role, policy in
            guard role == .tuner else { return policy }
            var draft = PolicyDraft(policy)
            draft.capacity = 2
            return draft.policy
        }
        #expect(plan.policies.map(\.capacity) == [8, 2, 2])
        #expect(plan.policy(for: .tuner)?.capacity == 2)
    }

    @Test
    func aRefusedPlanDoesNotChangeALaterValidPlan() throws {
        let specs = try Self.threeSpecs() + [Self.spec(.recorder, capacity: 5)]
        #expect(Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: specs) } == .duplicateRole(.recorder))
        let valid = try Self.threeSpecs()
        let first = try MediaTapPlan.make(tap: Self.tap(), specs: valid)
        _ = Self.refusal { try MediaTapPlan.make(tap: Self.tap(), specs: specs) }
        #expect(try MediaTapPlan.make(tap: Self.tap(), specs: valid) == first)
    }

    @Test
    func plansForDifferentTapsAreNotEqual() throws {
        let one = try MediaTapPlan.make(tap: Self.tap(1), specs: Self.threeSpecs())
        let two = try MediaTapPlan.make(tap: Self.tap(2), specs: Self.threeSpecs())
        #expect(one != two)
        #expect(one.tap == (try Self.tap(1)))
        #expect(two.tap == (try Self.tap(2)))
        #expect(one.policies == two.policies)
    }
}
