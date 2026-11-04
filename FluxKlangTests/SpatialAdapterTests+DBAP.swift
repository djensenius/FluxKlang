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

    @Test func blurOutsideDomainIsRefusedIncludingOverflowExtremes() throws {
        let speaker = try SpatialSpeaker(id: SpeakerID("spk"), position: NeutralPoint(x: 0.25, y: -0.5))
        let layout = try SpatialLayout(speakers: [speaker])
        let range = SpatialSourcePlacement.blurRange
        for blur in [1e-200, 1e200, 0, -0.3, range.lowerBound.nextDown, range.upperBound.nextUp, .nan, .infinity] {
            #expect(throws: SpatialLayoutError.invalidBlur) {
                try NeutralDBAP.gains(source: speaker.position, layout: layout, blur: blur)
            }
            #expect(throws: SpatialLayoutError.invalidBlur) {
                try SpatialSourcePlacement(sourceID: SpatialSourceID("src"), position: speaker.position, blur: blur)
            }
        }
        let json = #"{"sourceID":"s","position":{"x":0,"y":0},"blur":1e-200,"width":0.5,"channelCount":1}"#
        #expect(Self.decodeError(SpatialSourcePlacement.self, json) == .invalidBlur)
        #expect(range.contains(SpatialSourcePlacement.defaultBlur))
        for (blur, accepted) in [(0.000_999, false), (0.001, true), (2.828_4, true), (2.828_5, false)] {
            let result = try? NeutralDBAP.gains(source: speaker.position, layout: layout, blur: blur)
            #expect((result == [1]) == accepted, "blur \(blur)")
        }
    }

    @Test func relativeWeightsStayBoundedForExtremeDistances() {
        for exponent in [0.5, 1, 4] {
            let weights = NeutralDBAP.relativeWeights(distances: [1e200, nil, 1e-200, 1e-199], exponent: exponent)
            #expect(weights[2] == 1 && weights[1] == 0)
            #expect(weights.allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(weights[3] > 0 && weights[3] < 1)
        }
        #expect(NeutralDBAP.relativeWeights(distances: [nil, nil], exponent: 1) == [0, 0])
    }

    @Test(arguments: [0.0, 6.0, 24.0])
    func singleSpeakerAtSourceIsUnityAcrossBlurDomain(rolloff: Double) throws {
        let speaker = try SpatialSpeaker(id: SpeakerID("spk"), position: NeutralPoint(x: -1, y: 1))
        let layout = try SpatialLayout(speakers: [speaker])
        let range = SpatialSourcePlacement.blurRange
        for blur in [range.lowerBound, SpatialSourcePlacement.defaultBlur, range.upperBound] {
            let atSource = try NeutralDBAP.gains(source: speaker.position, layout: layout, rolloff: rolloff, blur: blur)
            #expect(atSource == [1])
            let far = try NeutralDBAP.gains(source: NeutralPoint(x: 1, y: -1), layout: layout, rolloff: rolloff,
                                            blur: blur)
            #expect(far == [1])
        }
    }

    @Test(arguments: [0.0, 6.0, 24.0])
    func gainsStayFiniteAndAudibleAtDomainEdges(rolloff: Double) throws {
        let corners = try [(-1.0, 1.0), (1, 1), (-1, -1), (1, -1), (0, 0)].enumerated().map { index, point in
            try SpatialSpeaker(id: SpeakerID("spk.\(index)"), position: NeutralPoint(x: point.0, y: point.1),
                               participatesInPanning: index != 2)
        }
        let layout = try SpatialLayout(speakers: corners)
        let sources = try [(-1.0, 1.0), (0, 0), (0.0005, 0), (1, 0), (-0.3, 0.7)].map { try NeutralPoint(x: $0, y: $1) }
        let range = SpatialSourcePlacement.blurRange
        for blur in [range.lowerBound, range.upperBound] {
            for source in sources {
                let gains = try NeutralDBAP.gains(source: source, layout: layout, rolloff: rolloff, blur: blur)
                #expect(gains.allSatisfy { $0.isFinite && $0 >= 0 })
                #expect(gains.contains { $0 > 0 } && gains[2] == 0)
                #expect(abs(gains.reduce(0) { $0 + $1 * $1 } - 1) < 1e-12)
                if blur == range.upperBound {
                    #expect(gains.enumerated().allSatisfy { $0.offset == 2 || abs($0.element - 0.5) < 1e-12 })
                }
            }
        }
    }

    @Test func rolloffIsCheckedBeforeBlur() throws {
        let layout = try LegacySpatialImport.importLegacy(speakers: Self.quadInputs()).layout
        let origin = try NeutralPoint(x: 0, y: 0)
        for (rolloff, blur) in [(Double.nan, 0.0), (-1, 1e200), (25, .infinity)] {
            #expect(throws: SpatialLayoutError.invalidRolloff) {
                try NeutralDBAP.gains(source: origin, layout: layout, rolloff: rolloff, blur: blur)
            }
        }
    }
}
