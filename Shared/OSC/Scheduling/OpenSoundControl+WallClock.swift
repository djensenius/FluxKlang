//
//  OpenSoundControl+WallClock.swift
//  FluxKlang
//
//  Wall-clock instants on the NTP timescale across its 2036 wrap, the injected
//  wall-to-host mapping and the exact host-tick bounds a time tag names. Pure:
//  nothing here reads a clock. Arithmetic is exact Int128 with overflow checks;
//  only the final host-tick bounds round, always outwards.
//

extension OpenSoundControl {
    /// An instant on the NTP timescale extended by an era number:
    /// `era · 2³² s + seconds + fraction · 2⁻³² s` after 1900-01-01T00:00:00Z.
    /// Era 0 ends at 2036-02-07T06:28:16Z, where era 1 begins.
    struct WallInstant: Sendable, Hashable, Comparable, CustomStringConvertible {
        /// 1900 to roughly 36 800 CE; resolving outside this range is refused.
        static let supportedEras: ClosedRange<Int> = 0...255

        /// Exact 2⁻³² s units since era 0 began.
        private(set) var units: Int128

        init(era: Int, seconds: UInt32, fraction: UInt32) throws(SchedulingRefusal) {
            guard Self.supportedEras.contains(era) else { throw .eraOutOfRange(era) }
            units = Int128(era) << 64 | Int128(TimeTag(seconds: seconds, fraction: fraction).rawValue)
        }

        private init(validatedUnits: Int128) {
            units = validatedUnits
        }

        var era: Int { Int(units >> 64) }
        /// The 64-bit tag that names this instant in its own era.
        var timeTag: TimeTag { TimeTag(rawValue: UInt64(truncatingIfNeeded: units)) }
        var description: String { "era \(era) + \(timeTag.seconds) s + \(timeTag.fraction) / 2^32 s" }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.units < rhs.units }

