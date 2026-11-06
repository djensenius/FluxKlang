//
//  MIDIClockArbitrationPolicy.swift
//  FluxKlang
//
//  The validated product values of MIDI clock leader arbitration: the source
//  table bound, the leader silence timeout, the reacquire pulse count and the
//  jitter tolerance a steady pulse must meet. Built only through `make`.
//

/// Validated arbitration limits. Every value is checked against its range by `make`.
struct MIDIClockArbitrationPolicy: Equatable, Sendable {
    static let maximumSourcesRange = 1...64
    static let reacquirePulsesRange = 2...96
    static let timeoutNanosRange: ClosedRange<Int64> = 50_000_000...2_000_000_000
    static let jitterTolerancePerMilleRange = 1...500

    /// 16 sources, 500 ms timeout, 24 steady pulses (one quarter) and a quarter period of jitter beyond the lag.
    static let standard = MIDIClockArbitrationPolicy(
        validatedMaximumSources: 16, timeoutNanos: 500_000_000, reacquirePulses: 24, jitterTolerancePerMille: 250
    )

    /// The most sources the arbiter's table holds; one more is refused.
    var maximumSources: Int { storedMaximumSources }
    /// Leader silence strictly longer than this loses the leader while its transport runs and idles it while
    /// stopped. Clocks may arrive up to L = 2 pulses late (C1's lag bound), so one gap can span L + 1 pulse
    /// intervals: the timeout must exceed (L + 1) times the slowest pulse interval the leader is expected to send
    /// (375 ms at 20 BPM, 125 ms per pulse), or a slow leader's batched clocks read as silence. The 50 ms floor
    /// bounds the value, not the tempo.
    var timeoutNanos: Int64 { storedTimeoutNanos }
    /// N: the steady pulses that lock or relock the leader.
    var reacquirePulses: Int { storedReacquirePulses }
    /// A pulse is steady when it lands within L + this many thousandths of the run's reference period of its
    /// due time, where L = 2 is the tempo estimator's lag bound (`MIDIClockSteadyRun`).
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
