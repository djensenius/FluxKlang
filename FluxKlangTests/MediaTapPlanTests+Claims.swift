import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The claim table: one holder per role per tap, 16 distinct taps, whole-value state after every refusal.
extension MediaTapPlanTests {
    /// A tiny fixed-seed generator for the model run; not shared with any other suite.
    struct ClaimsStepper {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static func filled(taps count: Int) throws -> MediaTapClaims {
        var claims = MediaTapClaims()
        for value in 1...count {
            try claims.claim(.playback, on: tap(value))
        }
        return claims
    }

    @Test
    func aFreshClaimTableIsEmpty() throws {
        let claims = MediaTapClaims()
        #expect(claims.claimedTaps.isEmpty)
        #expect(claims.claimedRoles(on: try Self.tap()).isEmpty)
        #expect(!claims.isClaimed(.playback, on: try Self.tap()))
        #expect(MediaTapClaims.maximumTaps == 16)
    }

    @Test
    func theSecondClaimOfOneRoleOnOneTapIsRefusedAndLeavesTheTableUnchanged() throws {
        var claims = MediaTapClaims()
        let tap = try Self.tap(3)
        try claims.claim(.recorder, on: tap)
        let before = claims
        #expect(Self.refusal { try claims.claim(.recorder, on: tap) } == .alreadyClaimed(tap, .recorder))
        #expect(claims == before)
        #expect(claims.claimedRoles(on: tap) == [.recorder])
    }

    @Test
    func otherRolesAndOtherTapsAreStillClaimable() throws {
        var claims = MediaTapClaims()
        let first = try Self.tap(1)
        let second = try Self.tap(2)
        try claims.claim(.recorder, on: first)
        try claims.claim(.playback, on: first)
        try claims.claim(.recorder, on: second)
        #expect(claims.claimedRoles(on: first) == [.playback, .recorder])
        #expect(claims.claimedRoles(on: second) == [.recorder])
        #expect(claims.isClaimed(.recorder, on: second))
        #expect(!claims.isClaimed(.tuner, on: first))
        #expect(!claims.isClaimed(.playback, on: second))
    }

    @Test
    func releaseFreesTheRoleAndAReleaseOfAnUnclaimedRoleIsRefusedUnchanged() throws {
        var claims = MediaTapClaims()
        let tap = try Self.tap(5)
        try claims.claim(.tuner, on: tap)
        try claims.claim(.playback, on: tap)
        try claims.release(.tuner, on: tap)
        #expect(claims.claimedRoles(on: tap) == [.playback])
        let before = claims
        #expect(Self.refusal { try claims.release(.tuner, on: tap) } == .notClaimed(tap, .tuner))
        #expect(claims == before)
        try claims.claim(.tuner, on: tap)
        #expect(claims.claimedRoles(on: tap) == [.playback, .tuner])
    }

    @Test
    func releaseOnAnUnknownTapIsNotClaimedAndLeavesTheTableUnchanged() throws {
        var claims = MediaTapClaims()
        try claims.claim(.playback, on: Self.tap(1))
        let before = claims
        let unknown = try Self.tap(2)
        #expect(Self.refusal { try claims.release(.playback, on: unknown) } == .notClaimed(unknown, .playback))
        #expect(claims == before)
        var empty = MediaTapClaims()
        #expect(Self.refusal { try empty.release(.recorder, on: unknown) } == .notClaimed(unknown, .recorder))
        #expect(empty == MediaTapClaims())
    }

    @Test
    func releasingTheLastRoleOfATapRemovesTheTap() throws {
        var claims = MediaTapClaims()
        try claims.claim(.recorder, on: Self.tap(9))
        try claims.claim(.tuner, on: Self.tap(9))
        try claims.claim(.recorder, on: Self.tap(4))
        try claims.release(.recorder, on: Self.tap(9))
        #expect(try claims.claimedTaps == [Self.tap(4), Self.tap(9)])
        try claims.release(.tuner, on: Self.tap(9))
        #expect(try claims.claimedTaps == [Self.tap(4)])
        try claims.release(.recorder, on: Self.tap(4))
        #expect(claims == MediaTapClaims())
    }

