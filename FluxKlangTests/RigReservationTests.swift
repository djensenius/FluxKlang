import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Rig reservation ledger (#68, slice RIG1): builders, the scripted lock fake, token, instant and window tests.
@Suite("Rig reservation ledger", .productionAccessAudit)
struct RigReservationTests {
    // MARK: Scripted lock

    /// A scripted `RigLockPort`: answers from its scripts in order, `.unavailable` once a script is exhausted, and
    /// records every call.
    struct ScriptedRigLock: RigLockPort {
        var acquireScript: [RigLockAcquisition]
        var releaseScript: [RigLockReleaseOutcome]
        private(set) var acquireCalls: [RigLockRequest] = []
        private(set) var releaseCalls: [RigLockRequest] = []

        init(acquire: [RigLockAcquisition] = [], release: [RigLockReleaseOutcome] = []) {
            acquireScript = acquire
            releaseScript = release
        }

        /// A lock that grants every acquire and release for a long scripted run.
        static var generous: ScriptedRigLock {
            ScriptedRigLock(
                acquire: Array(repeating: .acquired, count: 80),
                release: Array(repeating: .released, count: 80)
            )
        }

        mutating func acquire(_ request: RigLockRequest) -> RigLockAcquisition {
            acquireCalls.append(request)
            return acquireScript.isEmpty ? .unavailable : acquireScript.removeFirst()
        }

        mutating func release(_ request: RigLockRequest) -> RigLockReleaseOutcome {
            releaseCalls.append(request)
            return releaseScript.isEmpty ? .unavailable : releaseScript.removeFirst()
        }
    }

    // MARK: Builders

    static func tok(_ text: String, _ field: RigTokenField = .owner) throws -> RigToken {
        try RigToken(text, field: field)
    }

    static func instant(_ seconds: Int) throws -> RigInstant {
        try RigInstant(seconds: seconds)
    }

    static func window(_ start: Int, _ end: Int) throws -> RigWindow {
        try RigWindow(start: instant(start), end: instant(end))
    }

    static func request(
        _ id: String,
        rig: String = "rig-a",
        start: Int = 1_000,
        end: Int = 5_000
    ) throws -> RigBookingRequest {
        RigBookingRequest(
            id: try tok(id, .reservationID),
            rig: try tok(rig, .rigKey),
            owner: try tok("owner-1", .owner),
            window: try window(start, end)
        )
    }

    static func plan(_ id: String, kind: RigExperimentKind = .analogLoopback) throws -> RigExperimentPlan {
        try RigExperimentPlan(
            id: try tok(id, .experimentID),
            kind: kind,
            stopConditions: RigStopCondition.allCases
        )
    }

    /// The reference baseline; field index 0...6 (source, rate, buffer, io, mixer, path, fallback) changed when listed.
    static func baseline(changing changed: [Int] = []) throws -> RigBaseline {
        let clock = try RigClockBaseline(
            source: try tok(changed.contains(0) ? "clock-b" : "clock-a", .clockSource),
            sampleRateHertz: changed.contains(1) ? 96_000 : 48_000,
            bufferFrames: changed.contains(2) ? 512 : 256
        )
        return RigBaseline(
            clock: clock,
            ioConfiguration: try tok(changed.contains(3) ? "io-b" : "io-a", .ioConfiguration),
            mixerConfiguration: try tok(changed.contains(4) ? "mix-b" : "mix-a", .mixerConfiguration),
            signalPath: try tok(changed.contains(5) ? "path-b" : "path-a", .signalPath),
            fallbackPath: try tok(changed.contains(6) ? "fb-b" : "fb-a", .fallbackPath)
        )
    }

    /// Runs `body` and returns the refusal it throws, or nil when it succeeds.
    static func refusal<Value>(_ body: () throws(RigReservationRefusal) -> Value) -> RigReservationRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }

    /// Expects `body` to refuse with exactly `expected` and the receiver ledger to stay equal to its earlier value.
    static func expectRefusal(
        _ expected: RigReservationRefusal,
        from ledger: RigReservationLedger,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (RigReservationLedger) throws -> RigReservationLedger
    ) {
        let before = ledger
        var caught: RigReservationRefusal?
        do {
            _ = try body(ledger)
        } catch let error as RigReservationRefusal {
            caught = error
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
        #expect(caught == expected, sourceLocation: sourceLocation)
        #expect(ledger == before, sourceLocation: sourceLocation)
    }

    // MARK: Scenario driver

    /// A ledger, a scripted lock and a clock that advances one second per operation, starting at 1_000.
    struct Scenario {
        var ledger = RigReservationLedger.empty
        var lock = ScriptedRigLock.generous
        var now = 1_000

        mutating func tick() throws -> RigInstant {
            defer { now += 1 }
            return try RigReservationTests.instant(now)
        }

        mutating func book(_ id: String, rig: String = "rig-a", start: Int = 1_000, end: Int = 5_000) throws {
            let request = try RigReservationTests.request(id, rig: rig, start: start, end: end)
            ledger = try ledger.booking(request, at: try tick())
        }

        /// Records the reference baseline and grants every approval kind.
        mutating func prepare(_ id: String) throws {
            let reservation = try RigReservationTests.tok(id, .reservationID)
            ledger = try ledger.recordingBaseline(
                reservation: reservation,
                baseline: try RigReservationTests.baseline(),
                at: try tick()
            )
            for kind in RigApprovalKind.allCases {
                ledger = try ledger.approving(
                    reservation: reservation,
                    kind: kind,
                    approver: try RigReservationTests.tok("ops", .approver),
                    at: try tick()
                )
            }
        }

        mutating func start(_ id: String, experiment: String, kind: RigExperimentKind = .analogLoopback) throws {
            ledger = try ledger.startingExperiment(
                reservation: try RigReservationTests.tok(id, .reservationID),
                plan: try RigReservationTests.plan(experiment, kind: kind),
                at: try tick(),
                port: &lock
            )
        }

        mutating func stop(_ id: String, reason: RigStopReason = .completed) throws {
            ledger = try ledger.stoppingExperiment(
                reservation: try RigReservationTests.tok(id, .reservationID),
                reason: reason,
                at: try tick()
            )
        }

        mutating func report(_ id: String, changing changed: [Int] = []) throws {
            ledger = try ledger.reportingRestoration(
                reservation: try RigReservationTests.tok(id, .reservationID),
                observed: try RigReservationTests.baseline(changing: changed),
                at: try tick()
            )
        }

        mutating func release(_ id: String) throws {
            ledger = try ledger.releasing(
                reservation: try RigReservationTests.tok(id, .reservationID),
                at: try tick(),
                port: &lock
            )
        }

        /// Books `id` and drives it to `phase` with one experiment `exp-<id>`.
        mutating func drive(
            _ id: String,
            to phase: RigReservationPhase,
            rig: String = "rig-a",
            kind: RigExperimentKind = .analogLoopback
        ) throws {
            try book(id, rig: rig)
            if phase == .booked { return }
            try prepare(id)
            try start(id, experiment: "exp-\(id)", kind: kind)
            if phase == .running { return }
            try stop(id)
            if phase == .restoring { return }
            if phase == .unresolved { return try report(id, changing: [3]) }
            try report(id)
            if phase == .restored { return }
            try release(id)
        }

        func reservation(_ id: String) throws -> RigReservation {
            try #require(ledger.reservation(try RigReservationTests.tok(id, .reservationID)))
        }
    }

    // MARK: Tokens

    @Test("Rig token accepts 64 bytes and refuses 65")
    func rigTokenAcceptsSixtyFourBytesAndRefusesSixtyFive() throws {
        let sixtyFour = String(repeating: "a", count: 64)
        #expect(try RigToken(sixtyFour, field: .owner).description == sixtyFour)
        let refused = Self.refusal { () throws(RigReservationRefusal) in
            try RigToken(sixtyFour + "a", field: .owner)
        }
        #expect(refused == .invalidToken(field: .owner, fault: .tooLong(bytes: 65)))
        #expect(RigReservationLimits.maximumTokenBytes == 64)
    }

    @Test("Rig token refuses empty text")
    func rigTokenRefusesEmpty() {
        let refused = Self.refusal { () throws(RigReservationRefusal) in try RigToken("", field: .approver) }
        #expect(refused == .invalidToken(field: .approver, fault: .empty))
    }

    @Test("Rig token first byte must be a lowercase letter or digit")
    func rigTokenFirstByteRules() throws {
        for text in ["-a", "_a", ".a", "Aa", " a", "é"] {
            let refused = Self.refusal { () throws(RigReservationRefusal) in try RigToken(text, field: .rigKey) }
            #expect(refused == .invalidToken(field: .rigKey, fault: .badFirstByte), "\(text)")
        }
        for text in ["a", "z", "0", "9", "a-._9"] {
            #expect(try RigToken(text, field: .rigKey).description == text)
        }
    }

    @Test("Rig token reports the lowest illegal byte offset")
    func rigTokenIllegalBytesReportLowestOffset() {
        let cases: [(String, Int)] = [
            ("a b", 1), ("aB", 1), ("ab/", 2), ("a\u{0}", 1), ("abcé", 3), ("a/b B", 1), ("ab:c ", 2), ("a-é", 2)
        ]
        for (text, offset) in cases {
            let refused = Self.refusal { () throws(RigReservationRefusal) in try RigToken(text, field: .owner) }
            #expect(refused == .invalidToken(field: .owner, fault: .illegalByte(offset: offset)), "\(text)")
        }
    }

    @Test("Rig token checks length before the first byte")
    func rigTokenLengthIsCheckedBeforeFirstByte() {
        let text = "-" + String(repeating: "a", count: 70)
        let refused = Self.refusal { () throws(RigReservationRefusal) in try RigToken(text, field: .owner) }
        #expect(refused == .invalidToken(field: .owner, fault: .tooLong(bytes: 71)))
    }

    @Test("Rig token measures UTF-8 bytes, not characters")
    func rigTokenCountsUTF8BytesNotCharacters() {
        let letters = String(repeating: "é", count: 33)
        let long = Self.refusal { () throws(RigReservationRefusal) in try RigToken(letters, field: .owner) }
        #expect(long == .invalidToken(field: .owner, fault: .tooLong(bytes: 66)))
        let sixtyTwo = String(repeating: "a", count: 62) + "é"
        let exact = Self.refusal { () throws(RigReservationRefusal) in try RigToken(sixtyTwo, field: .owner) }
        #expect(exact == .invalidToken(field: .owner, fault: .illegalByte(offset: 62)))
        let combining = Self.refusal { () throws(RigReservationRefusal) in try RigToken("e\u{301}", field: .owner) }
        #expect(combining == .invalidToken(field: .owner, fault: .illegalByte(offset: 1)))
    }

    @Test("Rig token orders and compares by UTF-8 bytes")
    func rigTokenOrdersByBytes() throws {
        let texts = ["aab", "a_b", "a0b", "a.b", "a-b"]
        let sorted = try texts.map { try RigToken($0, field: .owner) }.sorted()
        #expect(sorted.map(\.description) == ["a-b", "a.b", "a0b", "a_b", "aab"])
        let prefix = try RigToken("ab", field: .owner)
        let longer = try RigToken("ab-", field: .owner)
        #expect(prefix < longer)
        #expect(!(longer < prefix))
        #expect(!(prefix < prefix))
    }

    @Test("Rig token equality and hashing follow the bytes")
    func rigTokenEqualityAndHashAreByteWise() throws {
        let first = try RigToken("abc", field: .owner)
        let second = try RigToken("abc", field: .approver)
        let other = try RigToken("abd", field: .owner)
        #expect(first == second)
        #expect(first != other)
        #expect(Set([first, second, other]).count == 2)
    }

    @Test("Rig token refusals echo every field")
    func rigTokenEchoesEveryField() {
        for field in RigTokenField.allCases {
            let refused = Self.refusal { () throws(RigReservationRefusal) in try RigToken("", field: field) }
            #expect(refused == .invalidToken(field: field, fault: .empty))
        }
    }

    @Test("Rig token field table")
    func rigTokenFieldTable() {
        let expected = [
            "rigKey", "owner", "reservationID", "experimentID", "approver",
            "clockSource", "ioConfiguration", "mixerConfiguration", "signalPath", "fallbackPath"
        ]
        #expect(RigTokenField.allCases.map(\.rawValue) == expected)
    }

    // MARK: Instants and windows

    @Test("Rig instant bounds")
    func rigInstantBounds() throws {
        #expect(try RigInstant(seconds: 0).seconds == 0)
        #expect(try RigInstant(seconds: 9_007_199_254_740_991).seconds == 9_007_199_254_740_991)
        for bad in [-1, 9_007_199_254_740_992, Int.min, Int.max] {
            let refused = Self.refusal { () throws(RigReservationRefusal) in try RigInstant(seconds: bad) }
            #expect(refused == .invalidInstant(seconds: bad))
        }
        #expect(try Self.instant(1) < Self.instant(2))
    }

    @Test("Rig window length bounds")
    func rigWindowLengthBounds() throws {
        #expect(try Self.window(10, 11).end.seconds == 11)
        #expect(try Self.window(0, 604_800).end.seconds == 604_800)
        let start = try Self.instant(5)
        let cases: [(Int, RigReservationRefusal)] = [
            (5, .windowEmpty(start: 5, end: 5)), (4, .windowEmpty(start: 5, end: 4)),
            (0, .windowEmpty(start: 5, end: 0)), (604_806, .windowTooLong(seconds: 604_801)),
            (1_000_000, .windowTooLong(seconds: 999_995))
        ]
        for (endSeconds, expected) in cases {
            let end = try Self.instant(endSeconds)
            let refused = Self.refusal { () throws(RigReservationRefusal) in try RigWindow(start: start, end: end) }
            #expect(refused == expected)
        }
        let longest = try RigWindow(start: start, end: try Self.instant(604_805))
        #expect(longest.start == start)
        #expect(longest.end.seconds == 604_805)
    }

    @Test("Rig window reports the true length of a huge span")
    func rigWindowReportsTrueLengthForHugeSpan() throws {
        let start = try Self.instant(0)
        let end = try Self.instant(RigReservationLimits.maximumInstantSeconds)
        let refused = Self.refusal { () throws(RigReservationRefusal) in try RigWindow(start: start, end: end) }
        #expect(refused == .windowTooLong(seconds: 9_007_199_254_740_991))
        #expect(RigReservationLimits.maximumWindowSeconds == 604_800)
    }

    @Test("Rig window contains is half open")
    func rigWindowContainsIsHalfOpen() throws {
        let window = try Self.window(100, 200)
        #expect(!window.contains(try Self.instant(99)))
        #expect(window.contains(try Self.instant(100)))
        #expect(window.contains(try Self.instant(199)))
        #expect(!window.contains(try Self.instant(200)))
    }

    @Test("Rig window overlaps for identical, nested, partial and adjacent windows")
    func rigWindowOverlapsCases() throws {
        let base = try Self.window(100, 200)
        let cases: [(RigWindow, Bool)] = [
            (try Self.window(100, 200), true), (try Self.window(120, 180), true), (try Self.window(50, 250), true),
            (try Self.window(150, 250), true), (try Self.window(50, 150), true), (try Self.window(199, 300), true),
            (try Self.window(50, 101), true), (try Self.window(200, 300), false), (try Self.window(50, 100), false),
            (try Self.window(300, 400), false), (try Self.window(1, 2), false)
        ]
        for (other, expected) in cases {
            #expect(base.overlaps(other) == expected)
            #expect(other.overlaps(base) == expected)
        }
    }
}
