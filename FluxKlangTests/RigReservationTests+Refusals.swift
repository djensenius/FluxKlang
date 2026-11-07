// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The seven mutating operations, for the shared time and unknown-reservation checks.
private enum RigSevenOperations: CaseIterable {
    case booking, approving, recordingBaseline, starting, stopping, reporting, releasing
}

extension RigReservationTests {
    /// A scenario in which `operation` would otherwise succeed.
    private static func readyScenario(for operation: RigSevenOperations) throws -> Scenario {
        var scenario = Scenario()
        switch operation {
        case .booking, .approving, .recordingBaseline:
            try scenario.book("res-a")
        case .starting:
            try scenario.book("res-a")
            try scenario.prepare("res-a")
        case .stopping:
            try scenario.drive("res-a", to: .running)
        case .reporting:
            try scenario.drive("res-a", to: .restoring)
        case .releasing:
            try scenario.drive("res-a", to: .restored)
        }
        return scenario
    }

    private static func perform(
        _ operation: RigSevenOperations,
        on scenario: Scenario,
        reservation id: RigToken,
        at: RigInstant
    ) throws -> Result<RigReservationLedger, RigReservationRefusal> {
        var lock = scenario.lock
        let ledger = scenario.ledger
        let approver = try tok("ops", .approver)
        let plan = try plan("exp-new")
        let value = try baseline()
        let booked = try request("res-new", rig: "rig-z")
        do throws(RigReservationRefusal) {
            switch operation {
            case .booking:
                return .success(try ledger.booking(booked, at: at))
            case .approving:
                return .success(try ledger.approving(reservation: id, kind: .mappings, approver: approver, at: at))
            case .recordingBaseline:
                return .success(try ledger.recordingBaseline(reservation: id, baseline: value, at: at))
            case .starting:
                return .success(try ledger.startingExperiment(reservation: id, plan: plan, at: at, port: &lock))
            case .stopping:
                return .success(try ledger.stoppingExperiment(reservation: id, reason: .completed, at: at))
            case .reporting:
                return .success(try ledger.reportingRestoration(reservation: id, observed: value, at: at))
            case .releasing:
                return .success(try ledger.releasing(reservation: id, at: at, port: &lock))
            }
        } catch {
            return .failure(error)
        }
    }

    @Test("Rig every operation refuses time going backwards and accepts an equal instant")
    func rigTimeBackwardsRefusedByEveryOperation() throws {
        let id = try Self.tok("res-a", .reservationID)
        for operation in RigSevenOperations.allCases {
            let scenario = try Self.readyScenario(for: operation)
            let last = try #require(scenario.ledger.lastInstant)
            let earlier = try Self.instant(last.seconds - 1)
            let refused = try Self.perform(operation, on: scenario, reservation: id, at: earlier)
            #expect(refused == .failure(.timeWentBackwards(last: last.seconds, got: last.seconds - 1)), "\(operation)")
            let equal = try Self.perform(operation, on: scenario, reservation: id, at: last)
            guard case .success(let next) = equal else {
                Issue.record("\(operation) refused an instant equal to the last one: \(equal)")
                continue
            }
            #expect(next.lastInstant == last, "\(operation)")
        }
    }

    @Test("Rig every reservation operation refuses an unknown reservation")
    func rigUnknownReservationRefusedByEveryOperation() throws {
        let unknown = try Self.tok("res-zzz", .reservationID)
        for operation in RigSevenOperations.allCases where operation != .booking {
            let scenario = try Self.readyScenario(for: operation)
            let at = try Self.instant(scenario.now)
            let refused = try Self.perform(operation, on: scenario, reservation: unknown, at: at)
            #expect(refused == .failure(.unknownReservation(unknown)), "\(operation)")
        }
    }

    @Test("Rig time going backwards beats an unknown reservation")
    func rigTimeBackwardsBeatsUnknownReservation() throws {
        let unknown = try Self.tok("res-zzz", .reservationID)
        let scenario = try Self.readyScenario(for: .approving)
        let last = try #require(scenario.ledger.lastInstant)
        let earlier = try Self.instant(last.seconds - 1)
        let refused = try Self.perform(.approving, on: scenario, reservation: unknown, at: earlier)
        #expect(refused == .failure(.timeWentBackwards(last: last.seconds, got: last.seconds - 1)))
    }

