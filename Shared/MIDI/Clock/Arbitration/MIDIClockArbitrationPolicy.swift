//
//  MIDIClockArbitrationPolicy.swift
//  FluxKlang
//
//  The validated product values of MIDI clock leader arbitration: the source
//  table bound, the leader pulse timeout, the reacquire pulse count and the
//  jitter tolerance a steady pulse must meet. Built only through `make`.
//

/// Validated arbitration limits. Every value is checked against its range by `make`.
struct MIDIClockArbitrationPolicy: Equatable, Sendable {
    static let maximumSourcesRange = 1...64
    static let reacquirePulsesRange = 2...96
    static let timeoutNanosRange: ClosedRange<Int64> = 50_000_000...2_000_000_000
    static let jitterTolerancePerMilleRange = 1...500

    /// 16 sources, 500 ms timeout, 24 steady pulses (one quarter) and 25 % jitter tolerance.
    static let standard = MIDIClockArbitrationPolicy(
        validatedMaximumSources: 16, timeoutNanos: 500_000_000, reacquirePulses: 24, jitterTolerancePerMille: 250
    )

    /// The most sources the arbiter's table holds; one more is refused.
    var maximumSources: Int { storedMaximumSources }
    /// A leader pulse gap strictly longer than this loses the leader.
    var timeoutNanos: Int64 { storedTimeoutNanos }
    /// N: the consecutive steady pulses that lock or relock the leader.
    var reacquirePulses: Int { storedReacquirePulses }
    /// A pulse is steady when its interval differs from the previous one by at most this many thousandths of it.
    var jitterTolerancePerMille: Int { storedJitterTolerancePerMille }

    private let storedMaximumSources: Int
    private let storedTimeoutNanos: Int64
    private let storedReacquirePulses: Int
    private let storedJitterTolerancePerMille: Int

    private init(validatedMaximumSources maximumSources: Int, timeoutNanos: Int64, reacquirePulses: Int,
                 jitterTolerancePerMille: Int) {
        storedMaximumSources = maximumSources
        storedTimeoutNanos = timeoutNanos
        storedReacquirePulses = reacquirePulses
        storedJitterTolerancePerMille = jitterTolerancePerMille
    }

    static func make(maximumSources: Int, timeoutNanos: Int64, reacquirePulses: Int,
                     jitterTolerancePerMille: Int) throws(MIDIClockArbitrationError) -> Self {
        guard maximumSourcesRange.contains(maximumSources) else { throw .invalidMaximumSources(maximumSources) }
        guard timeoutNanosRange.contains(timeoutNanos) else { throw .invalidTimeout(nanos: timeoutNanos) }
        guard reacquirePulsesRange.contains(reacquirePulses) else { throw .invalidReacquirePulses(reacquirePulses) }
        guard jitterTolerancePerMilleRange.contains(jitterTolerancePerMille) else {
            throw .invalidJitterTolerance(perMille: jitterTolerancePerMille)
        }
        return Self(validatedMaximumSources: maximumSources, timeoutNanos: timeoutNanos,
                    reacquirePulses: reacquirePulses, jitterTolerancePerMille: jitterTolerancePerMille)
    }
}
