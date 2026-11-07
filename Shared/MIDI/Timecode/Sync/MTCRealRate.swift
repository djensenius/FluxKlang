/// Exact frame rate as a reduced rational (frames per second = numerator / denominator) and the
/// frame <-> host tick conversions on a host timebase. No floating point: every boundary is one integer division.
struct MTCRealRate: Equatable, Hashable, Sendable {
    let rate: SMPTEFrameRate
    let numerator: Int64
    let denominator: Int64

    init(_ rate: SMPTEFrameRate) {
        self.rate = rate
        switch rate {
        case .fps24: (numerator, denominator) = (24, 1)
        case .fps25: (numerator, denominator) = (25, 1)
        case .fps2997DropFrame: (numerator, denominator) = (30_000, 1_001)
        case .fps30: (numerator, denominator) = (30, 1)
        }
    }

    /// The first host tick at or after the start of frame `frames`: `ceil(frames * q * 1e9 * D / (p * N))`.
    func hostTicks(forFrames frames: Int64, timebase: HostTimebase) throws(MTCFollowerError) -> UInt64 {
        try Self.narrow(UInt64.self, try ticks(forFrames: Int128(frames), timebase: timebase))
    }

    /// Whole frames elapsed after `ticks` host ticks: `floor(ticks * N * p / (D * 1e9 * q))`.
    func wholeFrames(inTicks ticks: UInt64, timebase: HostTimebase) throws(MTCFollowerError) -> Int64 {
        try Self.narrow(Int64.self, try frames(inTicks: Int128(ticks), timebase: timebase))
    }

    func ticks(forFrames frames: Int128, timebase: HostTimebase) throws(MTCFollowerError) -> Int128 {
        try Self.validate(timebase)
        guard frames >= 0 else { throw .overflow }
        let numer = try Self.product(frames, Int128(denominator), ExactMath.nanosPerSecond, Int128(timebase.denom))
        let denom = try Self.product(Int128(numerator), Int128(timebase.numer))
        return ExactMath.ceilDiv(numer, denom)
    }

    func frames(inTicks ticks: Int128, timebase: HostTimebase) throws(MTCFollowerError) -> Int128 {
        try Self.validate(timebase)
        let numer = try Self.product(ticks, Int128(timebase.numer), Int128(numerator))
        let denom = try Self.product(Int128(timebase.denom), ExactMath.nanosPerSecond, Int128(denominator))
        return ExactMath.floorDiv(numer, denom)
    }

    static func validate(_ timebase: HostTimebase) throws(MTCFollowerError) {
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
    }

    /// The fastest supported rate (30 fps) has the shortest frame, and a host tick must be strictly shorter than half
    /// of it, so the one-tick relocation slack of `MTCFollowerAnchor` stays under half a frame period.
    private static let fastestFramesPerSecond: UInt64 = 30
    private static let framePeriodFractionDivisor: UInt64 = 2
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    /// Accepts a (valid) timebase of `numer / denom` ns per tick iff
    /// `numer / denom < 1e9 / (fastest fps * divisor)`, decided on integers: `numer * 60 < 1e9 * denom`.
    /// Both products fit `UInt64` for every `UInt32` input (at most 2.6e11 and 4.3e18).
    static func requireFollowerResolution(_ timebase: HostTimebase) throws(MTCFollowerError) {
        let scale = fastestFramesPerSecond * framePeriodFractionDivisor
        guard UInt64(timebase.numer) * scale < nanosecondsPerSecond * UInt64(timebase.denom) else {
            throw .timebaseTooCoarse
        }
    }

    static func narrow<Integer: FixedWidthInteger>(
        _ type: Integer.Type, _ value: Int128
    ) throws(MTCFollowerError) -> Integer {
        guard let narrowed = Integer(exactly: value) else { throw .overflow }
        return narrowed
    }

    private static func product(_ factors: Int128...) throws(MTCFollowerError) -> Int128 {
        var result: Int128 = 1
        for factor in factors {
            let (next, overflow) = result.multipliedReportingOverflow(by: factor)
            if overflow { throw .overflow }
            result = next
        }
        return result
    }
}
