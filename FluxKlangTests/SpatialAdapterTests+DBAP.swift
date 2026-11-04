import CoreGraphics
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialAdapterTests {
    @Test(arguments: [0.0, 3.0, 6.0, 12.0])
    func neutralDBAPMatchesLegacyGolden(rolloff: Double) throws {
        let legacySpeakers: [(Double, Double)] = Self.legacyQuad + [(0.5, 0.05), (0.2, 0.55)]
        let ids = try (0..<legacySpeakers.count).map { try Self.uuid($0, prefix: "10000000") }
        let inputs = zip(ids, legacySpeakers).map { LegacySpeakerInput(id: $0, x: $1.0, y: $1.1) }
        let layout = try LegacySpatialImport.importLegacy(speakers: inputs).layout
        let points = legacySpeakers.map { CGPoint(x: $0.0, y: $0.1) }
        let grid = stride(from: 0.0, through: 1.0, by: 0.125)
        for col in grid {
            for row in grid {
                let legacy = SpatialPanner.gains(source: CGPoint(x: col, y: row), speakers: points, rolloff: rolloff)
                let neutral = try NeutralDBAP.gains(source: LegacySpatialImport.point(x: col, y: row),
                                                    layout: layout, rolloff: rolloff)
                #expect(legacy.count == neutral.count)
                #expect(zip(legacy, neutral).allSatisfy { abs($0 - $1) < 1e-9 })
            }
        }
    }

    /// Legacy `SpatialRouting.settings` pans over bus speakers only; emulate that
    /// filter on plain flags and compare against the neutral participation mask.
    @Test(arguments: [
        [true, false, true, true, false], [false, true, false, true, true], [true, true, false, false, false]
    ])
    func neutralDBAPMatchesLegacyRoutingForMixedLayouts(isBus: [Bool]) throws {
        let legacySpeakers: [(Double, Double)] = Self.legacyQuad + [(0.5, 0.05)]
        let ids = try (0..<legacySpeakers.count).map { try Self.uuid($0, prefix: "30000000") }
        let inputs = zip(zip(ids, legacySpeakers), isBus).map { pair, bus in
            LegacySpeakerInput(id: pair.0, x: pair.1.0, y: pair.1.1, drivesPanning: bus)
        }
        let layout = try LegacySpatialImport.importLegacy(speakers: inputs).layout
        let busPoints = zip(legacySpeakers, isBus).filter(\.1).map { CGPoint(x: $0.0.0, y: $0.0.1) }
        let source = LegacySourceInput(id: try Self.uuid(1), x: 0.3, y: 0.6, width: 0.7, isStereo: true)
        let placement = try LegacySpatialImport.source(source)
        let legacyPoints = [0.3 - 0.7 * 0.25, 0.3 + 0.7 * 0.25].map { CGPoint(x: $0, y: 0.6) }
        let perChannel = try NeutralDBAP.gains(placement: placement, layout: layout)
        #expect(perChannel.count == 2)
        for (neutral, point) in zip(perChannel, legacyPoints) {
            #expect(neutral.count == legacySpeakers.count)
            let legacy = SpatialPanner.gains(source: point, speakers: busPoints)
            let participating = zip(neutral, isBus).filter(\.1).map(\.0)
            #expect(zip(legacy, participating).allSatisfy { abs($0 - $1) < 1e-9 })
            #expect(zip(neutral, isBus).allSatisfy { $1 || $0 == 0 })
        }
    }

    @Test func neutralDBAPRefusesInvalidParametersAndStaysSilentWithoutParticipants() throws {
        let layout = try LegacySpatialImport.importLegacy(speakers: Self.quadInputs()).layout
        let origin = try NeutralPoint(x: 0, y: 0)
        for rolloff in [-0.5, 24.5, .nan, .infinity] {
            #expect(throws: SpatialLayoutError.invalidRolloff) {
                try NeutralDBAP.gains(source: origin, layout: layout, rolloff: rolloff)
            }
        }
        #expect(try NeutralDBAP.gains(source: origin, layout: layout, rolloff: 24).count == 4)
        #expect(throws: SpatialLayoutError.invalidBlur) {
            try NeutralDBAP.gains(source: origin, layout: layout, blur: 0)
        }
        #expect(try NeutralDBAP.gains(source: origin, layout: SpatialLayout(speakers: [])).isEmpty)
        let silent = try Self.quadInputs().map {
            LegacySpeakerInput(id: $0.id, x: $0.legacyX, y: $0.legacyY, drivesPanning: false)
        }
        let silentLayout = try LegacySpatialImport.importLegacy(speakers: silent).layout
        #expect(try NeutralDBAP.gains(source: origin, layout: silentLayout) == [0, 0, 0, 0])
    }
}
