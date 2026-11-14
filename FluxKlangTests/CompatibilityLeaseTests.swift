import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// WL1 (#76): the pure WING compatibility lease. The fixtures here build every lease by a scripted legal path (there
/// is no test-only initializer) and every expected value in the suites is a literal, never a production formula.
@Suite("CompatibilityLeaseTests", .productionAccessAudit)
struct CompatibilityLeaseTests {
    // MARK: Fixtures shared by the extension files

    static func tick(_ raw: Int) throws -> WingLeaseTick { try WingLeaseTick(raw) }

    static func makeGrant(
        origin: WingLeaseOrigin = .human,
        issuedAt: Int = 100,
        duration: Int = 1_000,
        budget: Int = 10
    ) throws -> WingLeaseGrant {
        try WingLeaseGrant.make(
            grantedBy: .human,
            writeOrigin: origin,
            issuedAt: tick(issuedAt),
            durationTicks: duration,
            settingBudget: budget
        )
    }

    static func step(_ lease: WingCompatibilityLease, _ event: WingLeaseEvent, at raw: Int) throws
        -> WingCompatibilityLease {
        try lease.applying(event, at: tick(raw))
    }

    /// The refusal `lease` gives for `event` at `raw`, or nil when the event is accepted.
    static func refusal(_ lease: WingCompatibilityLease, _ event: WingLeaseEvent, at raw: Int) throws
        -> WingLeaseRefusal? {
        let now = try tick(raw)
        do {
            _ = try lease.applying(event, at: now)
            return nil
        } catch {
            return error
        }
    }

    /// Asserts the exact refusal, that it repeats identically, and that the lease equals its pre-call copy.
    static func expectRefusal(
        _ lease: WingCompatibilityLease,
        _ event: WingLeaseEvent,
        at raw: Int,
        _ expected: WingLeaseRefusal,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let before = lease
        let first = try refusal(lease, event, at: raw)
        let second = try refusal(lease, event, at: raw)
        #expect(first == expected, sourceLocation: sourceLocation)
        #expect(second == expected, sourceLocation: sourceLocation)
        #expect(lease == before, sourceLocation: sourceLocation)
    }

    static func discovering(at raw: Int = 100) throws -> WingCompatibilityLease {
        try step(.unleased, .beginDiscovery, at: raw)
    }

    /// Discovery and the grant at `issuedAt`, then `written` settings admitted in chunks of at most 256.
    static func authorized(
        origin: WingLeaseOrigin = .human,
        issuedAt: Int = 100,
        duration: Int = 1_000,
        budget: Int = 10,
        written: Int = 0
    ) throws -> WingCompatibilityLease {
        var lease = try discovering(at: issuedAt)
        let grant = try makeGrant(origin: origin, issuedAt: issuedAt, duration: duration, budget: budget)
        lease = try step(lease, .grant(grant), at: issuedAt)
        var remaining = written
        while remaining > 0 {
            let chunk = min(remaining, 256)
            lease = try step(lease, .admitWrite(origin: origin, settingCount: chunk), at: issuedAt)
            remaining -= chunk
        }
        return lease
    }

    /// A lease in `restoring` with `planned` settings planned and `sent` restore writes admitted, all at tick 100.
    static func restoring(written: Int, planned: Int, sent: Int = 0, budget: Int = 1_024) throws
        -> WingCompatibilityLease {
        var lease = try authorized(budget: budget, written: written)
        lease = try step(lease, .beginRestore(plannedCount: planned), at: 100)
        var remaining = sent
        while remaining > 0 {
            let chunk = min(remaining, 256)
            lease = try step(lease, .admitRestoreWrite(settingCount: chunk), at: 100)
            remaining -= chunk
        }
        return lease
    }

    // MARK: Vocabulary

    @Test func leaseVocabularyListsAndRawValuesMatchTheRulings() {
        #expect(WingLeasePhase.allCases == [.unleased, .readOnlyDiscovery, .authorizedWrite, .restoring])
        #expect(WingLeasePhase.allCases.map(\.rawValue)
            == ["unleased", "readOnlyDiscovery", "authorizedWrite", "restoring"])
        #expect(WingLeaseEventKind.allCases == [
            .beginDiscovery, .grant, .admitWrite, .beginRestore, .admitRestoreWrite, .finishRestore, .release
        ])
        #expect(WingLeaseEventKind.allCases.map(\.rawValue) == [
            "beginDiscovery", "grant", "admitWrite", "beginRestore", "admitRestoreWrite", "finishRestore", "release"
        ])
        #expect(WingLeaseOutcomeKind.allCases == [.verified, .partial, .unverified])
        #expect(WingLeaseOutcomeKind.allCases.map(\.rawValue) == ["verified", "partial", "unverified"])
    }

    @Test func leaseOriginMirrorsTheCommandOriginRawValues() {
        #expect(WingLeaseOrigin.allCases == [.human, .controller, .assistant])
        #expect(WingLeaseOrigin.allCases.map(\.rawValue) == ["human", "controller", "assistant"])
    }

    @Test func leaseEventKindIsCorrectForAllSevenEvents() throws {
        let grant = try Self.makeGrant()
        let pairs: [(WingLeaseEvent, WingLeaseEventKind)] = [
            (.beginDiscovery, .beginDiscovery),
            (.grant(grant), .grant),
            (.admitWrite(origin: .human, settingCount: 1), .admitWrite),
            (.beginRestore(plannedCount: 1), .beginRestore),
            (.admitRestoreWrite(settingCount: 1), .admitRestoreWrite),
            (.finishRestore(expectedCount: 1, confirmedCount: 1), .finishRestore),
            (.release, .release)
        ]
        #expect(pairs.count == 7)
        for (event, kind) in pairs { #expect(event.kind == kind) }
        #expect(pairs.map(\.1) == WingLeaseEventKind.allCases)
    }

    @Test func leaseOutcomeKindAndUnconfirmedCountAreExact() {
        let verified = WingLeaseOutcome.verified(plannedCount: 4)
        let partial = WingLeaseOutcome.partial(confirmedCount: 1, plannedCount: 3)
        let unverified = WingLeaseOutcome.unverified(confirmedCount: 0, plannedCount: 5)
        #expect(verified.kind == .verified && verified.unconfirmedCount == 0)
        #expect(partial.kind == .partial && partial.unconfirmedCount == 2)
        #expect(unverified.kind == .unverified && unverified.unconfirmedCount == 5)
    }

    @Test func leaseInitialValueIsUnleasedAndEmpty() {
        let lease = WingCompatibilityLease()
        #expect(lease == WingCompatibilityLease.unleased)
        #expect(lease.phase == .unleased)
        #expect(lease.grant == nil)
        #expect(lease.writtenSettingCount == 0)
        #expect(lease.plannedRestoreCount == 0)
        #expect(lease.restoreSentCount == 0)
        #expect(lease.lastTick == nil)
        #expect(lease.lastOutcome == nil)
    }
}
