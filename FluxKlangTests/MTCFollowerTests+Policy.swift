import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MTCFollowerTests {
    @Test func policyDefaultsAreExact() throws {
        let policy = MTCFollowerPolicy.standard
        #expect(policy.lockPositions == 2)
        #expect(policy.toleranceFrames == 1)
        #expect(policy.dropoutFrames == 2)
        #expect(policy.freewheelNanoseconds == 1_000_000_000)
        #expect(try MTCFollowerPolicy.make() == policy)
    }

    @Test func lockPositionsAccept1And8AndRefuse0And9() throws {
        #expect(try Self.policy(lock: 1).lockPositions == 1)
        #expect(try Self.policy(lock: 8).lockPositions == 8)
        #expect(Self.thrown { try Self.policy(lock: 0) } == .policyOutOfRange(field: .lockPositions, value: 0))
        #expect(Self.thrown { try Self.policy(lock: 9) } == .policyOutOfRange(field: .lockPositions, value: 9))
    }

    @Test func toleranceFramesAccept0And4AndRefuseMinus1And5() throws {
        #expect(try Self.policy(tolerance: 0).toleranceFrames == 0)
        #expect(try Self.policy(tolerance: 4).toleranceFrames == 4)
        #expect(Self.thrown { try Self.policy(tolerance: -1) } == .policyOutOfRange(field: .toleranceFrames, value: -1))
        #expect(Self.thrown { try Self.policy(tolerance: 5) } == .policyOutOfRange(field: .toleranceFrames, value: 5))
    }

    @Test func dropoutFramesAccept1And30AndRefuse0And31() throws {
        #expect(try Self.policy(dropout: 1).dropoutFrames == 1)
        #expect(try Self.policy(dropout: 30).dropoutFrames == 30)
        #expect(Self.thrown { try Self.policy(dropout: 0) } == .policyOutOfRange(field: .dropoutFrames, value: 0))
        #expect(Self.thrown { try Self.policy(dropout: 31) } == .policyOutOfRange(field: .dropoutFrames, value: 31))
    }

    @Test func freewheelNanosecondsAcceptTheBoundsAndRefuseOneOutside() throws {
        #expect(try Self.policy(freewheel: 1_000_000).freewheelNanoseconds == 1_000_000)
        #expect(try Self.policy(freewheel: 60_000_000_000).freewheelNanoseconds == 60_000_000_000)
        #expect(Self.thrown { try Self.policy(freewheel: 999_999) }
                == .policyOutOfRange(field: .freewheelNanoseconds, value: 999_999))
        #expect(Self.thrown { try Self.policy(freewheel: 60_000_000_001) }
                == .policyOutOfRange(field: .freewheelNanoseconds, value: 60_000_000_001))
        #expect(Self.thrown { try Self.policy(freewheel: Int64.min) }
                == .policyOutOfRange(field: .freewheelNanoseconds, value: Int64.min))
    }

    @Test func theFirstOutOfRangeFieldInDeclarationOrderIsReported() {
        #expect(Self.thrown { try Self.policy(lock: 0, tolerance: 9, dropout: 99, freewheel: 1) }
                == .policyOutOfRange(field: .lockPositions, value: 0))
        #expect(Self.thrown { try Self.policy(tolerance: 9, dropout: 99, freewheel: 1) }
                == .policyOutOfRange(field: .toleranceFrames, value: 9))
        #expect(Self.thrown { try Self.policy(dropout: 99, freewheel: 1) }
                == .policyOutOfRange(field: .dropoutFrames, value: 99))
        #expect(Self.thrown { try Self.policy(freewheel: 1) }
                == .policyOutOfRange(field: .freewheelNanoseconds, value: 1))
    }
}
