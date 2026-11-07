//
//  MIDIHostStamping.swift
//  FluxKlang
//
//  The exact inverse of `SampleClockMap.frame(atHost:current:)`: the host tick to schedule a frame at (#84).
//

/// Host-time lookahead for planned frames.
enum MIDIHostStamping {
    /// The earliest host tick whose forward frame (`SampleClockMap.frame(atHost:current:)`) is at least `frame`, so a
    /// message scheduled at the returned tick is never early.
    ///
    /// The forward function is `F0 + roundHalfUp((h - H0) * N, D)` with `N = numer * rate`, `D = denom * 10^9`
    /// and `roundHalfUp(x, D) = floor(x / D + 1/2)`. With `T = frame - F0` it reaches `frame` when
    /// `(h - H0) >= D * (2T - 1) / (2N)`, so the stamp is `H0 + ceil(D * (2T - 1) / (2N))`, computed in Int128.
    /// Because the forward function rounds half-up, the stamp of the anchor frame itself can precede the anchor
    /// host tick. A stamp outside `UInt64`, or one at which the forward frame leaves `Int64`, is refused with
    /// `.overflow`, and a map of another sample-clock generation with `.staleSampleGeneration`.
    static func hostStamp(forFrame frame: Int64, in map: SampleClockMap, current: Generation) throws(ClockMapError)
        -> HostStamp {
        guard map.anchor.sample.generation == current else { throw .staleSampleGeneration }
        let numerator = Int128(map.timebase.numer) * Int128(map.nominalRate)
        let denominator = Int128(map.timebase.denom) * ExactMath.nanosPerSecond
        let elapsed = Int128(frame) - Int128(map.anchor.sample.frame)
        // The product is below 1.6e38 for every UInt32 timebase, so this guard is defensive.
        let (scaled, overflow) = denominator.multipliedReportingOverflow(by: 2 * elapsed - 1)
        guard !overflow else { throw .overflow }
        let ticks = Int128(map.anchor.host.ticks) + ExactMath.ceilDiv(scaled, 2 * numerator)
        guard let host = UInt64(exactly: ticks) else { throw .overflow }
        let stamp = HostStamp(ticks: host)
        // The forward function must evaluate at the stamp; it refuses frames beyond Int64.
        _ = try map.frame(atHost: stamp, current: current)
        return stamp
    }
}
