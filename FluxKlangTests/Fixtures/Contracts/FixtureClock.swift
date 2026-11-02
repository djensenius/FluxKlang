//
//  FixtureClock.swift
//  FluxKlangTests
//
//  A scripted host clock: ticks advance by a fixed step from a fixed start,
//  so every run sees the same stamps. It never reads the system clock.
//

@testable import FluxKlang

/// Why a clock was not created or refused to tick. A refusal changes nothing.
enum FixtureClockError: Error, Equatable, Sendable {
    case invalidStep
    case invalidTimebase
    /// The next tick would pass `UInt64.max`.
    case exhausted
}

struct FixtureHostClock: Hashable, Sendable {
    let step: UInt64
    let timebase: HostTimebase
    private(set) var now: HostStamp

    init(
        startTicks: UInt64 = 1_000,
        step: UInt64 = 1_000,
        timebase: HostTimebase = HostTimebase(numer: 1, denom: 1)
    ) throws(FixtureClockError) {
        guard step > 0 else { throw .invalidStep }
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
        self.step = step
        self.timebase = timebase
        now = HostStamp(ticks: startTicks)
    }

    /// Advances by `step` and returns the new stamp.
    mutating func tick() throws(FixtureClockError) -> HostStamp {
        let (ticks, overflow) = now.ticks.addingReportingOverflow(step)
        guard !overflow else { throw .exhausted }
        now = HostStamp(ticks: ticks)
        return now
    }

    /// An anchor observed at the current host stamp, without musical time.
    func anchor(
        frame: Int64,
        generation: Generation = .initial,
        clock: ClockID = ContractFixtureIDs.primaryClock
    ) -> ClockAnchor {
        ClockAnchor(sample: SampleStamp(clock: clock, generation: generation, frame: frame), host: now)
    }
}
