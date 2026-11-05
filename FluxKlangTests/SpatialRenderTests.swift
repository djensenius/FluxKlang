import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct SpatialRenderTests {
    static let quadNames = ["spk.fl", "spk.fr", "spk.rl", "spk.rr"]
    static let quadPoints: [(Double, Double)] = [(-1, 1), (1, 1), (-1, -1), (1, -1)]

    static func id(_ raw: String) throws -> SpeakerID { try SpeakerID(raw) }

    static func layout(_ points: [(Double, Double)], names: [String]? = nil,
                       participates: [Bool]? = nil) throws -> SpatialLayout {
        let names = names ?? points.indices.map { "spk.\($0)" }
        let speakers = try zip(names, points).enumerated().map { index, pair in
            try SpatialSpeaker(id: SpeakerID(pair.0), position: NeutralPoint(x: pair.1.0, y: pair.1.1),
                               route: RouteID("rte." + pair.0),
                               participatesInPanning: participates?[index] ?? true)
        }
        return try SpatialLayout(speakers: speakers)
    }

    static func quad() throws -> SpatialLayout { try layout(quadPoints, names: quadNames) }

    static func source(_ raw: String, _ horizontal: Double, _ vertical: Double,
                       channels: Int = 1, width: Double = 0.5) throws -> SpatialSourcePlacement {
        try SpatialSourcePlacement(sourceID: SpatialSourceID(raw), position: NeutralPoint(x: horizontal, y: vertical),
                                   width: width, channelCount: channels)
    }

    static func source(_ horizontal: Double, _ vertical: Double,
                       channels: Int = 1, width: Double = 0.5) throws -> SpatialSourcePlacement {
        try source("src.a", horizontal, vertical, channels: channels, width: width)
    }

    static func mask(_ raw: String, _ state: SpeakerMaskState = .muted) throws -> SpatialOutputMask {
        SpatialOutputMask(speaker: try id(raw), state: state)
    }

    static func plan(_ layout: SpatialLayout, _ placements: [SpatialSourcePlacement],
                     masks: [SpatialOutputMask] = [], renormalize: Bool = false,
                     calibration: SpatialCalibrationSet = .empty,
                     routes: Set<RouteID>? = nil) throws -> SpatialRenderPlan {
        let maskSet = try SpatialMaskSet(masks: masks, renormalizeSurvivors: renormalize)
        return try SpatialRenderer.plan(SpatialRenderRequest(
            layout: layout, placements: placements, masks: maskSet, calibration: calibration,
            availableRoutes: routes))
    }

    static func power(_ row: [Double]) -> Double { row.reduce(0) { $0 + $1 * $1 } }

    @Test(arguments: [0.0, 3.0, 6.0, 12.0, 24.0])
    func unmaskedPlanEqualsNeutralLawExactly(rolloff: Double) throws {
        let layout = try Self.layout(Self.quadPoints + [(0, 0.9), (-0.6, 0.1)])
        let grid = stride(from: -1.0, through: 1.0, by: 0.25)
        for col in grid {
            for row in grid {
                let point = try NeutralPoint(x: col, y: row)
                let request = SpatialRenderRequest(layout: layout, placements: [try Self.source(col, row)],
                                                   rolloff: rolloff)
                let plan = try SpatialRenderer.plan(request)
                #expect(plan.rowCount == 1 && plan.speakerCount == 6)
                #expect(plan.row(0) == (try NeutralDBAP.gains(source: point, layout: layout, rolloff: rolloff)))
                #expect(abs(Self.power(plan.row(0)) - 1) < 1e-12)
            }
        }
    }

    @Test func stereoRowsFollowSourceAndChannelOrder() throws {
        let layout = try Self.quad()
        let stereo = try Self.source("src.b", 0.3, 0.6, channels: 2, width: 0.7)
        let mono = try Self.source("src.a", -0.2, 0.1)
        let plan = try Self.plan(layout, [stereo, mono])
        let ids = [stereo.sourceID, stereo.sourceID, mono.sourceID]
        #expect(plan.rowSources == ids)
        let expected = try NeutralDBAP.gains(placement: stereo, layout: layout)
            + NeutralDBAP.gains(placement: mono, layout: layout)
        #expect((0..<3).map { plan.row($0) } == expected)
        #expect(plan.gains.count == 12 && plan.delayFrames == [0, 0, 0, 0])
        #expect(plan.calibrationGeneration == 0)
    }

    @Test func columnsFollowLayoutOrder() throws {
        let forward = try Self.quad()
        let reversed = try Self.layout(Self.quadPoints.reversed(), names: Self.quadNames.reversed())
        let source = try Self.source(0.2, 0.4)
        let entries = try [SpeakerCalibration(speaker: Self.id("spk.fl"), trimDecibels: -3, delaySeconds: 0.001)]
        let calibration = try SpatialCalibrationSet(entries: entries)
        let one = try Self.plan(forward, [source], masks: [Self.mask("spk.rr")], calibration: calibration)
        let two = try Self.plan(reversed, [source], masks: [Self.mask("spk.rr")], calibration: calibration)
        #expect(one.row(0) == two.row(0).reversed())
        #expect(one.delayFrames == [48, 0, 0, 0] && two.delayFrames == [0, 0, 0, 48])
    }

    @Test func permutedMasksAndCalibrationGiveEqualPlans() throws {
        let layout = try Self.quad()
        let masks = try [Self.mask("spk.rr"), Self.mask("spk.fl", .soloed), Self.mask("spk.fr", .soloed),
                         Self.mask("spk.fl")]
        let entries = try [
            SpeakerCalibration(speaker: Self.id("spk.fr"), trimDecibels: -6, delaySeconds: 0.002),
            SpeakerCalibration(speaker: Self.id("spk.rl"), trimDecibels: -1)
        ]
        let one = try Self.plan(layout, [Self.source(0.2, 0.4)], masks: masks, renormalize: true,
                                calibration: SpatialCalibrationSet(generation: 3, entries: entries))
        let two = try Self.plan(layout, [Self.source(0.2, 0.4)], masks: masks.reversed(), renormalize: true,
                                calibration: SpatialCalibrationSet(generation: 3, entries: entries.reversed()))
        #expect(one == two)
        #expect(try SpatialMaskSet(masks: masks) == SpatialMaskSet(masks: masks.reversed()))
        #expect(try SpatialMaskSet(masks: masks).masks.map(\.speaker.rawValue)
                == ["spk.fl", "spk.fl", "spk.fr", "spk.rr"])
    }

    @Test func sourceBoundsAndDuplicates() throws {
        let layout = try Self.quad()
        let sixtyFour = try (0..<64).map { try Self.source("src.\($0)", 0, 0) }
        #expect(try Self.plan(layout, sixtyFour).rowCount == 64)
        let sixtyFive = sixtyFour + [try Self.source("src.64", 0, 0)]
        #expect(throws: SpatialRenderError.tooManySources(65)) { try Self.plan(layout, sixtyFive) }
        let duplicate = try SpatialSourceID("src.3")
        #expect(throws: SpatialRenderError.duplicateSource(duplicate)) {
            try Self.plan(layout, Array(sixtyFour.prefix(63)) + [Self.source("src.3", 0.5, 0.5)])
        }
        let empty = try SpatialLayout(speakers: [])
        let silentPlan = try Self.plan(empty, [Self.source(0, 0)])
        #expect(silentPlan.rowCount == 1 && silentPlan.gains.isEmpty && silentPlan.delayFrames.isEmpty)
        #expect(try Self.plan(layout, []).gains.isEmpty)
    }

    @Test func refusalsBecomeShapedSilence() throws {
        let layout = try Self.quad()
        let placements = try [Self.source("src.a", 0.2, 0.4, channels: 2), Self.source("src.b", 0, 0)]
        let calibration = try SpatialCalibrationSet(generation: 2)
        let request = SpatialRenderRequest(layout: layout, placements: placements, calibration: calibration,
                                           rolloff: 24.5)
        #expect(throws: SpatialRenderError.layout(.invalidRolloff)) { try SpatialRenderer.plan(request) }
        let (silent, error) = SpatialRenderer.planOrSilence(request)
        #expect(error == .layout(.invalidRolloff))
        #expect(silent.rowSources == [placements[0].sourceID, placements[0].sourceID, placements[1].sourceID])
        #expect(silent.gains == Array(repeating: 0, count: 12) && silent.delayFrames == [0, 0, 0, 0])
        #expect(silent.calibrationGeneration == 2)
        #expect(silent.speakerIDs == layout.speakers.map(\.id))
        let many = try (0..<65).map { try Self.source("src.\($0)", 0, 0) }
        let (none, tooMany) = SpatialRenderer.planOrSilence(SpatialRenderRequest(layout: layout, placements: many))
        #expect(tooMany == .tooManySources(65) && none.rowCount == 0 && none.gains.isEmpty)
        let good = SpatialRenderRequest(layout: layout, placements: placements)
        let (plan, noError) = SpatialRenderer.planOrSilence(good)
        #expect(noError == nil)
        #expect(plan == (try SpatialRenderer.plan(good)))
    }

    @Test func everyGainStaysFiniteAndBounded() throws {
        let layout = try Self.layout(Self.quadPoints + [(0, 0)], participates: [true, true, true, true, false])
        let entries = try [SpeakerCalibration(speaker: Self.id("spk.1"), trimDecibels: -60)]
        let calibration = try SpatialCalibrationSet(entries: entries)
        let maskOptions: [[SpatialOutputMask]] = try [
            [], [Self.mask("spk.0")], [Self.mask("spk.3", .soloed)], [Self.mask("spk.4")],
            Self.quadPoints.indices.map { try Self.mask("spk.\($0)") }
        ]
        for masks in maskOptions {
            for renormalize in [false, true] {
                for corner in Self.quadPoints {
                    let plan = try Self.plan(layout, [Self.source(corner.0, corner.1, channels: 2, width: 1)],
                                             masks: masks, renormalize: renormalize, calibration: calibration)
                    #expect(plan.gains.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                    #expect((0..<plan.rowCount).allSatisfy { Self.power(plan.row($0)) <= 1 + 1e-12 })
                    #expect((0..<plan.rowCount).allSatisfy { plan.gain(row: $0, speaker: 4) == 0 })
                }
            }
        }
    }
}
