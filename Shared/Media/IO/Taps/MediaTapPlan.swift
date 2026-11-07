// #109 IO3: the capture tap consumer plan. Control-side only: it allocates no ring and moves no audio.

/// One validated `HandoffPolicy` per consumer of one capture tap, in role order. Feeding `policies` to
/// `FanOutHandoff(policies:)` gives each consumer its own SPSC ring, so one tap never has two consumers on one ring.
///
/// The tuner is advisory: its ring filling up refuses only the tuner's copy (`FanOutHandoff` contract) and
/// `lossIsCritical(.tuner)` is `false`. A recorder refusal is a lost-frame signal the caller must surface.
struct MediaTapPlan: Equatable, Sendable {
    let tap: MediaTapID
    /// Ascending by raw value; index `i` is the `FanOutHandoff` consumer index of `policies[i]`.
    let roles: [MediaTapRole]
    let policies: [HandoffPolicy]

    private init(tap: MediaTapID, roles: [MediaTapRole], policies: [HandoffPolicy]) {
        self.tap = tap
        self.roles = roles
        self.policies = policies
    }

    /// Refuses, in this order: an empty `specs` (`.emptyPlan`); the lowest duplicated role (`.duplicateRole`); the
    /// first role, in role order, whose policy fails `validate()` (`.policy`). The result does not depend on the
    /// order of `specs`.
    static func make(tap: MediaTapID, specs: [MediaTapConsumerSpec]) throws(MediaTapRefusal) -> MediaTapPlan {
        try make(tap: tap, specs: specs, adjusting: { _, policy in policy })
    }

    /// Test seam: `adjusting` may alter each built policy before it is validated, which is the only way to reach
    /// `.policy`, because every unaltered policy is valid.
    static func make(
        tap: MediaTapID,
        specs: [MediaTapConsumerSpec],
        adjusting: (MediaTapRole, HandoffPolicy) -> HandoffPolicy
    ) throws(MediaTapRefusal) -> MediaTapPlan {
        guard !specs.isEmpty else { throw .emptyPlan }
        let ordered = specs.sorted { $0.role < $1.role }
        for (earlier, later) in zip(ordered, ordered.dropFirst()) where earlier.role == later.role {
            throw .duplicateRole(earlier.role)
        }
        var policies: [HandoffPolicy] = []
        policies.reserveCapacity(ordered.count)
        for spec in ordered {
            let policy = adjusting(spec.role, spec.handoffPolicy())
            do {
                try policy.validate()
            } catch {
                throw .policy(spec.role, error)
            }
            policies.append(policy)
        }
        return MediaTapPlan(tap: tap, roles: ordered.map(\.role), policies: policies)
    }

    /// Whether losing this role's blocks must be surfaced. Does not depend on which roles the plan holds.
    func lossIsCritical(_ role: MediaTapRole) -> Bool {
        role.lossIsCritical
    }

    /// The `FanOutHandoff` consumer index of `role`, or `nil` when the plan has no such consumer.
    func consumerIndex(of role: MediaTapRole) -> Int? {
        roles.firstIndex(of: role)
    }

    func policy(for role: MediaTapRole) -> HandoffPolicy? {
        consumerIndex(of: role).map { policies[$0] }
    }

    /// Re-runs `validate()` on every stored policy at the point of use and returns them in role order.
    func validatedPolicies() throws(MediaTapRefusal) -> [HandoffPolicy] {
        for (role, policy) in zip(roles, policies) {
            do {
                try policy.validate()
            } catch {
                throw .policy(role, error)
            }
        }
        return policies
    }
}
