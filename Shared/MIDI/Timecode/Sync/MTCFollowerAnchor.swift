/// A known position: the frame count valid at one host stamp, with the direction of travel (nil when stationary).
struct MTCFollowerAnchor: Equatable, Hashable, Sendable {
    let frameCount: Int
    let stamp: UInt64
    let rate: SMPTEFrameRate
    let direction: MTCDirection?

    /// Host ticks added to the elapsed time of the relocation judgement only: two stamps that were each rounded to a
    /// whole tick can place a position one tick short of its exact frame boundary, which would floor to one frame less.
    /// The cost, at tolerance 0 only: a relocation one frame further along the direction of travel than continuous
    /// play goes unreported when the elapsed time is exactly one tick short of a frame boundary, because the slack
    /// then makes the jump look like continuous play. The follower factory guarantees the slack is under half a frame
    /// period by refusing timebases whose tick is not shorter than half a 30 fps frame (`.timebaseTooCoarse`).
    /// Direct callers of `MTCRealRate` and `MTCFollowerAnchor` are not guarded by that check, so the slack is sound
    /// only for timebases the factory accepted.
    static let relocationSlackTicks: UInt64 = 1

    /// The frame count extrapolated to `ticks` at the exact real rate, wrapped into the 24-hour day.
    func frameCount(atTicks ticks: UInt64, timebase: HostTimebase) throws(MTCFollowerError) -> Int {
        try frameCount(atTicks: ticks, slackTicks: 0, timebase: timebase)
    }

    private func frameCount(atTicks ticks: UInt64, slackTicks: UInt64,
                            timebase: HostTimebase) throws(MTCFollowerError) -> Int {
        guard let direction else { return frameCount }
        let (elapsed, overflow) = (ticks - stamp).addingReportingOverflow(slackTicks)
        if overflow { throw .overflow }
        let whole = try Int128(MTCRealRate(rate).wholeFrames(inTicks: elapsed, timebase: timebase))
        let day = Int128(rate.framesPerDay)
        let moved = Int128(frameCount) + (direction == .forward ? whole : -whole)
        return Int(((moved % day) + day) % day)
    }

    /// Shortest distance in frames between two counts of the same day, going either way round midnight.
    static func distance(_ lhs: Int, _ rhs: Int, day: Int) -> Int {
        let difference = abs(lhs - rhs)
        return min(difference, day - difference)
    }

    /// How `next` deviates from this anchor's extrapolation: a direction change, a rate change, or a relocation.
    /// A direction or rate change excludes the relocation judgement, which only runs when `judgesRelocation` is set.
    func deviations(to next: MTCFollowerAnchor, toleranceFrames: Int, judgesRelocation: Bool,
                    timebase: HostTimebase) throws(MTCFollowerError) -> [MTCFollowerEvent] {
        var events: [MTCFollowerEvent] = []
        if let from = direction, let to = next.direction, from != to {
            events.append(.directionChanged(from: from, to: to))
        }
        if rate != next.rate { events.append(.rateChanged(from: rate, to: next.rate)) }
        guard events.isEmpty, judgesRelocation else { return events }
        let expected = try frameCount(atTicks: next.stamp, slackTicks: Self.relocationSlackTicks, timebase: timebase)
        if Self.distance(expected, next.frameCount, day: rate.framesPerDay) > toleranceFrames {
            events.append(.relocated(frameCount: next.frameCount))
        }
        return events
    }
}
