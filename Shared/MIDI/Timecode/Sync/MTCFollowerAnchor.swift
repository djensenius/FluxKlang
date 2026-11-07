/// A known position: the frame count valid at one host stamp, with the direction of travel (nil when stationary).
struct MTCFollowerAnchor: Equatable, Hashable, Sendable {
    let frameCount: Int
    let stamp: UInt64
    let rate: SMPTEFrameRate
    let direction: MTCDirection?

    /// The frame count extrapolated to `ticks` at the exact real rate, wrapped into the 24-hour day.
    func frameCount(atTicks ticks: UInt64, timebase: HostTimebase) throws(MTCFollowerError) -> Int {
        guard let direction else { return frameCount }
        let whole = try Int128(MTCRealRate(rate).wholeFrames(inTicks: ticks - stamp, timebase: timebase))
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
    /// A direction or rate change excludes the relocation judgement.
    func deviations(to next: MTCFollowerAnchor, toleranceFrames: Int,
                    timebase: HostTimebase) throws(MTCFollowerError) -> [MTCFollowerEvent] {
        var events: [MTCFollowerEvent] = []
        if let from = direction, let to = next.direction, from != to {
            events.append(.directionChanged(from: from, to: to))
        }
        if rate != next.rate { events.append(.rateChanged(from: rate, to: next.rate)) }
        guard events.isEmpty else { return events }
        let expected = try frameCount(atTicks: next.stamp, timebase: timebase)
        if Self.distance(expected, next.frameCount, day: rate.framesPerDay) > toleranceFrames {
            events.append(.relocated(frameCount: next.frameCount))
        }
        return events
    }
}
