// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigReservationTests {
    // MARK: Plans

    @Test("Rig plan accepts any input order and stores case order")
    func rigPlanStoresStopConditionsInCaseOrder() throws {
        let id = try Self.tok("exp-a", .experimentID)
        for order in [RigStopCondition.allCases, RigStopCondition.allCases.reversed(), [
            .clipping, .overload, .unexpectedClock, .feedback, .unexpectedIdentity, .permissionDenied, .unexpectedLayout
        ]] {
            let plan = try RigExperimentPlan(id: id, kind: .soak, stopConditions: order)
            #expect(plan.stopConditions == RigStopCondition.allCases)
            #expect(plan.id == id)
            #expect(plan.kind == .soak)
        }
    }

    @Test("Rig plan names the first missing stop condition in case order")
    func rigPlanRefusesMissingStopConditions() throws {
        let id = try Self.tok("exp-a", .experimentID)
        for (index, missing) in RigStopCondition.allCases.enumerated() {
            var conditions = RigStopCondition.allCases
            conditions.remove(at: index)
            let refused = Self.refusal { () throws(RigReservationRefusal) in
                try RigExperimentPlan(id: id, kind: .soak, stopConditions: conditions)
            }
            #expect(refused == .stopConditionMissing(missing))
        }
        let empty = Self.refusal { () throws(RigReservationRefusal) in
            try RigExperimentPlan(id: id, kind: .soak, stopConditions: [])
        }
        #expect(empty == .stopConditionMissing(.unexpectedClock))
        let two = Self.refusal { () throws(RigReservationRefusal) in
            try RigExperimentPlan(id: id, kind: .soak, stopConditions: [.overload, .feedback, .clipping])
        }
        #expect(two == .stopConditionMissing(.unexpectedClock))
    }

    @Test("Rig plan reports a duplicate before a missing condition")
    func rigPlanDuplicateBeatsMissing() throws {
        let id = try Self.tok("exp-a", .experimentID)
        let duplicateAndMissing = Self.refusal { () throws(RigReservationRefusal) in
            try RigExperimentPlan(id: id, kind: .soak, stopConditions: [.clipping, .clipping])
        }
        #expect(duplicateAndMissing == .duplicateStopCondition(.clipping))
        let full = RigStopCondition.allCases + [.unexpectedClock]
        let eight = Self.refusal { () throws(RigReservationRefusal) in
            try RigExperimentPlan(id: id, kind: .soak, stopConditions: full)
        }
        #expect(eight == .duplicateStopCondition(.unexpectedClock))
        let firstInInputOrder = Self.refusal { () throws(RigReservationRefusal) in
            try RigExperimentPlan(
                id: id,
                kind: .soak,
                stopConditions: [.overload, .clipping, .clipping, .overload]
            )
        }
        #expect(firstInInputOrder == .duplicateStopCondition(.clipping))
    }

    // MARK: Starting

    /// A scenario with `res-a` booked, optionally with the baseline, and exactly `kinds` approved.
    private static func scenario(approved kinds: [RigApprovalKind], baseline: Bool = true) throws -> Scenario {
        var scenario = Scenario()
        try scenario.book("res-a")
        let id = try tok("res-a", .reservationID)
        if baseline {
            scenario.ledger = try scenario.ledger.recordingBaseline(
                reservation: id,
                baseline: try Self.baseline(),
                at: try scenario.tick()
            )
        }
        for kind in kinds {
            scenario.ledger = try scenario.ledger.approving(
                reservation: id,
                kind: kind,
                approver: try tok("ops", .approver),
                at: try scenario.tick()
            )
        }
        return scenario
    }

    @Test("Rig start requires a recorded baseline")
    func rigStartRequiresBaseline() throws {
        var scenario = try Self.scenario(approved: RigApprovalKind.allCases, baseline: false)
        let id = try Self.tok("res-a", .reservationID)
        let plan = try Self.plan("exp-a")
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(.baselineMissing(reservation: id), from: scenario.ledger) {
            try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock)
        }
        #expect(scenario.lock.acquireCalls.isEmpty)
    }

    @Test("Rig start names the first missing required approval for every kind")
    func rigStartNamesFirstMissingApprovalForEveryKind() throws {
        let id = try Self.tok("res-a", .reservationID)
        for kind in RigExperimentKind.allCases {
            let required = kind.requiredApprovals
            for index in required.indices {
                let granted = RigApprovalKind.allCases.filter { !required[index...].contains($0) }
                var scenario = try Self.scenario(approved: granted)
                let plan = try Self.plan("exp-a", kind: kind)
                let at = try Self.instant(scenario.now)
                Self.expectRefusal(.approvalMissing(reservation: id, kind: required[index]), from: scenario.ledger) {
                    try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock)
                }
                #expect(scenario.lock.acquireCalls.isEmpty, "\(kind) \(index)")
            }
        }
    }

    @Test("Rig start succeeds for every kind with one lock acquisition")
    func rigStartSucceedsForEveryKindWithOneAcquire() throws {
        let id = try Self.tok("res-a", .reservationID)
        let rig = try Self.tok("rig-a", .rigKey)
        for kind in RigExperimentKind.allCases {
            var scenario = try Self.scenario(approved: kind.requiredApprovals)
            let plan = try Self.plan("exp-a", kind: kind)
            let at = try Self.instant(scenario.now)
            let before = scenario.ledger
            let next = try before.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock)
            #expect(scenario.lock.acquireCalls == [RigLockRequest(rig: rig, holder: id)], "\(kind)")
            #expect(scenario.lock.releaseCalls.isEmpty)
            let reservation = try #require(next.reservation(id))
            #expect(reservation.phase == .running)
            #expect(reservation.experiments == [RigExperimentRecord(id: plan.id, kind: kind, startedAt: at)])
            #expect(reservation.experiments.first?.stop == nil)
            #expect(next.lastInstant == at)
            #expect(before.reservation(id)?.phase == .booked)
            #expect(next != before)
        }
    }

    @Test("Rig start window boundaries")
    func rigStartWindowBoundaries() throws {
        let id = try Self.tok("res-a", .reservationID)
        var base = Scenario()
        try base.book("res-a", start: 2_000, end: 3_000)
        try base.prepare("res-a")
        let plan = try Self.plan("exp-a")
        for outside in [1_999, 3_000, 3_001, 1_500] {
            var scenario = base
            let at = try Self.instant(outside)
            Self.expectRefusal(.outsideWindow(reservation: id), from: scenario.ledger) {
                try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock)
            }
            #expect(scenario.lock.acquireCalls.isEmpty)
        }
        for inside in [2_000, 2_999] {
            var scenario = base
            let next = try scenario.ledger.startingExperiment(
                reservation: id,
                plan: plan,
                at: Self.instant(inside),
                port: &scenario.lock
            )
            #expect(next.reservation(id)?.phase == .running)
        }
    }

    @Test("Rig start refuses a busy or unavailable lock after exactly one acquire")
    func rigStartLockBusyAndUnavailable() throws {
        let id = try Self.tok("res-a", .reservationID)
        let rig = try Self.tok("rig-a", .rigKey)
        let plan = try Self.plan("exp-a")
        let cases: [(RigLockAcquisition, RigReservationRefusal)] = [
            (.busy, .lockBusy(rig: rig)), (.unavailable, .lockUnavailable(rig: rig))
        ]
        for (answer, expected) in cases {
            var scenario = Scenario()
            try scenario.book("res-a")
            try scenario.prepare("res-a")
            var lock = ScriptedRigLock(acquire: [answer])
            let at = try Self.instant(scenario.now)
            Self.expectRefusal(expected, from: scenario.ledger) {
                try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &lock)
            }
            #expect(lock.acquireCalls == [RigLockRequest(rig: rig, holder: id)])
            #expect(scenario.reservationPhase("res-a") == .booked)
            #expect(scenario.ledger.reservation(id)?.experiments == [])
        }
        var exhausted = ScriptedRigLock()
        var scenario = Scenario()
        try scenario.book("res-a")
        try scenario.prepare("res-a")
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(.lockUnavailable(rig: rig), from: scenario.ledger) {
            try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &exhausted)
        }
        #expect(exhausted.acquireCalls.count == 1)
    }

    @Test("Rig start refuses a phase other than booked or restored without a port call")
    func rigStartRefusesInvalidPhases() throws {
        let id = try Self.tok("res-a", .reservationID)
        for phase in [RigReservationPhase.running, .restoring, .unresolved, .released] {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            let calls = scenario.lock.acquireCalls
            let plan = try Self.plan("exp-b")
            let at = try Self.instant(scenario.now)
            Self.expectRefusal(
                .invalidPhase(reservation: id, phase: phase, operation: .startExperiment),
                from: scenario.ledger
            ) { try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock) }
            #expect(scenario.lock.acquireCalls == calls)
        }
    }

    @Test("Rig experiment ids are unique across every reservation")
    func rigDuplicateExperimentIdAcrossReservations() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        try scenario.book("res-b", rig: "rig-b")
        try scenario.prepare("res-b")
        let plan = try Self.plan("exp-res-a")
        let at = try Self.instant(scenario.now)
        let second = try Self.tok("res-b", .reservationID)
        let calls = scenario.lock.acquireCalls.count
        Self.expectRefusal(
            .duplicateExperiment(experiment: try Self.tok("exp-res-a", .experimentID)),
            from: scenario.ledger
        ) { try $0.startingExperiment(reservation: second, plan: plan, at: at, port: &scenario.lock) }
        #expect(scenario.lock.acquireCalls.count == calls)
        try scenario.start("res-b", experiment: "exp-res-b")
        #expect(scenario.reservationPhase("res-b") == .running)
    }

    @Test("Rig reservation holds 16 experiments and refuses the 17th")
    func rigSixteenExperimentsThenTooMany() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        try scenario.prepare("res-a")
        for index in 0..<16 {
            try scenario.start("res-a", experiment: "exp-\(index)")
            try scenario.stop("res-a")
            try scenario.report("res-a")
        }
        let reservation = try scenario.reservation("res-a")
        #expect(reservation.experiments.count == RigReservationLimits.maximumExperimentsPerReservation)
        #expect(reservation.experiments.map(\.id.description) == (0..<16).map { "exp-\($0)" })
        #expect(scenario.lock.acquireCalls.count == 1)
        let id = reservation.id
        let plan = try Self.plan("exp-16")
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(.tooManyExperiments(reservation: id, count: 16), from: scenario.ledger) {
            try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock)
        }
        #expect(scenario.lock.acquireCalls.count == 1)
    }

    @Test("Rig start from restored does not call the port")
    func rigStartFromRestoredDoesNotCallPort() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .restored)
        #expect(scenario.lock.acquireCalls.count == 1)
        try scenario.start("res-a", experiment: "exp-2")
        #expect(scenario.lock.acquireCalls.count == 1)
        let reservation = try scenario.reservation("res-a")
        #expect(reservation.phase == .running)
        #expect(reservation.experiments.map(\.id.description) == ["exp-res-a", "exp-2"])
        #expect(reservation.experiments.first?.stop != nil)
        #expect(reservation.experiments.last?.stop == nil)
    }

    @Test("Rig only one experiment is active across the whole ledger")
    func rigOtherReservationBlockedWhileFirstIsActive() throws {
        let phases: [(RigReservationPhase, Bool)] = [
            (.running, true), (.restoring, true), (.unresolved, true), (.restored, false), (.released, false)
        ]
        for (phase, blocked) in phases {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            try scenario.book("res-b", rig: "rig-b")
            try scenario.prepare("res-b")
            let acquires = scenario.lock.acquireCalls.count
            let id = try Self.tok("res-b", .reservationID)
            let plan = try Self.plan("exp-b")
            let at = try Self.instant(scenario.now)
            if blocked {
                let active = try Self.tok("res-a", .reservationID)
                Self.expectRefusal(.experimentAlreadyActive(reservation: active), from: scenario.ledger) {
                    try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock)
                }
                #expect(scenario.lock.acquireCalls.count == acquires, "\(phase)")
            } else {
                try scenario.start("res-b", experiment: "exp-b")
                #expect(scenario.reservationPhase("res-b") == .running, "\(phase)")
                #expect(scenario.lock.acquireCalls.count == acquires + 1)
            }
        }
    }
}

extension RigReservationTests.Scenario {
    func reservationPhase(_ id: String) -> RigReservationPhase? {
        (try? RigToken(id, field: .reservationID)).flatMap { ledger.reservation($0)?.phase }
    }
}
// swiftlint:enable identifier_name
