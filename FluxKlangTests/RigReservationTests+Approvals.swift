import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigReservationTests {
    // MARK: Closed-enum tables

    @Test("Rig approval kind table")
    func rigApprovalKindTable() {
        let expected = ["audibility", "mappings", "clockChange", "configChange", "restoration"]
        #expect(RigApprovalKind.allCases.map(\.rawValue) == expected)
    }

    @Test("Rig experiment kind table")
    func rigExperimentKindTable() {
        let expected = [
            "analogLoopback", "digitalCalibration", "avEnginePilot", "directIOPilot", "rustPilot",
            "midiOscExercise", "clockExercise", "soak", "wingProcedure"
        ]
        #expect(RigExperimentKind.allCases.map(\.rawValue) == expected)
    }

    @Test("Rig required approvals match an independently written table")
    func rigRequiredApprovalsTableMatchesIndependentTable() {
        let table: [(RigExperimentKind, [RigApprovalKind])] = [
            (.analogLoopback, [.audibility, .mappings, .restoration]),
            (.digitalCalibration, [.mappings, .restoration]),
            (.avEnginePilot, [.audibility, .mappings, .restoration]),
            (.directIOPilot, [.audibility, .mappings, .restoration]),
            (.rustPilot, [.audibility, .mappings, .restoration]),
            (.midiOscExercise, [.mappings, .restoration]),
            (.clockExercise, [.clockChange, .configChange, .restoration]),
            (.soak, [.audibility, .mappings, .clockChange, .restoration]),
            (.wingProcedure, [.mappings, .configChange, .restoration])
        ]
        #expect(table.map(\.0) == RigExperimentKind.allCases)
        for (kind, required) in table {
            #expect(kind.requiredApprovals == required, "\(kind)")
        }
    }

    @Test("Rig phase, operation, stop condition and stop reason tables")
    func rigPhaseOperationAndStopTables() {
        #expect(RigReservationPhase.allCases.map(\.rawValue) ==
            ["booked", "running", "restoring", "unresolved", "restored", "released"])
        #expect(RigOperation.allCases.map(\.rawValue) ==
            ["approve", "recordBaseline", "startExperiment", "stopExperiment", "reportRestoration", "release"])
        #expect(RigStopCondition.allCases.map(\.rawValue) == [
            "unexpectedClock", "unexpectedLayout", "unexpectedIdentity", "clipping", "feedback",
            "permissionDenied", "overload"
        ])
        let active = RigReservationPhase.allCases.filter(\.hasActiveExperiment)
        #expect(active == [.running, .restoring, .unresolved])
    }

    // MARK: Approvals

    @Test("Rig approval is recorded with kind, approver and time")
    func rigApprovalIsRecordedWithKindApproverAndTime() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let id = try Self.tok("res-a", .reservationID)
        let approver = try Self.tok("alice", .approver)
        let next = try scenario.ledger.approving(
            reservation: id,
            kind: .mappings,
            approver: approver,
            at: Self.instant(1_001)
        )
        let approvals = try #require(next.reservation(id)).approvals
        #expect(approvals == [RigApproval(kind: .mappings, approver: approver, at: try Self.instant(1_001))])
        #expect(scenario.ledger.reservation(id)?.approvals == [])
        #expect(next.lastInstant == (try Self.instant(1_001)))
    }

    @Test("Rig approvals are stored in kind order whatever the grant order")
    func rigApprovalsAreSortedByKindRegardlessOfGrantOrder() throws {
        let id = try Self.tok("res-a", .reservationID)
        let approver = try Self.tok("alice", .approver)
        let orders: [[RigApprovalKind]] = [
            RigApprovalKind.allCases, RigApprovalKind.allCases.reversed(),
            [.configChange, .audibility, .restoration, .mappings, .clockChange]
        ]
        for order in orders {
            var scenario = Scenario()
            try scenario.book("res-a")
            for (offset, kind) in order.enumerated() {
                scenario.ledger = try scenario.ledger.approving(
                    reservation: id,
                    kind: kind,
                    approver: approver,
                    at: Self.instant(1_001 + offset)
                )
            }
            let stored = try #require(scenario.ledger.reservation(id)).approvals
            #expect(stored.map(\.kind) == RigApprovalKind.allCases)
            #expect(stored.count == 5)
        }
    }

    @Test("Rig second approval of a kind is refused and keeps the first")
    func rigSecondApprovalOfAKindIsRefusedAndKeepsTheFirst() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let id = try Self.tok("res-a", .reservationID)
        let first = try Self.tok("alice", .approver)
        let second = try Self.tok("bob", .approver)
        let granted = try scenario.ledger.approving(
            reservation: id,
            kind: .audibility,
            approver: first,
            at: Self.instant(1_001)
        )
        let later = try Self.instant(1_002)
        Self.expectRefusal(.duplicateApproval(reservation: id, kind: .audibility), from: granted) {
            try $0.approving(reservation: id, kind: .audibility, approver: second, at: later)
        }
        #expect(granted.reservation(id)?.approvals.first?.approver == first)
        let other = try granted.approving(reservation: id, kind: .mappings, approver: second, at: later)
        #expect(other.reservation(id)?.approvals.count == 2)
    }

    @Test("Rig approval window boundary")
    func rigApprovalBoundaryAtWindowEnd() throws {
        var scenario = Scenario()
        try scenario.book("res-a", start: 1_000, end: 2_000)
        let id = try Self.tok("res-a", .reservationID)
        let approver = try Self.tok("alice", .approver)
        let accepted = try scenario.ledger.approving(
            reservation: id,
            kind: .audibility,
            approver: approver,
            at: Self.instant(1_999)
        )
        #expect(accepted.reservation(id)?.approvals.count == 1)
        let end = try Self.instant(2_000)
        Self.expectRefusal(.windowExpired(reservation: id), from: scenario.ledger) {
            try $0.approving(reservation: id, kind: .audibility, approver: approver, at: end)
        }
    }

    @Test("Rig approval may be granted before the window starts and while running")
    func rigApprovalAllowedBeforeWindowStartAndWhileRunning() throws {
        var early = Scenario()
        try early.book("res-a", start: 3_000, end: 4_000)
        let id = try Self.tok("res-a", .reservationID)
        let approver = try Self.tok("alice", .approver)
        let granted = try early.ledger.approving(
            reservation: id,
            kind: .mappings,
            approver: approver,
            at: Self.instant(1_001)
        )
        #expect(granted.reservation(id)?.approvals.count == 1)

        var running = Scenario()
        try running.book("res-a")
        let baseline = try Self.baseline()
        running.ledger = try running.ledger.recordingBaseline(reservation: id, baseline: baseline, at: running.tick())
        for kind in RigExperimentKind.digitalCalibration.requiredApprovals {
            running.ledger = try running.ledger.approving(
                reservation: id,
                kind: kind,
                approver: approver,
                at: running.tick()
            )
        }
        try running.start("res-a", experiment: "exp-a", kind: .digitalCalibration)
        let more = try running.ledger.approving(
            reservation: id,
            kind: .clockChange,
            approver: approver,
            at: Self.instant(running.now)
        )
        #expect(more.reservation(id)?.phase == .running)
        #expect(more.reservation(id)?.approvals.map(\.kind) == [.mappings, .clockChange, .restoration])
    }

    @Test("Rig approval on a released reservation is an invalid phase and beats window expiry")
    func rigApprovalOnReleasedIsInvalidPhaseAndBeatsWindowExpired() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        let id = try Self.tok("res-a", .reservationID)
        let approver = try Self.tok("alice", .approver)
        let afterEnd = try Self.instant(5_000)
        Self.expectRefusal(
            .invalidPhase(reservation: id, phase: .released, operation: .approve),
            from: scenario.ledger
        ) { try $0.approving(reservation: id, kind: .audibility, approver: approver, at: afterEnd) }
    }

    @Test("Rig approval checks the window before a duplicate")
    func rigApprovalChecksWindowBeforeDuplicate() throws {
        var scenario = Scenario()
        try scenario.book("res-a", start: 1_000, end: 2_000)
        let id = try Self.tok("res-a", .reservationID)
        let approver = try Self.tok("alice", .approver)
        let granted = try scenario.ledger.approving(
            reservation: id,
            kind: .audibility,
            approver: approver,
            at: Self.instant(1_001)
        )
        let end = try Self.instant(2_000)
        Self.expectRefusal(.windowExpired(reservation: id), from: granted) {
            try $0.approving(reservation: id, kind: .audibility, approver: approver, at: end)
        }
    }
}
