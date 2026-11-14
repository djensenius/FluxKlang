//
//  SpatialMotionPlanStepperTests.swift
//  FluxKlangTests
//
//  The bounded motion plan stepper (#116 SPS1): one placement moves along a path and every plan equals the renderer's
//  plan of the request with that placement's position replaced. The oracle (`expected`) never calls the stepper or
//  the path; its positions are typed by hand from the two-waypoint ramp (-1, 0) at frame 0 to (1, 0) at frame 100.
//  Nothing here reads a time source, an engine or a device.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct SpatialMotionPlanStepperTests {
    private static let quadPoints: [(Double, Double)] = [(-1, 1), (1, 1), (-1, -1), (1, -1)]

    private static func layout(
        _ points: [(Double, Double)],
        participates: [Bool] = []
    ) throws -> SpatialLayout {
        var speakers: [SpatialSpeaker] = []
        for (index, point) in points.enumerated() {
            let flag = index < participates.count ? participates[index] : true
            speakers.append(try SpatialSpeaker(
                id: SpeakerID("spk.\(index)"),
                position: NeutralPoint(x: point.0, y: point.1),
                route: RouteID("rte.spk.\(index)"),
                participatesInPanning: flag
            ))
        }
        return try SpatialLayout(speakers: speakers)
    }

    private static func quad() throws -> SpatialLayout { try layout(quadPoints) }

    /// Sixty-four distinct speakers on an 8 x 8 grid; the first `inert` do not take part in panning.
    private static func grid64(inert: Int = 0) throws -> SpatialLayout {
        var points: [(Double, Double)] = []
        for column in 0..<8 {
            for row in 0..<8 { points.append((Double(column) * 0.25 - 0.875, Double(row) * 0.25 - 0.875)) }
        }
        return try layout(points, participates: (0..<64).map { $0 >= inert })
    }

    private static func mono(
        _ raw: String,
        _ horizontal: Double,
        _ vertical: Double,
        width: Double = 0.5,
        channels: Int = 1
    ) throws -> SpatialSourcePlacement {
        try SpatialSourcePlacement(
            sourceID: SpatialSourceID(raw), position: NeutralPoint(x: horizontal, y: vertical),
            width: width, channelCount: channels
        )
    }

    /// `count` mono placements `src.0`, `src.1`, ... at distinct fixed positions.
    private static func monos(_ count: Int) throws -> [SpatialSourcePlacement] {
        try (0..<count).map { try mono("src.\($0)", Double($0 % 10) * 0.1 - 0.45, Double($0 % 7) * 0.1) }
    }

    private static func ramp(_ raw: String, mode: SpatialMotionMode = .once) throws -> SpatialMotionPath {
        try SpatialMotionPath.make(source: SpatialSourceID(raw), mode: mode, waypoints: [
            SpatialMotionWaypoint(frame: 0, x: -1, y: 0), SpatialMotionWaypoint(frame: 100, x: 1, y: 0)
        ])
    }

    private static func request(
        _ layout: SpatialLayout,
        _ placements: [SpatialSourcePlacement]
    ) -> SpatialRenderRequest {
        SpatialRenderRequest(layout: layout, placements: placements)
    }

    /// The renderer's plan of `base` with the placement `raw` rebuilt at the typed point.
    private static func expected(
        _ base: SpatialRenderRequest,
        _ raw: String,
        _ horizontal: Double,
        _ vertical: Double
    ) throws -> SpatialRenderPlan {
        let target = try SpatialSourceID(raw)
        var placements: [SpatialSourcePlacement] = []
        for item in base.placements {
            if item.sourceID == target {
                placements.append(try SpatialSourcePlacement(
                    sourceID: item.sourceID, position: NeutralPoint(x: horizontal, y: vertical),
                    blur: item.blur, width: item.width, channelCount: item.channelCount
                ))
            } else {
                placements.append(item)
            }
        }
        return try SpatialRenderer.plan(SpatialRenderRequest(
            layout: base.layout, placements: placements, masks: base.masks, calibration: base.calibration,
            rolloff: base.rolloff, availableRoutes: base.availableRoutes, sampleRate: base.sampleRate
        ))
    }

    private static func run(
        _ request: SpatialRenderRequest,
        _ path: SpatialMotionPath,
        step: Int64 = 1,
        count: Int
    ) throws -> [SpatialRenderPlan] {
        try SpatialMotionPlanStepper.plans(request: request, path: path, firstFrame: 0, stepFrames: step, count: count)
    }

    private static func refusalOfPlan(
        _ request: SpatialRenderRequest,
        _ path: SpatialMotionPath,
        frame: Int64 = 0
    ) -> SpatialMotionPlanRefusal? {
        do throws(SpatialMotionPlanRefusal) {
            _ = try SpatialMotionPlanStepper.plan(request: request, path: path, frame: frame)
            return nil
        } catch {
            return error
        }
    }

    private static func refusalOfPlans(
        _ request: SpatialRenderRequest,
        _ path: SpatialMotionPath,
        first: Int64 = 0,
        step: Int64 = 25,
        count: Int
    ) -> SpatialMotionPlanRefusal? {
        do throws(SpatialMotionPlanRefusal) {
            _ = try SpatialMotionPlanStepper.plans(
                request: request, path: path, firstFrame: first, stepFrames: step, count: count
            )
            return nil
        } catch {
            return error
        }
    }

    // MARK: One step

    @Test func spatialMotionPlanStepperSingleStepEqualsRendererPlanOfMovedRequest() throws {
        let steps: [(Int64, Double)] = [(25, -0.5), (50, 0), (75, 0.5)]
        let path = try Self.ramp("src.a")
        // Blur 1.5 floors only the near speaker pair at (+-0.5, 0): distances 1.118 (near) and 1.803 (far), against
        // the default 0.30 that floors none. A blur above 1.803 would floor all four and hide the position.
        for channels in [1, 2] {
            let styled = try SpatialSourcePlacement(
                sourceID: SpatialSourceID("src.a"), position: NeutralPoint(x: 0.9, y: 0.9), blur: 1.5, width: 0.9,
                channelCount: channels
            )
            let base = Self.request(try Self.quad(), [styled])
            for (frame, horizontal) in steps {
                let plan = try SpatialMotionPlanStepper.plan(request: base, path: path, frame: frame)
                let oracle = try Self.expected(base, "src.a", horizontal, 0)
                #expect(plan == oracle)
            }
        }
    }

    @Test func spatialMotionPlanStepperCentreOfQuadGivesFourGainsOfOneHalf() throws {
        let base = Self.request(try Self.quad(), [try Self.mono("src.a", 0.9, 0.9)])
        let plan = try SpatialMotionPlanStepper.plan(request: base, path: try Self.ramp("src.a"), frame: 50)
        #expect(plan.rowCount == 1)
        #expect(plan.speakerCount == 4)
        #expect(plan.gains == [0.5, 0.5, 0.5, 0.5])
    }

    @Test func spatialMotionPlanStepperFramesOutsideThePathHoldOrWrapByMode() throws {
        let base = Self.request(try Self.quad(), [try Self.mono("src.a", 0.9, 0.9)])
        let once = try Self.ramp("src.a")
        let before = try SpatialMotionPlanStepper.plan(request: base, path: once, frame: -10)
        let after = try SpatialMotionPlanStepper.plan(request: base, path: once, frame: 150)
        #expect(before == (try Self.expected(base, "src.a", -1, 0)))
        #expect(after == (try Self.expected(base, "src.a", 1, 0)))
        let loop = try Self.ramp("src.a", mode: .loop)
        let wrapped = try SpatialMotionPlanStepper.plan(request: base, path: loop, frame: 150)
        let restart = try SpatialMotionPlanStepper.plan(request: base, path: loop, frame: 100)
        #expect(wrapped == (try Self.expected(base, "src.a", 0, 0)))
        #expect(restart == (try Self.expected(base, "src.a", -1, 0)))
    }

    // MARK: A run

    @Test func spatialMotionPlanStepperRunEqualsRendererPlanAtEachFrame() throws {
        let base = Self.request(try Self.quad(), [try Self.mono("src.a", 0.9, 0.9)])
        let plans = try SpatialMotionPlanStepper.plans(
            request: base, path: try Self.ramp("src.a"), firstFrame: 0, stepFrames: 25, count: 5
        )
        try #require(plans.count == 5)
        let horizontals: [Double] = [-1, -0.5, 0, 0.5, 1]
        for (plan, horizontal) in zip(plans, horizontals) {
            #expect(plan == (try Self.expected(base, "src.a", horizontal, 0)))
        }
        let later = try SpatialMotionPlanStepper.plans(
            request: base, path: try Self.ramp("src.a"), firstFrame: 25, stepFrames: 25, count: 3
        )
        try #require(later.count == 3)
        for (plan, horizontal) in zip(later, [-0.5, 0, 0.5]) {
            #expect(plan == (try Self.expected(base, "src.a", horizontal, 0)))
        }
    }

    @Test func spatialMotionPlanStepperOtherSourcesKeepTheirRowsAndOrder() throws {
        let fixed = try Self.mono("src.b", 0.3, 0.6)
        let alone = try SpatialRenderer.plan(Self.request(try Self.quad(), [fixed]))
        let idA = try SpatialSourceID("src.a")
        let idB = try SpatialSourceID("src.b")
        let path = try Self.ramp("src.a")
        for channels in [1, 2] {
            let moving = try Self.mono("src.a", 0, 0, channels: channels)
            let firstOrder = channels == 1 ? [idA, idB] : [idA, idA, idB]
            let secondOrder = channels == 1 ? [idB, idA] : [idB, idA, idA]
            for movingFirst in [true, false] {
                let rows = movingFirst ? firstOrder : secondOrder
                let placements = movingFirst ? [moving, fixed] : [fixed, moving]
                let fixedRow = movingFirst ? channels : 0
                let plans = try Self.run(Self.request(try Self.quad(), placements), path, step: 25, count: 5)
                try #require(plans.count == 5)
                for plan in plans {
                    try #require(plan.rowSources == rows)
                    #expect(plan.row(fixedRow) == alone.row(0))
                }
            }
        }
    }

    @Test func spatialMotionPlanStepperRunKeepsOneShapeThatAGainRampAccepts() throws {
        let pair = [try Self.mono("src.a", 0, 0, channels: 2), try Self.mono("src.b", 0, 0)]
        let base = Self.request(try Self.quad(), pair)
        let plans = try SpatialMotionPlanStepper.plans(
            request: base, path: try Self.ramp("src.a"), firstFrame: 0, stepFrames: 25, count: 5
        )
        try #require(plans.count == 5)
        let first = plans[0]
        for plan in plans {
            #expect(plan.rowSources == first.rowSources)
            #expect(plan.speakerIDs == first.speakerIDs)
            #expect(plan.delayFrames == first.delayFrames)
            #expect(plan.calibrationGeneration == first.calibrationGeneration)
        }
        for (from, next) in zip(plans, plans.dropFirst()) {
            _ = try SpatialGainRamp(from: from, to: next, frames: 0)
        }
    }

    @Test func spatialMotionPlanStepperGainsStayFiniteAndInUnitRangeAcrossThePlane() throws {
        let points = Self.quadPoints + [(0, 0.9)]
        let base = Self.request(try Self.layout(points, participates: [true, true, true, true, false]),
                                [try Self.mono("src.a", 0, 0)])
        let path = try SpatialMotionPath.make(source: SpatialSourceID("src.a"), mode: .once, waypoints: [
            SpatialMotionWaypoint(frame: 0, x: -1, y: -1), SpatialMotionWaypoint(frame: 40, x: 1, y: 1),
            SpatialMotionWaypoint(frame: 80, x: -1, y: 1)
        ])
        let plans = try SpatialMotionPlanStepper.plans(
            request: base, path: path, firstFrame: 0, stepFrames: 10, count: 9
        )
        try #require(plans.count == 9)
        for plan in plans {
            try #require(plan.speakerCount == 5)
            #expect(plan.gain(row: 0, speaker: 4) == 0)
            for gain in plan.gains {
                #expect(gain.isFinite)
                #expect(gain >= 0)
                #expect(gain <= 1)
            }
        }
    }

    // MARK: Masks, calibration and routes

    @Test func spatialMotionPlanStepperMuteAndSoloNeverRaiseASurvivorWithoutRenormalisation() throws {
        let path = try Self.ramp("src.a")
        let plain = Self.request(try Self.quad(), [try Self.mono("src.a", 0, 0)])
        let open = try SpatialMotionPlanStepper.plans(
            request: plain, path: path, firstFrame: 0, stepFrames: 25, count: 5
        )
        let muted = try SpatialMaskSet(masks: [SpatialOutputMask(speaker: SpeakerID("spk.1"), state: .muted)])
        let soloed = try SpatialMaskSet(masks: [SpatialOutputMask(speaker: SpeakerID("spk.0"), state: .soloed)])
        for masks in [muted, soloed] {
            let masked = SpatialRenderRequest(layout: plain.layout, placements: plain.placements, masks: masks)
            let plans = try SpatialMotionPlanStepper.plans(
                request: masked, path: path, firstFrame: 0, stepFrames: 25, count: 5
            )
            try #require(plans.count == open.count)
            for (plan, reference) in zip(plans, open) {
                #expect(plan.gain(row: 0, speaker: 1) == 0)
                for (gain, before) in zip(plan.gains, reference.gains) { #expect(gain <= before) }
            }
        }
    }

    @Test func spatialMotionPlanStepperCalibrationRoutesAndGenerationPassThrough() throws {
        let entry = try SpeakerCalibration(speaker: SpeakerID("spk.2"), trimDecibels: -6, delaySeconds: 0.01)
        let calibration = try SpatialCalibrationSet(generation: 3, entries: [entry])
        let routes: Set<RouteID> = [try RouteID("rte.spk.0"), try RouteID("rte.spk.1"), try RouteID("rte.spk.2")]
        let base = SpatialRenderRequest(
            layout: try Self.quad(), placements: [try Self.mono("src.a", 0, 0)], calibration: calibration,
            availableRoutes: routes
        )
        let plans = try SpatialMotionPlanStepper.plans(
            request: base, path: try Self.ramp("src.a"), firstFrame: 0, stepFrames: 50, count: 3
        )
        try #require(plans.count == 3)
        let horizontals: [Double] = [-1, 0, 1]
        for (plan, horizontal) in zip(plans, horizontals) {
            #expect(plan == (try Self.expected(base, "src.a", horizontal, 0)))
            #expect(plan.calibrationGeneration == 3)
            #expect(plan.delayFrames == [0, 0, 480, 0])
            #expect(plan.gain(row: 0, speaker: 3) == 0)
        }
    }

    // MARK: Refusals

    @Test func spatialMotionPlanStepperRefusesASourceThatIsNotPlaced() throws {
        let missing = try SpatialSourceID("src.z")
        let path = try Self.ramp("src.z")
        let placed = Self.request(try Self.quad(), [try Self.mono("src.a", 0, 0)])
        let empty = Self.request(try Self.quad(), [])
        for base in [placed, empty] {
            #expect(Self.refusalOfPlan(base, path) == .sourceNotPlaced(missing))
            #expect(Self.refusalOfPlans(base, path, count: 3) == .sourceNotPlaced(missing))
        }
    }

    @Test func spatialMotionPlanStepperFrameArithmeticAtTheInt64Limits() throws {
        let base = Self.request(try Self.quad(), [try Self.mono("src.a", 0, 0)])
        let path = try Self.ramp("src.a")
        let zeroStep = Self.refusalOfPlans(base, path, step: 0, count: 2)
        let negativeStep = Self.refusalOfPlans(base, path, step: -1, count: 0)
        let zeroStepEmpty = Self.refusalOfPlans(base, path, step: 0, count: 0)
        #expect(zeroStepEmpty == .motion(.stepNotPositive(0)))
        #expect(zeroStep == .motion(.stepNotPositive(0)))
        #expect(negativeStep == .motion(.stepNotPositive(-1)))
        #expect(Self.refusalOfPlans(base, path, first: Int64.max - 1, step: 1, count: 2) == nil)
        #expect(Self.refusalOfPlans(base, path, first: Int64.max, step: 1, count: 2) == .motion(.frameOverflow))
        let half = Int64.max / 2
        #expect(Self.refusalOfPlans(base, path, first: 0, step: half, count: 3) == nil)
        #expect(Self.refusalOfPlans(base, path, first: 0, step: half + 1, count: 3) == .motion(.frameOverflow))
        let low = try SpatialMotionPlanStepper.plans(
            request: base, path: path, firstFrame: Int64.min, stepFrames: 1, count: 2
        )
        try #require(low.count == 2)
        #expect(low[0] == (try Self.expected(base, "src.a", -1, 0)))
        let none = try SpatialMotionPlanStepper.plans(
            request: base, path: path, firstFrame: Int64.max, stepFrames: 5, count: 0
        )
        #expect(none.isEmpty)
    }

    @Test func spatialMotionPlanStepperEarlierRefusalWinsWhenTwoDefectsHoldTogether() throws {
        let good = Self.request(try Self.quad(), [try Self.mono("src.a", 0, 0)])
        let path = try Self.ramp("src.a")
        let stray = try Self.ramp("src.z")
        let badRate = SpatialRenderRequest(layout: try Self.quad(), placements: good.placements, sampleRate: 0)
        #expect(Self.refusalOfPlans(good, path, step: 0, count: 257) == .planCountOutOfRange(257))
        #expect(Self.refusalOfPlans(good, stray, step: 0, count: 3) == .motion(.stepNotPositive(0)))
        let crowd = Self.request(try Self.quad(), try Self.monos(65))
        #expect(Self.refusalOfPlans(crowd, stray, count: 3) == .render(.tooManySources(65)))
        #expect(Self.refusalOfPlan(crowd, stray) == .render(.tooManySources(65)))
        let missing = try SpatialSourceID("src.z")
        #expect(Self.refusalOfPlans(good, stray, count: 0) == .sourceNotPlaced(missing))
        #expect(Self.refusalOfPlans(badRate, path, count: 0) == nil)
        #expect(Self.refusalOfPlans(badRate, stray, count: 3) == .sourceNotPlaced(missing))
        #expect(Self.refusalOfPlan(badRate, stray) == .sourceNotPlaced(missing))
        let tight = Self.request(try Self.grid64(), try Self.monos(5))
        let source0 = try Self.ramp("src.0")
        #expect(Self.refusalOfPlans(tight, source0, first: Int64.max, step: 1, count: 205) == .tooManyCells(65_600))
        #expect(Self.refusalOfPlans(tight, source0, count: 257) == .planCountOutOfRange(257))
    }

    @Test func spatialMotionPlanStepperFrameOverflowBeatsARendererRefusal() throws {
        let badRate = SpatialRenderRequest(
            layout: try Self.quad(), placements: [try Self.mono("src.a", 0, 0)], sampleRate: 0
        )
        let path = try Self.ramp("src.a")
        #expect(Self.refusalOfPlans(badRate, path, first: Int64.max, step: 1, count: 2) == .motion(.frameOverflow))
        #expect(Self.refusalOfPlans(badRate, path, count: 2) == .render(.invalidSampleRate))
    }

    // MARK: Limits

    @Test func spatialMotionPlanStepperPlanCountLimitIs256() throws {
        let base = Self.request(try Self.quad(), [try Self.mono("src.a", 0, 0)])
        let path = try Self.ramp("src.a")
        let plans = try SpatialMotionPlanStepper.plans(
            request: base, path: path, firstFrame: 0, stepFrames: 1, count: 256
        )
        #expect(plans.count == 256)
        #expect(plans.last?.rowCount == 1)
        #expect(Self.refusalOfPlans(base, path, count: 257) == .planCountOutOfRange(257))
        #expect(Self.refusalOfPlans(base, path, count: -1) == .planCountOutOfRange(-1))
    }

    /// 65,537 is prime and the count is at most 256, so no call has exactly one cell over the budget: the first
    /// refused total in these fixtures is 65,600.
    @Test func spatialMotionPlanStepperCellBudgetOf65536IsAcceptedAndMoreIsRefused() throws {
        let grid = try Self.grid64()
        let four = Self.request(grid, try Self.monos(4))
        let path = try Self.ramp("src.0")
        let full = try Self.run(four, path, count: 256)
        #expect(full.count == 256)
        let five = Self.request(grid, try Self.monos(5))
        let under = try Self.run(five, path, count: 204)
        #expect(under.count == 204)
        #expect(Self.refusalOfPlans(five, path, step: 1, count: 205) == .tooManyCells(65_600))
        let inertFive = Self.request(try Self.grid64(inert: 4), try Self.monos(5))
        #expect(Self.refusalOfPlans(inertFive, path, step: 1, count: 205) == .tooManyCells(65_600))
        let wide = [try Self.mono("src.0", 0, 0, channels: 2)] + (try Self.monos(4)).dropFirst()
        let stereo = Self.request(grid, wide)
        let rows = try Self.run(stereo, path, count: 204)
        #expect(rows.count == 204)
        #expect(Self.refusalOfPlans(stereo, path, step: 1, count: 205) == .tooManyCells(65_600))
    }

    @Test func spatialMotionPlanStepperSourceLimitIs64() throws {
        let sixtyFour = Self.request(try Self.quad(), try Self.monos(64))
        let path = try Self.ramp("src.0")
        let one = try Self.run(sixtyFour, path, count: 1)
        #expect(one.first?.rowCount == 64)
        let sixtyFive = Self.request(try Self.quad(), try Self.monos(65))
        #expect(Self.refusalOfPlans(sixtyFive, path, count: 1) == .render(.tooManySources(65)))
        #expect(Self.refusalOfPlan(sixtyFive, path) == .render(.tooManySources(65)))
    }

    @Test func spatialMotionPlanStepperCarriesRendererRefusalsFromBothEntryPoints() throws {
        let layout = try Self.quad()
        let placement = try Self.mono("src.a", 0, 0)
        let path = try Self.ramp("src.a")
        let unknown = try SpeakerID("spk.9")
        let strayMask = try SpatialMaskSet(masks: [SpatialOutputMask(speaker: unknown, state: .muted)])
        let cases: [(SpatialRenderRequest, SpatialRenderError)] = [
            (SpatialRenderRequest(layout: layout, placements: [placement], sampleRate: 0), .invalidSampleRate),
            (SpatialRenderRequest(layout: layout, placements: [placement, placement]),
             .duplicateSource(placement.sourceID)),
            (SpatialRenderRequest(layout: layout, placements: [placement], rolloff: 25), .layout(.invalidRolloff)),
            (SpatialRenderRequest(layout: layout, placements: [placement], masks: strayMask),
             .unknownMaskSpeaker(unknown))
        ]
        for (base, error) in cases {
            #expect(Self.refusalOfPlan(base, path, frame: 50) == .render(error))
            #expect(Self.refusalOfPlans(base, path, count: 3) == .render(error))
        }
    }

    @Test func spatialMotionPlanStepperGivesEqualPlansForEqualInputs() throws {
        let original = try Self.mono("src.a", 0.4, -0.3)
        let base = Self.request(try Self.quad(), [original])
        let path = try Self.ramp("src.a")
        let one = try SpatialMotionPlanStepper.plans(request: base, path: path, firstFrame: 0, stepFrames: 20, count: 6)
        let two = try SpatialMotionPlanStepper.plans(request: base, path: path, firstFrame: 0, stepFrames: 20, count: 6)
        #expect(one == two)
    }
}