        /// The instant `timeTag` names in the era that puts it nearest to this
        /// reference. The offset is the RFC 5905 two's-complement difference, so
        /// it lies in `[-2³¹ s, 2³¹ s)`: an exact tie resolves into the past.
        func resolve(_ timeTag: TimeTag) throws(SchedulingRefusal) -> WallInstant {
            let offset = Int64(bitPattern: timeTag.rawValue &- UInt64(truncatingIfNeeded: units))
            let resolved = try CheckedInt128.add(units, Int128(offset))
            let era = Int(resolved >> 64)
            guard Self.supportedEras.contains(era) else { throw .eraOutOfRange(era) }
            return WallInstant(validatedUnits: resolved)
        }
    }

    /// An injected statement that host tick `host` coincided with wall instant
    /// `wall`, how fast the host clock runs relative to wall time and how wrong
    /// the statement may be. Host elapsed time is wall elapsed time scaled by
    /// `1 + rate · 10⁻⁹`; a prediction `Δ` away from the anchor may err by
    /// `uncertainty + |Δ| · rateUncertainty · 10⁻⁹`. The anchor's wall instant is
    /// also the reference that resolves time-tag eras.
    struct WallClockMapping: Sendable, Hashable {
        /// ±1000 ppm, far beyond any disciplined or free-running crystal.
        static let rateLimitPartsPerBillion = 1_000_000
        /// One hour: past this, wall time says nothing useful about host time.
        static let maximumUncertaintyNanoseconds: UInt64 = 3_600_000_000_000

        private(set) var wall: WallInstant
        private(set) var host: HostStamp
        private(set) var uncertaintyNanoseconds: UInt64
        private(set) var ratePartsPerBillion: Int
        private(set) var rateUncertaintyPartsPerBillion: Int

        init(
            wall: WallInstant, host: HostStamp, uncertaintyNanoseconds: UInt64,
            ratePartsPerBillion: Int = 0, rateUncertaintyPartsPerBillion: Int = 0
        ) throws(SchedulingRefusal) {
            let limit = Self.rateLimitPartsPerBillion
            guard (-limit...limit).contains(ratePartsPerBillion) else {
                throw .rateOutOfRange(partsPerBillion: ratePartsPerBillion)
            }
            guard (0...limit).contains(rateUncertaintyPartsPerBillion) else {
                throw .rateUncertaintyOutOfRange(partsPerBillion: rateUncertaintyPartsPerBillion)
            }
            guard uncertaintyNanoseconds <= Self.maximumUncertaintyNanoseconds else {
                throw .uncertaintyOutOfRange(nanoseconds: uncertaintyNanoseconds)
            }
            self.wall = wall
            self.host = host
            self.uncertaintyNanoseconds = uncertaintyNanoseconds
            self.ratePartsPerBillion = ratePartsPerBillion
            self.rateUncertaintyPartsPerBillion = rateUncertaintyPartsPerBillion
        }

        /// Exact host-tick bounds, possibly outside `UInt64`, of the time tag's
        /// whole 2⁻³² s quantum `[instant, instant + 1 unit]` widened by the
        /// stated uncertainty. With `D = 2³² · numer` ticks per unit-nanosecond:
        /// `earliest = host + ⌊(Δ·scale − |Δ|·spread − slack) / D⌋` and
        /// `latest = host + ⌈((Δ+1)·scale + |Δ+1|·spread + slack) / D⌉`, where
        /// `scale = (10⁹ + rate)·denom`, `spread = rateUncertainty·denom` and
        /// `slack = uncertainty·2³²·denom`. No intermediate nanosecond rounding.
        func hostBounds(
            of instant: WallInstant, timebase: HostTimebase
        ) throws(SchedulingRefusal) -> (earliest: Int128, latest: Int128) {
            guard timebase.numer > 0, timebase.denom > 0 else {
                throw .invalidTimebase(numer: timebase.numer, denom: timebase.denom)
            }
            let denom = Int128(timebase.denom)
            let divisor = Int128(timebase.numer) << 32
            let delta = try CheckedInt128.subtract(instant.units, wall.units)
            let after = try CheckedInt128.add(delta, 1)
            let scale = try CheckedInt128.multiply(Int128(1_000_000_000 + ratePartsPerBillion), denom)
            let spread = try CheckedInt128.multiply(Int128(rateUncertaintyPartsPerBillion), denom)
            let slack = try CheckedInt128.multiply(Int128(uncertaintyNanoseconds) << 32, denom)
            let low = try CheckedInt128.subtract(
                CheckedInt128.multiply(delta, scale),
                CheckedInt128.add(CheckedInt128.multiply(CheckedInt128.magnitude(delta), spread), slack)
            )
            let high = try CheckedInt128.add(
                CheckedInt128.multiply(after, scale),
                CheckedInt128.add(CheckedInt128.multiply(CheckedInt128.magnitude(after), spread), slack)
            )
            let origin = Int128(host.ticks)
            return (try CheckedInt128.add(origin, ExactMath.floorDiv(low, divisor)),
                    try CheckedInt128.add(origin, ExactMath.ceilDiv(high, divisor)))
        }
    }

    /// Overflow-checked Int128 steps; an overflow is a typed refusal, never a trap.
    enum CheckedInt128 {
        static func add(_ lhs: Int128, _ rhs: Int128) throws(SchedulingRefusal) -> Int128 {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw .arithmeticOverflow }
            return value
        }

        static func subtract(_ lhs: Int128, _ rhs: Int128) throws(SchedulingRefusal) -> Int128 {
            let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
            guard !overflow else { throw .arithmeticOverflow }
            return value
        }

        static func multiply(_ lhs: Int128, _ rhs: Int128) throws(SchedulingRefusal) -> Int128 {
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            guard !overflow else { throw .arithmeticOverflow }
            return value
        }

        static func magnitude(_ value: Int128) throws(SchedulingRefusal) -> Int128 {
            value < 0 ? try subtract(0, value) : value
        }
    }
}