    // MARK: Start check order (each pair: two coexisting faults, the earlier check wins, no port call)

    private static func expectStartRefusal(
        _ expected: RigReservationRefusal,
        scenario: Scenario,
        reservation: String = "res-a",
        plan planID: String = "exp-new",
        at seconds: Int? = nil,
        lock: ScriptedRigLock? = nil
    ) throws {
        let id = try tok(reservation, .reservationID)
        let plan = try plan(planID)
        let at = try instant(seconds ?? scenario.now)
        var port = lock ?? scenario.lock
        let calls = port.acquireCalls.count
        expectRefusal(expected, from: scenario.ledger) {
            try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &port)
        }
        #expect(port.acquireCalls.count == calls)
    }

    @Test("Rig start checks the phase before the window")
    func rigStartPhaseBeatsWindow() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .running)
        let running = try Self.tok("res-a", .reservationID)
        try Self.expectStartRefusal(
            .invalidPhase(reservation: running, phase: .running, operation: .startExperiment),
            scenario: scenario,
            at: 6_000
        )
    }

    @Test("Rig start checks the window before the baseline")
    func rigStartWindowBeatsBaseline() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        try Self.expectStartRefusal(
            .outsideWindow(reservation: try Self.tok("res-a", .reservationID)),
            scenario: scenario,
            at: 6_000
        )
    }

    @Test("Rig start checks the baseline before approvals")
    func rigStartBaselineBeatsApprovals() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let missing = try Self.tok("res-a", .reservationID)
        try Self.expectStartRefusal(.baselineMissing(reservation: missing), scenario: scenario)
    }

    @Test("Rig start checks approvals before a duplicate experiment id")
    func rigStartApprovalsBeatDuplicateExperiment() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        try scenario.book("res-b", rig: "rig-b")
        let id = try Self.tok("res-b", .reservationID)
        scenario.ledger = try scenario.ledger.recordingBaseline(
            reservation: id,
            baseline: try Self.baseline(),
            at: try scenario.tick()
        )
        try Self.expectStartRefusal(
            .approvalMissing(reservation: id, kind: .audibility),
            scenario: scenario,
            reservation: "res-b",
            plan: "exp-res-a"
        )
    }

    @Test("Rig start checks a duplicate experiment id before the experiment count")
    func rigStartDuplicateBeatsTooMany() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        try scenario.prepare("res-a")
        for index in 0..<16 {
            try scenario.start("res-a", experiment: "exp-\(index)")
            try scenario.stop("res-a")
            try scenario.report("res-a")
        }
        try Self.expectStartRefusal(
            .duplicateExperiment(experiment: try Self.tok("exp-3", .experimentID)),
            scenario: scenario,
            plan: "exp-3"
        )
    }

    @Test("Rig start checks the experiment count before another active experiment")
    func rigStartTooManyBeatsActiveExperiment() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        try scenario.prepare("res-a")
        for index in 0..<16 {
            try scenario.start("res-a", experiment: "exp-\(index)")
            try scenario.stop("res-a")
            try scenario.report("res-a")
        }
        try scenario.book("res-b", rig: "rig-b")
        try scenario.prepare("res-b")
        try scenario.start("res-b", experiment: "exp-other")
        try Self.expectStartRefusal(
            .tooManyExperiments(reservation: try Self.tok("res-a", .reservationID), count: 16),
            scenario: scenario
        )
    }

    @Test("Rig start checks another active experiment before the lock")
    func rigStartActiveExperimentBeatsLock() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .running)
        try scenario.book("res-b", rig: "rig-b")
        try scenario.prepare("res-b")
        try Self.expectStartRefusal(
            .experimentAlreadyActive(reservation: try Self.tok("res-a", .reservationID)),
            scenario: scenario,
            reservation: "res-b",
            lock: ScriptedRigLock(acquire: [.busy])
        )
    }

    @Test("Rig release checks the phase before the lock")
    func rigReleaseChecksPhaseBeforeLock() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        let id = try Self.tok("res-a", .reservationID)
        var lock = ScriptedRigLock(release: [.notHeld])
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(
            .invalidPhase(reservation: id, phase: .released, operation: .release),
            from: scenario.ledger
        ) { try $0.releasing(reservation: id, at: at, port: &lock) }
        #expect(lock.releaseCalls.isEmpty)
    }
}
// swiftlint:enable identifier_name
