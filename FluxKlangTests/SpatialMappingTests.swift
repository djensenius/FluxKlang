//
//  SpatialMappingTests.swift
//  FluxKlangTests
//
//  The legacy-golden preservation bridge (#113 S1): legacy goldens still match
//  `SpatialPanner`, and the neutral render plan reached through
//  `LegacySpatialRenderBridge` reproduces them within a derived tolerance.
//

import CoreGraphics
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct SpatialMappingTests {
    static let layouts = [quad, stereo, single, triangle, ring]
    /// The legacy placement grid of every golden layout: 0, 0.25, 0.5, 0.75, 1.
    static let gridSteps = Array(stride(from: 0.0, through: 1.0, by: 0.25))

    /// Bound on `|neutral − legacy|` for a gain in `0…1`, derived from IEEE-754
    /// double rounding (ε = 2⁻⁵²), not tuned to observed errors:
    /// - each coordinate carries ≤ 2ε (one rounding in x′ = 2x − 1 or 1 − 2y,
    ///   plus the stereo offset `x ± w·k` on either side); a speaker–source
    ///   difference therefore carries ≤ 6ε (two coordinates, plus one rounding in
    ///   the legacy and one in the neutral subtraction, at magnitude ≤ 2);
    /// - every distance is floored at the blur (0.30 neutral), and `max` is
    ///   1-Lipschitz, so the relative distance error is ≤ 6ε/0.30 + 2ε (one
    ///   `hypot` per side) = 22ε;
    /// - a weight `(dmin/d)^a` against legacy `d^−a` compounds two distances and
    ///   `pow`/division: ≤ a·44ε + 3ε relative;
    /// - power normalisation over `n` speakers adds ≤ (n + 3)ε and the
    ///   normalised gain carries the weight error twice (own weight and norm).
    /// Total: (88a + n + 9)ε, i.e. 102ε ≈ 2.3e-14 at the default a = 1, n = 5.
    static func tolerance(speakers: Int, exponent: Double = 1) -> Double {
        (88 * exponent + Double(speakers) + 9) * Double.ulpOfOne
    }

    static func uuid(_ index: Int, prefix: String) throws -> UUID {
        try #require(UUID(uuidString: prefix + "-0000-0000-0000-" + String(format: "%012d", index)))
    }

    static func speakerInputs(_ layout: SpatialMappingGoldenLayout) throws -> [LegacySpeakerInput] {
        try layout.speakers.enumerated().map { index, point in
            LegacySpeakerInput(id: try uuid(index, prefix: "51130000"), x: point.0, y: point.1)
        }
    }

    static func sourceInputs(_ cases: [SpatialMappingGoldenCase]) throws -> [LegacySourceInput] {
        try cases.enumerated().map { index, golden in
            LegacySourceInput(id: try uuid(index, prefix: "51130001"), x: golden.legacyX, y: golden.legacyY,
                              width: golden.width ?? 0.5, isStereo: golden.width != nil)
        }
    }

    static func bridge(_ layout: SpatialMappingGoldenLayout, masks: [LegacySpeakerMask] = []) throws
        -> LegacySpatialRenderBridge {
        try LegacySpatialRenderBridge.make(speakers: speakerInputs(layout), sources: sourceInputs(layout.all),
                                           masks: masks)
    }

    /// Legacy gains for a golden case via the real legacy model and panner.
    static func legacyGains(_ golden: SpatialMappingGoldenCase, speakers: [CGPoint]) -> [[Double]] {
        let source = SpatialSource(
            name: "golden", mode: golden.width == nil ? .mono : .stereo, left: .channel(1), right: .channel(2),
            position: CGPoint(x: golden.legacyX, y: golden.legacyY), width: golden.width ?? 0.5
        )
        return source.channelPlacements().map { SpatialPanner.gains(source: $0.point, speakers: speakers) }
    }

    static func maxError(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
    }

    @Test func goldenGridCoversEveryPlacementInOrder() {
        #expect(Self.gridSteps == [0, 0.25, 0.5, 0.75, 1])
        let expected = Self.gridSteps.flatMap { row in Self.gridSteps.map { [$0, row] } }
        #expect(Self.layouts.map(\.name) == ["quad", "stereo", "single", "triangle", "ring"])
        for layout in Self.layouts {
            #expect(layout.grid.map { [$0.legacyX, $0.legacyY] } == expected)
            #expect(layout.grid.allSatisfy { $0.width == nil })
            #expect(layout.edges.count >= 2)
            for golden in layout.all {
                #expect(golden.gains.count == (golden.width == nil ? 1 : 2))
                #expect(golden.gains.allSatisfy { $0.count == layout.speakers.count })
            }
        }
        #expect(Self.layouts.map(\.stereo.count) == [7, 7, 0, 0, 0])
    }

    @Test(arguments: 0..<5)
    func legacyPannerStillReproducesGoldensExactly(layoutIndex: Int) {
        let layout = Self.layouts[layoutIndex]
        let speakers = layout.speakers.map { CGPoint(x: $0.0, y: $0.1) }
        for golden in layout.all {
            #expect(Self.legacyGains(golden, speakers: speakers) == golden.gains,
                    "\(layout.name) (\(golden.legacyX), \(golden.legacyY)) width \(String(describing: golden.width))")
        }
    }

    @Test(arguments: 0..<5)
    func neutralPlanMatchesLegacyGoldensWithinDerivedTolerance(layoutIndex: Int) throws {
        let layout = Self.layouts[layoutIndex]
        let bridge = try Self.bridge(layout)
        let plan = try bridge.plan()
        let speakers = try Self.speakerInputs(layout)
        #expect(plan.speakerIDs == speakers.map { SpeakerID(uuid: $0.id) })
        let tolerance = Self.tolerance(speakers: layout.speakers.count)
        for (golden, input) in zip(layout.all, try Self.sourceInputs(layout.all)) {
            let rows = try #require(bridge.rows(forLegacySource: input.id))
            #expect(rows.count == golden.gains.count)
            for (row, legacy) in zip(rows, golden.gains) {
                let error = Self.maxError(plan.row(row), legacy)
                #expect(error <= tolerance, "\(layout.name) (\(golden.legacyX), \(golden.legacyY)) error \(error)")
            }
        }
    }

    @Test func legacyModelMappingFollowsLegacyBusRouting() throws {
        var array = SpeakerArray.standardQuad
        array.speakers.insert(Speaker(name: "Main", node: .main(1), position: CGPoint(x: 0.5, y: 0)), at: 2)
        let stereo = SpatialSource(name: "Keys", mode: .stereo, left: .channel(3), right: .channel(9),
                                   position: CGPoint(x: 0.3, y: 0.6), width: 0.7)
        let mono = SpatialSource(name: "Voice", left: .channel(1), position: CGPoint(x: 0.8, y: 0.2))
        let bridge = try LegacySpatialRenderBridge.make(array: array, sources: [stereo, mono])
        let plan = try bridge.plan()
        let layout = bridge.request.layout
        #expect(layout.speakers.map(\.participatesInPanning) == [true, true, false, true, true])
        #expect(layout.speakers.map(\.evidence) == ["bus-1", "bus-2", "main-1", "bus-3", "bus-4"])
        #expect(layout.groups.map(\.speakers) == array.pairs.map {
            [SpeakerID(uuid: $0.left), SpeakerID(uuid: $0.right)]
        })
        #expect(bridge.request.placements.map(\.evidence) == [["ch-3", "ch-9"], ["ch-1"]])
        // Legacy `SpatialRouting.settings` pans over bus speakers only.
        let busPoints = array.speakers.filter { $0.node.kind == .bus }.map(\.position)
        let legacy = [stereo, mono].flatMap { source in
            source.channelPlacements().map { SpatialPanner.gains(source: $0.point, speakers: busPoints) }
        }
        #expect(plan.rowCount == legacy.count)
        for (index, gains) in legacy.enumerated() {
            let row = plan.row(index)
            #expect(row[2] == 0)
            #expect(Self.maxError([row[0], row[1], row[3], row[4]], gains) <= Self.tolerance(speakers: 4))
        }
    }

    @Test func idMigrationIsStableIdempotentAndCanonical() throws {
        let legacy = try Self.uuid(42, prefix: "ABCDEF01")
        let canonical: SpeakerID = try LegacySpatialIDMigration.migrate(legacy.uuidString)
        #expect(canonical == LegacySpatialIDMigration.speakerID(legacy))
        #expect(canonical.rawValue == "ABCDEF01-0000-0000-0000-000000000042")
        #expect(try LegacySpatialIDMigration.migrate(legacy.uuidString.lowercased(), as: SpeakerTag.self) == canonical)
        #expect(try LegacySpatialIDMigration.migrate(canonical.rawValue, as: SpeakerTag.self) == canonical)
        #expect(LegacySpatialIDMigration.sourceID(legacy).rawValue == canonical.rawValue)
        #expect(LegacySpatialIDMigration.groupID(legacy).rawValue == canonical.rawValue)
        let neutral: SpeakerID = try LegacySpatialIDMigration.migrate("spk.front-left")
        #expect(neutral.rawValue == "spk.front-left")
        #expect(try LegacySpatialIDMigration.migrate(neutral.rawValue, as: SpeakerTag.self) == neutral)
        #expect(throws: LegacySpatialMappingError.invalidLegacyID(.invalidLength(0))) {
            try LegacySpatialIDMigration.migrate("", as: SpeakerTag.self)
        }
        #expect(throws: LegacySpatialMappingError.invalidLegacyID(.invalidCharacter(" "))) {
            try LegacySpatialIDMigration.migrate("front left", as: SpeakerTag.self)
        }
        // The same legacy values map to the same plan regardless of how often they are mapped.
        #expect(try Self.bridge(Self.ring) == Self.bridge(Self.ring))
    }

    @Test func bridgeMapsColumnsAndRowsByLegacyIdentity() throws {
        let bridge = try Self.bridge(Self.quad)
        let speakers = try Self.speakerInputs(Self.quad)
        let sources = try Self.sourceInputs(Self.quad.all)
        #expect(bridge.speakerColumns == speakers.map(\.id))
        for (index, speaker) in speakers.enumerated() {
            #expect(bridge.column(forLegacySpeaker: speaker.id) == index)
        }
        let mono = sources.count - Self.quad.stereo.count
        #expect(bridge.rows.count == mono + 2 * Self.quad.stereo.count)
        #expect(bridge.rows(forLegacySource: sources[0].id) == 0..<1)
        #expect(bridge.rows(forLegacySource: sources[mono].id) == mono..<(mono + 2))
        #expect(bridge.rows(forLegacySource: sources[mono + 1].id) == (mono + 2)..<(mono + 4))
        #expect(bridge.rows[mono + 1] == LegacySpatialRow(source: sources[mono].id, channel: 1))
        let plan = try bridge.plan()
        #expect(plan.rowSources == bridge.rows.map { SpatialSourceID(uuid: $0.source) })
        let unknown = try Self.uuid(99, prefix: "51130009")
        #expect(bridge.column(forLegacySpeaker: unknown) == nil)
        #expect(bridge.rows(forLegacySource: unknown) == nil)
    }

    @Test func bridgeRequestKeepsTheLegacyLawAndRefusesBadInput() throws {
        let request = try Self.bridge(Self.ring).request
        #expect(request.masks == .none)
        #expect(request.calibration == .empty)
        #expect(request.rolloff == NeutralDBAP.defaultRolloff)
        #expect(request.availableRoutes == nil)
        #expect(request.layout.speakers.allSatisfy { $0.route == nil })
        let speakers = try Self.speakerInputs(Self.quad)
        let stranger = try Self.uuid(7, prefix: "51130009")
        #expect(throws: LegacySpatialMappingError.unknownMaskSpeaker(stranger)) {
            try LegacySpatialRenderBridge.make(speakers: speakers, masks: [LegacySpeakerMask(speaker: stranger)])
        }
        let twice = [LegacySpeakerMask(speaker: speakers[0].id), LegacySpeakerMask(speaker: speakers[0].id)]
        #expect(throws: LegacySpatialMappingError.render(.duplicateMask(SpeakerID(uuid: speakers[0].id)))) {
            try LegacySpatialRenderBridge.make(speakers: speakers, masks: twice)
        }
        #expect(throws: LegacySpatialMappingError.importRefused(
            .collection(.duplicateSpeaker(SpeakerID(uuid: speakers[0].id))))) {
            try LegacySpatialRenderBridge.make(speakers: speakers + [speakers[0]])
        }
        let broken = LegacySourceInput(id: stranger, x: .nan, y: 0.5)
        #expect(throws: LegacySpatialMappingError.importRefused(.source(index: 0, .nonFiniteCoordinate))) {
            try LegacySpatialRenderBridge.make(speakers: speakers, sources: [broken])
        }
    }

    /// The tolerance must still detect a real law change: a rolloff off by one
    /// part in a million, or a blur off by one part in a million, exceeds it.
    @Test func derivedToleranceDetectsTinyLawChanges() throws {
        let tolerance = Self.tolerance(speakers: 4)
        #expect(tolerance < 1e-13)
        let layout = try LegacySpatialImport.importLegacy(speakers: Self.speakerInputs(Self.quad)).layout
        var rolloffChange = 0.0
        var blurChange = 0.0
        for golden in Self.quad.grid + Self.quad.edges {
            let point = try LegacySpatialImport.point(x: golden.legacyX, y: golden.legacyY)
            let steeper = try NeutralDBAP.gains(source: point, layout: layout, rolloff: 6 * (1 + 1e-6))
            let wider = try NeutralDBAP.gains(source: point, layout: layout,
                                              blur: SpatialSourcePlacement.defaultBlur * (1 + 1e-6))
            rolloffChange = max(rolloffChange, Self.maxError(steeper, golden.gains[0]))
            blurChange = max(blurChange, Self.maxError(wider, golden.gains[0]))
        }
        #expect(rolloffChange > 1_000 * tolerance)
        #expect(blurChange > 1_000 * tolerance)
    }

    /// Ruling 1 (#113 S1): the neutral import clamps an out-of-range legacy
    /// position or width into `0…1`; legacy pans the raw values and stays the
    /// default rendering path. This is an intentional divergence that the golden
    /// comparison never covers, because every golden stays inside `0…1`.
    @Test func outOfRangeLegacyValuesImportClampedOutsideTheGoldenDomain() throws {
        for golden in Self.layouts.flatMap(\.all) {
            #expect(LegacySpatialImport.legacyRange.contains(golden.legacyX))
            #expect(LegacySpatialImport.legacyRange.contains(golden.legacyY))
            #expect(golden.width.map(LegacySpatialImport.legacyRange.contains) ?? true)
        }
        let points = Self.quad.speakers.map { CGPoint(x: $0.0, y: $0.1) }
        let speakers = try Self.speakerInputs(Self.quad)
        let outside = LegacySourceInput(id: try Self.uuid(0, prefix: "51130002"), x: 1.25, y: -0.25)
        let wide = LegacySourceInput(id: try Self.uuid(1, prefix: "51130002"), x: 0.5, y: 0.5, width: 1.5,
                                     isStereo: true)
        let bridge = try LegacySpatialRenderBridge.make(speakers: speakers, sources: [outside, wide])
        #expect(bridge.request.placements[0].position == (try LegacySpatialImport.point(x: 1, y: 0)))
        #expect(bridge.request.placements[1].width == 1)
        let plan = try bridge.plan()
        // The position imports as (1, 0); legacy pans (1.25, −0.25) unclamped.
        let unclamped = SpatialPanner.gains(source: CGPoint(x: 1.25, y: -0.25), speakers: points)
        let clamped = SpatialPanner.gains(source: CGPoint(x: 1, y: 0), speakers: points)
        #expect(Self.maxError(plan.row(0), unclamped) > 1e-3)
        #expect(Self.maxError(plan.row(0), clamped) <= Self.tolerance(speakers: 4))
        // The width imports as 1; legacy spreads by 1.5 × 0.25.
        let legacyWide = [0.5 - 0.375, 0.5 + 0.375].map {
            SpatialPanner.gains(source: CGPoint(x: $0, y: 0.5), speakers: points)
        }
        let legacyUnit = [0.25, 0.75].map { SpatialPanner.gains(source: CGPoint(x: $0, y: 0.5), speakers: points) }
        #expect(Self.maxError(plan.row(1), legacyWide[0]) > 1e-3)
        #expect(Self.maxError(plan.row(1), legacyUnit[0]) <= Self.tolerance(speakers: 4))
        #expect(Self.maxError(plan.row(2), legacyUnit[1]) <= Self.tolerance(speakers: 4))
    }

    /// Rulings (#113 S1 round 1): a NaN or ±∞ speaker or source position refuses
    /// the whole bridge with the exact typed error, never a zeroed column or a
    /// silently dropped source. Legacy instead zeroes only that speaker's column
    /// (±∞), silences every speaker (a NaN speaker poisons the norm) or zeroes that
    /// source. A valid layout still matches the goldens. Legacy speakers
    /// are 2-D, so x and y are the only coordinates.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFinitePositionsRefuseTheWholeBridge(bad: Double) throws {
        let points = Self.quad.speakers.map { CGPoint(x: $0.0, y: $0.1) }
        let speakers = try Self.speakerInputs(Self.quad)
        let sources = try Self.sourceInputs(Self.quad.grid)
        for (legacyX, legacyY) in [(bad, 0.5), (0.5, bad)] {
            #expect(SpatialPanner.gains(source: CGPoint(x: legacyX, y: legacyY), speakers: points) == [0, 0, 0, 0])
            var badSources = sources
            badSources[3] = LegacySourceInput(id: sources[3].id, x: legacyX, y: legacyY)
            #expect(throws: LegacySpatialMappingError.importRefused(.source(index: 3, .nonFiniteCoordinate))) {
                try LegacySpatialRenderBridge.make(speakers: speakers, sources: badSources)
            }
            var badPoints = points
            badPoints[2] = CGPoint(x: legacyX, y: legacyY)
            let legacy = SpatialPanner.gains(source: CGPoint(x: 0.5, y: 0.5), speakers: badPoints)
            if bad.isNaN {
                #expect(legacy == [0, 0, 0, 0])
            } else {
                #expect(legacy[2] == 0 && [0, 1, 3].allSatisfy { legacy[$0] > 0 })
            }
            var badSpeakers = speakers
            badSpeakers[2] = LegacySpeakerInput(id: speakers[2].id, x: legacyX, y: legacyY)
            #expect(throws: LegacySpatialMappingError.importRefused(.speaker(index: 2, .nonFiniteCoordinate))) {
                try LegacySpatialRenderBridge.make(speakers: badSpeakers, sources: sources)
            }
            var array = SpeakerArray.standardQuad
            array.speakers[1].position = CGPoint(x: legacyX, y: legacyY)
            #expect(throws: LegacySpatialMappingError.importRefused(.speaker(index: 1, .nonFiniteCoordinate))) {
                try LegacySpatialRenderBridge.make(array: array, sources: [])
            }
        }
        let plan = try LegacySpatialRenderBridge.make(speakers: speakers, sources: sources).plan()
        #expect(plan.rowCount == Self.quad.grid.count)
        for (index, golden) in Self.quad.grid.enumerated() {
            #expect(Self.maxError(plan.row(index), golden.gains[0]) <= Self.tolerance(speakers: 4))
        }
    }

    /// Legacy `SpatialRouting.settings` sends only to bus speakers, so exactly
    /// the `.bus` kind drives panning; every other kind is carried but gets 0.
    @Test(arguments: WingNodeKind.allCases)
    func onlyBusSpeakersDrivePanningForEveryNodeKind(kind: WingNodeKind) throws {
        let expected: [WingNodeKind: Bool] = [
            .channel: false, .aux: false, .bus: true, .main: false, .matrix: false, .dca: false
        ]
        #expect(Set(expected.keys) == Set(WingNodeKind.allCases))
        let speaker = Speaker(name: "Probe", node: WingNodeRef(kind: kind, index: 1), position: CGPoint(x: 0.5, y: 0.5))
        #expect(LegacySpeakerInput(legacy: speaker).drivesPanning == expected[kind])
        var array = SpeakerArray.standardQuad
        array.speakers.append(speaker)
        let source = SpatialSource(name: "Voice", left: .channel(1), position: CGPoint(x: 0.5, y: 0.5))
        let plan = try LegacySpatialRenderBridge.make(array: array, sources: [source]).plan()
        #expect(plan.speakerIDs.count == 5)
        #expect((plan.row(0)[4] > 0) == expected[kind])
    }

    /// A `.stereo` source with no right channel falls back to mono, exactly as
    /// legacy `isStereo`/`channelPlacements()` do: one row, the mono gains.
    @Test func stereoSourceWithoutRightChannelFallsBackToMono() throws {
        let array = SpeakerArray.standardQuad
        let orphan = SpatialSource(name: "Half", mode: .stereo, left: .channel(5),
                                   position: CGPoint(x: 0.3, y: 0.6), width: 0.7)
        let mono = SpatialSource(name: "Mono", left: .channel(5), position: CGPoint(x: 0.3, y: 0.6))
        #expect(!orphan.isStereo && orphan.channelPlacements().count == 1)
        let bridge = try LegacySpatialRenderBridge.make(array: array, sources: [orphan])
        #expect(bridge.request.placements.map(\.channelCount) == [1])
        #expect(bridge.request.placements.map(\.evidence) == [["ch-5"]])
        #expect(bridge.rows == [LegacySpatialRow(source: orphan.id, channel: 0)])
        let monoPlan = try LegacySpatialRenderBridge.make(array: array, sources: [mono]).plan()
        #expect(try bridge.plan().row(0) == monoPlan.row(0))
    }

    /// Muting one speaker twice through the model path is a typed refusal, not a merge.
    @Test func duplicateModelMutesAreRefusedNotMerged() throws {
        let array = SpeakerArray.standardQuad
        let twice = array.speakers[1].id
        #expect(throws: LegacySpatialMappingError.render(.duplicateMask(SpeakerID(uuid: twice)))) {
            try LegacySpatialRenderBridge.make(array: array, sources: [], muted: [twice, array.speakers[0].id, twice])
        }
        let once = try LegacySpatialRenderBridge.make(array: array, sources: [], muted: [twice])
        #expect(once.request.masks.masks == [SpatialOutputMask(speaker: SpeakerID(uuid: twice), state: .muted)])
    }

    /// Bridge limits at N and N + 1: 64 speakers, 64 pairs, 64 sources and 128
    /// masks build and plan; one more of any is refused with the exact error.
    @Test func bridgeLimitsAcceptTheMaximumAndRefuseOneMore() throws {
        let speakers = try (0..<65).map {
            LegacySpeakerInput(id: try Self.uuid($0, prefix: "51130004"), x: Double($0 % 8) / 7, y: Double($0 / 8) / 8)
        }
        let sources = try (0..<65).map {
            LegacySourceInput(id: try Self.uuid($0, prefix: "51130005"), x: 0.5, y: Double($0) / 64)
        }
        let maxSpeakers = Array(speakers.prefix(64))
        let pairs = try (0..<65).map {
            LegacySpeakerPairInput(id: try Self.uuid($0, prefix: "51130006"), left: maxSpeakers[$0 % 64].id,
                                   right: maxSpeakers[($0 + 1) % 64].id)
        }
        let masks = maxSpeakers.flatMap {
            [LegacySpeakerMask(speaker: $0.id, state: .muted), LegacySpeakerMask(speaker: $0.id, state: .soloed)]
        }
        #expect(masks.count == 128)
        let full = try LegacySpatialRenderBridge.make(
            speakers: maxSpeakers, pairs: Array(pairs.prefix(64)), sources: Array(sources.prefix(64)), masks: masks
        )
        let plan = try full.plan()
        #expect(plan.rowCount == 64 && plan.speakerIDs.count == 64 && full.request.layout.groups.count == 64)
        #expect(full.request.masks.masks.count == 128)
        #expect(throws: LegacySpatialMappingError.importRefused(.collection(.tooManySpeakers(65)))) {
            try LegacySpatialRenderBridge.make(speakers: speakers)
        }
        #expect(throws: LegacySpatialMappingError.importRefused(.collection(.tooManyGroups(65)))) {
            try LegacySpatialRenderBridge.make(speakers: maxSpeakers, pairs: pairs)
        }
        #expect(throws: LegacySpatialMappingError.importRefused(.collection(.tooManySources(65)))) {
            try LegacySpatialRenderBridge.make(speakers: maxSpeakers, sources: sources)
        }
        #expect(throws: LegacySpatialMappingError.render(.tooManyMasks(129))) {
            try LegacySpatialRenderBridge.make(speakers: maxSpeakers, masks: masks + [masks[0]])
        }
        // The count is checked before the unknown-speaker scan, so an oversized list is refused as such.
        let stranger = LegacySpeakerMask(speaker: speakers[64].id)
        #expect(throws: LegacySpatialMappingError.render(.tooManyMasks(129))) {
            try LegacySpatialRenderBridge.make(speakers: maxSpeakers, masks: masks + [stranger])
        }
    }

    /// Remaining documented divergence, pinned so a change is noticed. Legacy
    /// stays the default path; the neutral bridge never changes `SpatialPanner`.
    @Test func emptyLayoutDivergenceIsPinned() throws {
        let source = LegacySourceInput(id: try Self.uuid(0, prefix: "51130002"), x: 0.5, y: 0.5)
        // No speakers: legacy gives no gains; the plan keeps the row with no columns.
        let empty = try LegacySpatialRenderBridge.make(speakers: [], sources: [source]).plan()
        #expect(SpatialPanner.gains(source: .zero, speakers: []).isEmpty)
        #expect(empty.rowCount == 1 && empty.gains.isEmpty)
    }
}
