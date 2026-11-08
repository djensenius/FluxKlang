//
//  SpatialMotionSampling.swift
//  FluxKlang
//
//  Evaluates a bounded run of sample frames of a spatial motion path (#116).
//

extension SpatialMotionPath {
    /// Positions at `firstFrame + i * stepFrames` for i in 0..<count, each computed directly from its own frame. The
    /// checks run in this order: a count outside 0...4096, a step below 1 (also when the count is 0), a count of 0
    /// (which returns an empty array whatever the first frame), then an overflow of the span
    /// `(count - 1) * stepFrames` or of the last frame `firstFrame + span`. All of them run before any allocation.
    /// Negative first frames are valid.
    func samples(
        firstFrame: Int64,
        stepFrames: Int64,
        count: Int
    ) throws(SpatialMotionRefusal) -> [NeutralPoint] {
        guard (0...Self.maximumSamples).contains(count) else { throw .sampleCountOutOfRange(count) }
        guard stepFrames >= 1 else { throw .stepNotPositive(stepFrames) }
        guard count > 0 else { return [] }
        let (span, spanOverflow) = Int64(count - 1).multipliedReportingOverflow(by: stepFrames)
        guard !spanOverflow else { throw .frameOverflow }
        let (_, lastOverflow) = firstFrame.addingReportingOverflow(span)
        guard !lastOverflow else { throw .frameOverflow }
        var points: [NeutralPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            points.append(point(at: firstFrame + Int64(index) * stepFrames))
        }
        return points
    }
}