    @Test
    func sixteenTapsAreAcceptedAndTheSeventeenthIsRefusedWithTheCountItWouldReach() throws {
        var claims = try Self.filled(taps: 16)
        #expect(claims.claimedTaps.count == 16)
        let before = claims
        #expect(Self.refusal { try claims.claim(.playback, on: Self.tap(17)) } == .tooManyTaps(17))
        #expect(Self.refusal { try claims.claim(.tuner, on: Self.tap(Int.max)) } == .tooManyTaps(17))
        #expect(claims == before)
        var fifteen = try Self.filled(taps: 15)
        try fifteen.claim(.playback, on: Self.tap(16))
        #expect(fifteen == before)
    }

    @Test
    func aFullTableStillTakesAnotherRoleOnAHeldTapAndRefusesARepeatAsAlreadyClaimed() throws {
        var claims = try Self.filled(taps: 16)
        let tap = try Self.tap(8)
        try claims.claim(.recorder, on: tap)
        #expect(claims.claimedRoles(on: tap) == [.playback, .recorder])
        let before = claims
        #expect(Self.refusal { try claims.claim(.playback, on: tap) } == .alreadyClaimed(tap, .playback))
        #expect(claims == before)
    }

    @Test
    func aTapLeavesTheFullTableOnlyWhenItsLastRoleIsReleased() throws {
        var claims = try Self.filled(taps: 16)
        try claims.claim(.tuner, on: Self.tap(2))
        try claims.release(.playback, on: Self.tap(2))
        #expect(Self.refusal { try claims.claim(.playback, on: Self.tap(20)) } == .tooManyTaps(17))
        try claims.release(.tuner, on: Self.tap(2))
        try claims.claim(.playback, on: Self.tap(20))
        #expect(claims.claimedTaps.count == 16)
        #expect(try !claims.claimedTaps.contains(Self.tap(2)))
        #expect(try claims.claimedTaps.last == Self.tap(20))
    }

    @Test
    func claimedTapsAreAscendingAndRolesFollowRoleOrderWhateverTheClaimOrder() throws {
        var claims = MediaTapClaims()
        for value in [9, 3, Int.max, 12, 1] {
            try claims.claim(.tuner, on: Self.tap(value))
        }
        try claims.claim(.playback, on: Self.tap(12))
        #expect(try claims.claimedTaps == [1, 3, 9, 12, Int.max].map { try Self.tap($0) })
        #expect(try claims.claimedRoles(on: Self.tap(12)) == [.playback, .tuner])
        #expect(try claims.isClaimed(.tuner, on: Self.tap(Int.max)))
    }

    @Test
    func claimSequencesMatchAReferenceModelAcrossSeededRandomSteps() throws {
        var claims = MediaTapClaims()
        var held: [[Bool]] = Array(repeating: Array(repeating: false, count: 3), count: 20)
        var stepper = ClaimsStepper(state: 0x1203)
        for _ in 0..<600 {
            let tapIndex = stepper.next(20)
            let role = MediaTapRole.allCases[stepper.next(3)]
            let tap = try Self.tap(tapIndex + 1)
            let isHeld = held[tapIndex][Int(role.rawValue)]
            let tapsInUse = held.filter { $0.contains(true) }.count
            let tapIsNew = !held[tapIndex].contains(true)
            if stepper.next(2) == 0 {
                let found = Self.refusal { try claims.claim(role, on: tap) }
                if isHeld {
                    #expect(found == .alreadyClaimed(tap, role))
                } else if tapIsNew && tapsInUse == 16 {
                    #expect(found == .tooManyTaps(17))
                } else {
                    #expect(found == nil)
                    held[tapIndex][Int(role.rawValue)] = true
                }
            } else {
                let found = Self.refusal { try claims.release(role, on: tap) }
                #expect(found == (isHeld ? nil : .notClaimed(tap, role)))
                held[tapIndex][Int(role.rawValue)] = false
            }
            let expectedTaps = try held.indices.filter { held[$0].contains(true) }.map { try Self.tap($0 + 1) }
            #expect(claims.claimedTaps == expectedTaps)
            for index in held.indices {
                let expectedRoles = MediaTapRole.allCases.filter { held[index][Int($0.rawValue)] }
                #expect(try claims.claimedRoles(on: Self.tap(index + 1)) == expectedRoles)
            }
        }
    }
}
