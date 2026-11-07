/// Read-only mapping between host stamps and frame counts at the exact real rate.
extension MTCFollower {
    /// The frame count at `stamp`, extrapolated from the anchor (frozen after a locate).
    func frameCount(at stamp: HostStamp) throws(MTCFollowerError) -> Int {
        let anchor = try position()
        guard stamp.ticks >= anchor.stamp else {
            throw .queryPrecedesAnchor(anchor: anchor.stamp, received: stamp.ticks)
        }
        return try anchor.frameCount(atTicks: stamp.ticks, timebase: timebase)
    }

    /// The first host stamp at which the follower reaches `frameCount`, moving with the direction of travel.
    /// Crossing midnight is refused: the target must lie ahead within the same day.
    func host(forFrameCount frameCount: Int) throws(MTCFollowerError) -> HostStamp {
        let anchor = try position()
        guard let direction = anchor.direction else { throw .stationary }
        let day = anchor.rate.framesPerDay
        guard (0..<day).contains(frameCount) else {
            throw .frameCountOutOfRange(frameCount: frameCount, framesPerDay: day)
        }
        let ahead = direction == .forward ? frameCount - anchor.frameCount : anchor.frameCount - frameCount
        guard ahead >= 0 else { throw .behindDirectionOfTravel(frameCount: frameCount, anchor: anchor.frameCount) }
        let ticks = try MTCRealRate(anchor.rate).hostTicks(forFrames: Int64(ahead), timebase: timebase)
        let (sum, overflow) = anchor.stamp.addingReportingOverflow(ticks)
        if overflow { throw .overflow }
        return HostStamp(ticks: sum)
    }

    private func position() throws(MTCFollowerError) -> MTCFollowerAnchor {
        guard state != .absent, state != .lost, let anchor else { throw .noPosition }
        return anchor
    }
}
