/// Exact integer arithmetic from quarter-frame indices to host ticks.
enum MTCEmitTimebase {
    /// Frames per second as the exact fraction `numerator / denominator`.
    struct Fraction: Equatable, Sendable {
        let numerator: Int128
        let denominator: Int128
    }

    static func frameRate(for rate: SMPTEFrameRate) -> Fraction {
        switch rate {
        case .fps24: Fraction(numerator: 24, denominator: 1)
        case .fps25: Fraction(numerator: 25, denominator: 1)
        case .fps2997DropFrame: Fraction(numerator: 30_000, denominator: 1_001)
        case .fps30: Fraction(numerator: 30, denominator: 1)
        }
    }

    /// Whether one quarter-frame period lasts at least one host tick, decided on integers.
    static func resolvesQuarterFrames(rate: SMPTEFrameRate, timebase: HostTimebase) -> Bool {
        let fps = frameRate(for: rate)
        let periodSide = ExactMath.nanosPerSecond * fps.denominator * Int128(timebase.denom)
        let tickSide = 4 * fps.numerator * Int128(timebase.numer)
        return periodSide >= tickSide
    }

    /// The host tick of quarter frame `quarter`: `origin + floor(quarter * D * 1e9 * denom / (4 * N * numer))`,
    /// computed from the origin so no rounding accumulates.
    static func tick(
        origin: UInt64, quarter: Int, rate: SMPTEFrameRate, timebase: HostTimebase
    ) throws(MTCEmitRefusal) -> UInt64 {
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
        let fps = frameRate(for: rate)
        let numerator = try product([Int128(quarter), fps.denominator, ExactMath.nanosPerSecond,
                                     Int128(timebase.denom)])
        let denominator = try product([4, fps.numerator, Int128(timebase.numer)])
        let offset = ExactMath.floorDiv(numerator, denominator)
        guard let tick = UInt64(exactly: Int128(origin) + offset) else { throw .tickOverflow }
        return tick
    }

    /// The product of `factors`, refusing with `tickOverflow` when it does not fit in `Int128`; for the inputs the
    /// plan builds the refusal cannot occur, and it is reached only by a direct call with an extreme quarter index.
    private static func product(_ factors: [Int128]) throws(MTCEmitRefusal) -> Int128 {
        var result: Int128 = 1
        for factor in factors {
            let (next, overflow) = result.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw .tickOverflow }
            result = next
        }
        return result
    }
}
