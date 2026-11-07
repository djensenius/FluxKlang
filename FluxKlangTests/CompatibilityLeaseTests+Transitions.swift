import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CompatibilityLeaseTests {
    /// One phase/event cell: `next == nil` means the cell is ILLEGAL (`notPermitted`).
    private struct Cell {
        let phase: WingLeasePhase
        let kind: WingLeaseEventKind
        let next: WingLeasePhase?
        let written: Int
    }

    /// The 4 x 7 transition table, written out as literals.
    private static let table: [Cell] = [
        Cell(phase: .unleased, kind: .beginDiscovery, next: .readOnlyDiscovery, written: 0),
        Cell(phase: .unleased, kind: .grant, next: nil, written: 0),
        Cell(phase: .unleased, kind: .admitWrite, next: nil, written: 0),
        Cell(phase: .unleased, kind: .beginRestore, next: nil, written: 0),
        Cell(phase: .unleased, kind: .admitRestoreWrite, next: nil, written: 0),
        Cell(phase: .unleased, kind: .finishRestore, next: nil, written: 0),
        Cell(phase: .unleased, kind: .release, next: nil, written: 0),
        Cell(phase: .readOnlyDiscovery, kind: .beginDiscovery, next: nil, written: 0),
        Cell(phase: .readOnlyDiscovery, kind: .grant, next: .authorizedWrite, written: 0),
        Cell(phase: .readOnlyDiscovery, kind: .admitWrite, next: nil, written: 0),
        Cell(phase: .readOnlyDiscovery, kind: .beginRestore, next: nil, written: 0),
        Cell(phase: .readOnlyDiscovery, kind: .admitRestoreWrite, next: nil, written: 0),
        Cell(phase: .readOnlyDiscovery, kind: .finishRestore, next: nil, written: 0),
        Cell(phase: .readOnlyDiscovery, kind: .release, next: .unleased, written: 0),
        Cell(phase: .authorizedWrite, kind: .beginDiscovery, next: nil, written: 3),
        Cell(phase: .authorizedWrite, kind: .grant, next: nil, written: 3),
        Cell(phase: .authorizedWrite, kind: .admitWrite, next: .authorizedWrite, written: 3),
        Cell(phase: .authorizedWrite, kind: .beginRestore, next: .restoring, written: 3),
        Cell(phase: .authorizedWrite, kind: .admitRestoreWrite, next: nil, written: 3),
        Cell(phase: .authorizedWrite, kind: .finishRestore, next: nil, written: 3),
        Cell(phase: .authorizedWrite, kind: .release, next: .unleased, written: 0),
        Cell(phase: .restoring, kind: .beginDiscovery, next: nil, written: 3),
        Cell(phase: .restoring, kind: .grant, next: nil, written: 3),
        Cell(phase: .restoring, kind: .admitWrite, next: nil, written: 3),
        Cell(phase: .restoring, kind: .beginRestore, next: nil, written: 3),
        Cell(phase: .restoring, kind: .admitRestoreWrite, next: .restoring, written: 3),
        Cell(phase: .restoring, kind: .finishRestore, next: .unleased, written: 3),
        Cell(phase: .restoring, kind: .release, next: .unleased, written: 3)
    ]

    private static func lease(in phase: WingLeasePhase, written: Int) throws -> WingCompatibilityLease {
        switch phase {
        case .unleased: .unleased
        case .readOnlyDiscovery: try discovering(at: 100)
        case .authorizedWrite: try authorized(written: written)
        case .restoring: try restoring(written: written, planned: 3, sent: 2)
        }
    }

    private static func event(of kind: WingLeaseEventKind) throws -> WingLeaseEvent {
        switch kind {
        case .beginDiscovery: .beginDiscovery
        case .grant: try .grant(makeGrant())
        case .admitWrite: .admitWrite(origin: .human, settingCount: 1)
        case .beginRestore: .beginRestore(plannedCount: 1)
        case .admitRestoreWrite: .admitRestoreWrite(settingCount: 1)
        case .finishRestore: .finishRestore(expectedCount: 3, confirmedCount: 2)
        case .release: .release
        }
    }

    @Test func leaseTableHasTwentyEightCellsInPhaseMajorOrder() {
        #expect(Self.table.count == 28)
        #expect(Self.table.map(\.phase) == WingLeasePhase.allCases.flatMap { Array(repeating: $0, count: 7) })
        #expect(Self.table.map(\.kind) == Array(repeating: WingLeaseEventKind.allCases, count: 4).flatMap { $0 })
        #expect(Self.table.filter { $0.next != nil }.count == 9)
    }

    @Test func leaseEveryOneOfTheTwentyEightCellsDoesExactlyWhatTheTableSays() throws {
        for cell in Self.table {
            let before = try Self.lease(in: cell.phase, written: cell.written)
            #expect(before.phase == cell.phase)
            let event = try Self.event(of: cell.kind)
            if let next = cell.next {
                let after = try Self.step(before, event, at: 150)
                #expect(after.phase == next, "\(cell.phase) \(cell.kind)")
                #expect(after.lastTick?.rawValue == 150)
            } else {
                try Self.expectRefusal(before, event, at: 150, .notPermitted(phase: cell.phase, event: cell.kind))
            }
        }
    }

    @Test func leaseTheUnleasedRowAllowsOnlyBeginDiscoveryAtAnyTick() throws {
        for raw in [0, 1_000_000_000_000] {
            for kind in WingLeaseEventKind.allCases where kind != .beginDiscovery {
                try Self.expectRefusal(
                    .unleased, Self.event(of: kind), at: raw, .notPermitted(phase: .unleased, event: kind)
                )
            }
            let started = try Self.step(.unleased, .beginDiscovery, at: raw)
            #expect(started.phase == .readOnlyDiscovery)
            #expect(started.lastTick?.rawValue == raw)
        }
    }

    @Test func leaseAfterEachRestoreOutcomeTheLeaseIsUnleasedAndOnlyDiscoveryIsLegal() throws {
        let base = try Self.restoring(written: 3, planned: 3, sent: 3)
        let finished = try [3, 2, 0].map {
            try Self.step(base, .finishRestore(expectedCount: 3, confirmedCount: $0), at: 100)
        }
        let expected: [WingLeaseOutcome] = [
            .verified(plannedCount: 3),
            .partial(confirmedCount: 2, plannedCount: 3),
            .unverified(confirmedCount: 0, plannedCount: 3)
        ]
        #expect(finished.map(\.lastOutcome) == expected.map { Optional($0) })
        for lease in finished {
            #expect(lease.phase == .unleased)
            for kind in WingLeaseEventKind.allCases where kind != .beginDiscovery {
                let refused = WingLeaseRefusal.notPermitted(phase: .unleased, event: kind)
                try Self.expectRefusal(lease, Self.event(of: kind), at: 200, refused)
            }
            let again = try Self.step(lease, .beginDiscovery, at: 200)
            #expect(again.phase == .readOnlyDiscovery)
            #expect(again.lastOutcome == nil)
        }
    }

    @Test func leaseBeginDiscoveryClearsTheLastOutcome() throws {
        let base = try Self.restoring(written: 2, planned: 2, sent: 2)
        let done = try Self.step(base, .finishRestore(expectedCount: 2, confirmedCount: 2), at: 100)
        #expect(done.lastOutcome == .verified(plannedCount: 2))
        #expect(try Self.step(done, .beginDiscovery, at: 100).lastOutcome == nil)
    }

    @Test func leaseAScriptedLegalPathShowsEveryAccessorAtEveryStep() throws {
        var lease = WingCompatibilityLease.unleased
        lease = try Self.step(lease, .beginDiscovery, at: 10)
        #expect(lease.phase == .readOnlyDiscovery && lease.grant == nil && lease.lastTick?.rawValue == 10)
        let grant = try Self.makeGrant(origin: .controller, issuedAt: 20, duration: 100, budget: 5)
        lease = try Self.step(lease, .grant(grant), at: 20)
        #expect(lease.phase == .authorizedWrite && lease.grant == grant)
        #expect(lease.writtenSettingCount == 0 && lease.lastTick?.rawValue == 20)
        lease = try Self.step(lease, .admitWrite(origin: .controller, settingCount: 2), at: 30)
        lease = try Self.step(lease, .admitWrite(origin: .controller, settingCount: 3), at: 30)
        #expect(lease.writtenSettingCount == 5 && lease.lastTick?.rawValue == 30)
        lease = try Self.step(lease, .beginRestore(plannedCount: 4), at: 500)
        #expect(lease.phase == .restoring && lease.grant == grant)
        #expect(lease.writtenSettingCount == 5 && lease.plannedRestoreCount == 4 && lease.restoreSentCount == 0)
        lease = try Self.step(lease, .admitRestoreWrite(settingCount: 3), at: 501)
        #expect(lease.restoreSentCount == 3 && lease.plannedRestoreCount == 4)
        lease = try Self.step(lease, .finishRestore(expectedCount: 4, confirmedCount: 3), at: 502)
        #expect(lease.phase == .unleased && lease.grant == nil)
        #expect(lease.writtenSettingCount == 0 && lease.plannedRestoreCount == 0 && lease.restoreSentCount == 0)
        #expect(lease.lastTick?.rawValue == 502)
        #expect(lease.lastOutcome == .partial(confirmedCount: 3, plannedCount: 4))
    }

    // MARK: Tick monotonicity

    @Test func leaseAnEqualTickIsAcceptedAndAnEarlierTickIsRefused() throws {
        let lease = try Self.discovering(at: 100)
        #expect(try Self.step(lease, .release, at: 100).phase == .unleased)
        try Self.expectRefusal(lease, .release, at: 99, .tickRegressed(last: 100, now: 99))
        try Self.expectRefusal(lease, .release, at: 0, .tickRegressed(last: 100, now: 0))
    }

    @Test func leaseTickRegressionBeatsEventFaultsButLosesToNotPermitted() throws {
        let lease = try Self.authorized()
        try Self.expectRefusal(
            lease, .admitWrite(origin: .human, settingCount: 0), at: 99, .tickRegressed(last: 100, now: 99)
        )
        try Self.expectRefusal(
            lease, .admitWrite(origin: .assistant, settingCount: 1), at: 99, .tickRegressed(last: 100, now: 99)
        )
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 1, confirmedCount: 1), at: 99,
            .notPermitted(phase: .authorizedWrite, event: .finishRestore)
        )
        try Self.expectRefusal(
            lease, .admitWrite(origin: .human, settingCount: 0), at: 100, .invalidCount(0)
        )
    }

    @Test func leaseTheLastTickSurvivesTheReturnToUnleased() throws {
        let released = try Self.step(Self.discovering(at: 100), .release, at: 150)
        #expect(released.phase == .unleased && released.lastTick?.rawValue == 150)
        try Self.expectRefusal(released, .beginDiscovery, at: 149, .tickRegressed(last: 150, now: 149))
        #expect(try Self.step(released, .beginDiscovery, at: 150).phase == .readOnlyDiscovery)
        let base = try Self.restoring(written: 1, planned: 1, sent: 1)
        let restored = try Self.step(base, .finishRestore(expectedCount: 1, confirmedCount: 1), at: 300)
        try Self.expectRefusal(restored, .beginDiscovery, at: 299, .tickRegressed(last: 300, now: 299))
    }

    // MARK: Grant window

    @Test func leaseAGrantIsCurrentFromIssuedAtUpToButExcludingExpiry() throws {
        let grant = try Self.makeGrant(issuedAt: 100, duration: 50)
        let lease = try Self.discovering(at: 10)
        try Self.expectRefusal(
            lease, .grant(grant), at: 99, .grantNotCurrent(issuedAt: 100, expiry: 150, now: 99)
        )
        #expect(try Self.step(lease, .grant(grant), at: 100).phase == .authorizedWrite)
        #expect(try Self.step(lease, .grant(grant), at: 149).phase == .authorizedWrite)
        try Self.expectRefusal(
            lease, .grant(grant), at: 150, .grantNotCurrent(issuedAt: 100, expiry: 150, now: 150)
        )
        try Self.expectRefusal(
            lease, .grant(grant), at: 151, .grantNotCurrent(issuedAt: 100, expiry: 150, now: 151)
        )
    }

    @Test func leaseAGrantStoresItselfAndResetsTheWrittenCount() throws {
        let grant = try Self.makeGrant(origin: .assistant, issuedAt: 100, duration: 50, budget: 4)
        let lease = try Self.step(Self.discovering(at: 10), .grant(grant), at: 120)
        #expect(lease.grant == grant && lease.writtenSettingCount == 0 && lease.lastTick?.rawValue == 120)
    }

    // MARK: Release

    @Test func leaseReleaseFromDiscoveryAndFromAnUnwrittenGrantReturnsToUnleasedWithoutAnOutcome() throws {
        let fromDiscovery = try Self.step(Self.discovering(at: 100), .release, at: 100)
        #expect(fromDiscovery.phase == .unleased && fromDiscovery.lastOutcome == nil)
        let fromGrant = try Self.step(Self.authorized(), .release, at: 120)
        #expect(fromGrant.phase == .unleased && fromGrant.grant == nil && fromGrant.lastOutcome == nil)
        #expect(fromGrant.writtenSettingCount == 0 && fromGrant.lastTick?.rawValue == 120)
    }

    @Test func leaseReleaseOfALeaseThatWroteRequiresARestoration() throws {
        for written in [1, 5] {
            try Self.expectRefusal(
                Self.authorized(written: written), .release, at: 100, .restoreRequired(writtenSettingCount: written)
            )
        }
    }

    @Test func leaseReleaseWhileRestoringAbandonsAsUnverifiedNeverVerified() throws {
        let lease = try Self.restoring(written: 5, planned: 4, sent: 4)
        let released = try Self.step(lease, .release, at: 101)
        #expect(released.phase == .unleased)
        #expect(released.lastOutcome == .unverified(confirmedCount: 0, plannedCount: 4))
        #expect(released.grant == nil && released.plannedRestoreCount == 0 && released.restoreSentCount == 0)
        #expect(released.lastTick?.rawValue == 101)
    }
}
