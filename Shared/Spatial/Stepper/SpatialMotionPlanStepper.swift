//
//  SpatialMotionPlanStepper.swift
//  FluxKlang
//
//  Turns a spatial motion path into render plans for one moving source (#116). Pure and deterministic; it reads no
//  time source and plays nothing. Control thread only: `SpatialRenderer.plan` allocates, so this never runs on the
//  audio thread. No caller exists yet.
//

/// Moves ONE placement of a render request along a `SpatialMotionPath` and builds plans through
/// `SpatialRenderer.plan`. Each plan equals the renderer's plan of the request with only that placement's position
/// replaced, so the rows and columns keep one shape across a call (this holds for every request the renderer accepts).
/// A `loop` path whose last point differs from its
/// first makes the plan jump at the wrap; smoothing is the consumer's job.
enum SpatialMotionPlanStepper {
    /// Plans per call.
    static let maximumPlans = 256
    /// Gains over all plans of one call (512 KiB of `Double`).
    static let maximumCells = 65_536

    /// The plan at one sample frame. Runs the source count check, the placement check and the renderer, in that order.
    static func plan(
        request: SpatialRenderRequest,
        path: SpatialMotionPath,
        frame: Int64
    ) throws(SpatialMotionPlanRefusal) -> SpatialRenderPlan {
        let index = try movingIndex(in: request, path: path)
        return try render(request, movingIndex: index, to: path.point(at: frame))
    }

    /// The plans at `firstFrame + i * stepFrames` for i in 0..<count. The refusal order is documented on
    /// `SpatialMotionPlanRefusal`; nothing partial is ever returned.
    static func plans(
        request: SpatialRenderRequest,
        path: SpatialMotionPath,
        firstFrame: Int64,
        stepFrames: Int64,
        count: Int
    ) throws(SpatialMotionPlanRefusal) -> [SpatialRenderPlan] {
        guard (0...maximumPlans).contains(count) else { throw .planCountOutOfRange(count) }
        guard stepFrames >= 1 else { throw .motion(.stepNotPositive(stepFrames)) }
        let index = try movingIndex(in: request, path: path)
        guard count > 0 else { return [] }
        // The count is at most 256 and cellsPerPlan at most 8,192 once movingIndex has run, so the product is at most
        // 2,097,152 and cannot overflow Int.
        let cells = count * cellsPerPlan(of: request)
        guard cells <= maximumCells else { throw .tooManyCells(cells) }
        let positions = try samples(of: path, firstFrame: firstFrame, stepFrames: stepFrames, count: count)
        var result: [SpatialRenderPlan] = []
        result.reserveCapacity(count)
        for position in positions {
            result.append(try render(request, movingIndex: index, to: position))
        }
        return result
    }

    private static func samples(
        of path: SpatialMotionPath,
        firstFrame: Int64,
        stepFrames: Int64,
        count: Int
    ) throws(SpatialMotionPlanRefusal) -> [NeutralPoint] {
        do {
            return try path.samples(firstFrame: firstFrame, stepFrames: stepFrames, count: count)
        } catch {
            throw .motion(error)
        }
    }

    /// The index of the one placement for `path.source`, after the source count check that bounds the scan.
    private static func movingIndex(
        in request: SpatialRenderRequest,
        path: SpatialMotionPath
    ) throws(SpatialMotionPlanRefusal) -> Int {
        let placements = request.placements
        guard placements.count <= SpatialRenderer.maximumSources else {
            throw .render(.tooManySources(placements.count))
        }
        guard let index = placements.firstIndex(where: { $0.sourceID == path.source }) else {
            throw .sourceNotPlaced(path.source)
        }
        return index
    }

    /// Rows (the sum of the channel counts) times speakers. Every placement has 1 or 2 channels
    /// (`SpatialSourcePlacement.channelCounts`) and a layout holds at most 64 speakers
    /// (`SpatialLayout.maximumSpeakers`). The only initializers enforce both limits and decoding checks them again.
    /// The caller has checked the source count (at most 64), so rows are at most 128 and the result is at most 8,192:
    /// neither the sum nor the product can overflow `Int`.
    private static func cellsPerPlan(of request: SpatialRenderRequest) -> Int {
        let rows = request.placements.reduce(0) { $0 + $1.channelCount }
        return rows * request.layout.speakers.count
    }

    private static func render(
        _ request: SpatialRenderRequest,
        movingIndex: Int,
        to position: NeutralPoint
    ) throws(SpatialMotionPlanRefusal) -> SpatialRenderPlan {
        var placements = request.placements
        placements[movingIndex] = try moved(placements[movingIndex], to: position)
        let variant = SpatialRenderRequest(
            layout: request.layout,
            placements: placements,
            masks: request.masks,
            calibration: request.calibration,
            rolloff: request.rolloff,
            availableRoutes: request.availableRoutes,
            sampleRate: request.sampleRate
        )
        do {
            return try SpatialRenderer.plan(variant)
        } catch {
            throw .render(error)
        }
    }

    /// The placement rebuilt through its validating initializer with only the position replaced. A placement that was
    /// valid is rebuilt without a refusal; the mapping to the renderer's layout error is not exercised.
    private static func moved(
        _ placement: SpatialSourcePlacement,
        to position: NeutralPoint
    ) throws(SpatialMotionPlanRefusal) -> SpatialSourcePlacement {
        do {
            return try SpatialSourcePlacement(
                sourceID: placement.sourceID,
                name: placement.name,
                position: position,
                blur: placement.blur,
                width: placement.width,
                channelCount: placement.channelCount,
                evidence: placement.evidence
            )
        } catch {
            throw .render(.layout(error))
        }
    }
}
