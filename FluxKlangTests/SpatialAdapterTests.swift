import CoreGraphics
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct SpatialAdapterTests {
    static let legacyQuad: [(Double, Double)] = [(0, 0), (1, 0), (0, 1), (1, 1)]

    static func uuid(_ index: Int, prefix: String = "00000000") throws -> UUID {
        try #require(UUID(uuidString: prefix + "-0000-0000-0000-" + String(format: "%012d", index)))
    }

    static func quadIDs() throws -> [UUID] {
        try (0..<4).map { try uuid($0) }
    }

    static func quadInputs() throws -> [LegacySpeakerInput] {
        try zip(quadIDs(), legacyQuad).enumerated().map { index, pair in
            LegacySpeakerInput(id: pair.0, x: pair.1.0, y: pair.1.1, evidence: "bus:\(index + 1)")
        }
    }

    static func speaker(_ raw: String, _ horizontal: Double = 0, _ vertical: Double = 0,
                        route: String? = nil) throws -> SpatialSpeaker {
        try SpatialSpeaker(id: SpeakerID(raw), position: NeutralPoint(x: horizontal, y: vertical),
                           route: route.map { try RouteID($0) })
    }

    @Test func quadCornersMapToNeutralCorners() throws {
        let layout = try LegacySpatialImport.importLegacy(speakers: Self.quadInputs()).layout
        let points = layout.speakers.map { [$0.position.x, $0.position.y] }
        #expect(points == [[-1, 1], [1, 1], [-1, -1], [1, -1]])
        #expect(layout.speakers.map(\.id) == (try Self.quadIDs()).map { SpeakerID(uuid: $0) })
    }

    @Test func centerMapsToOriginAndInteriorFollowsFormula() throws {
        #expect(try LegacySpatialImport.point(x: 0.5, y: 0.5) == NeutralPoint(x: 0, y: 0))
        let point = try LegacySpatialImport.point(x: 0.25, y: 0.1)
        #expect(point.x == -0.5)
        #expect(abs(point.y - 0.8) < 1e-12)
    }

    @Test func lenientPathClampsAndStrictPathRefuses() throws {
        #expect(try LegacySpatialImport.point(x: 1.7, y: -0.4) == NeutralPoint(x: 1, y: 1))
        let direct = try NeutralPoint(x: -3, y: 2.5)
        #expect(direct.x == -1 && direct.y == 1)
        #expect(throws: SpatialLayoutError.coordinateOutOfRange) { try NeutralPoint(validatingX: -1.01, y: 0) }
        #expect(throws: SpatialLayoutError.coordinateOutOfRange) { try NeutralPoint(validatingX: 0, y: 1.01) }
        #expect(throws: SpatialLayoutError.nonFiniteCoordinate) { try NeutralPoint(validatingX: .nan, y: 0) }
        #expect(try NeutralPoint(validatingX: -1, y: 1) == NeutralPoint(x: -1, y: 1))
    }

    @Test func blurAndWidthOffsetDouble() throws {
        let input = LegacySourceInput(id: try Self.uuid(0), x: 0.5, y: 0.5, width: 0.4, isStereo: true)
        let source = try LegacySpatialImport.source(input)
        #expect(source.blur == 0.30)
        #expect(SpatialSourcePlacement.defaultBlur == LegacySpatialImport.distance(SpatialPanner.spatialBlur))
        #expect(SpatialSourcePlacement.widthOffsetFactor == 2 * LegacySpatialImport.legacyWidthOffsetFactor)
        #expect(source.width == 0.4)
        #expect(source.channelPositions().map(\.x) == [-0.2, 0.2])
    }

    @Test(arguments: [(0.5, 0.3, 0.5), (0.05, 0.9, 1.0), (0.95, 0.0, 0.8), (0.3, 0.7, 0)])
    func stereoPlacementsMatchLegacyChannelPlacements(legacyX: Double, legacyY: Double, width: Double) throws {
        let input = LegacySourceInput(id: try Self.uuid(1), x: legacyX, y: legacyY, width: width, isStereo: true,
                                      evidence: ["ch:1", "ch:9"])
        let source = try LegacySpatialImport.source(input)
        #expect(source.channelCount == 2)
        #expect(source.evidence == ["ch:1", "ch:9"])
        let legacy = [legacyX - width * 0.25, legacyX + width * 0.25].map { min(max($0, 0), 1) }
        let expected = try legacy.map { try LegacySpatialImport.point(x: $0, y: legacyY) }
        for (actual, want) in zip(source.channelPositions(), expected) {
            #expect(abs(actual.x - want.x) < 1e-12 && actual.y == want.y)
        }
        let monoInput = LegacySourceInput(id: try Self.uuid(1), x: legacyX, y: legacyY, width: width)
        let mono = try LegacySpatialImport.source(monoInput)
        #expect(mono.channelCount == 1 && mono.channelPositions() == [mono.position])
    }

    @Test func nonFiniteInputRefused() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(throws: SpatialLayoutError.nonFiniteCoordinate) { try NeutralPoint(x: bad, y: 0) }
            #expect(throws: SpatialLayoutError.nonFiniteCoordinate) { try LegacySpatialImport.point(x: 0, y: bad) }
            #expect(throws: SpatialLayoutError.invalidWidth) {
                try LegacySpatialImport.source(LegacySourceInput(id: try Self.uuid(0), x: 0, y: 0, width: bad))
            }
            #expect(throws: SpatialLayoutError.invalidBlur) {
                try SpatialSourcePlacement(sourceID: SpatialSourceID("src"), position: NeutralPoint(x: 0, y: 0),
                                           blur: bad)
            }
        }
    }

    @Test func invalidPlacementParametersRefused() throws {
        let origin = try NeutralPoint(x: 0, y: 0)
        let id = try SpatialSourceID("src")
        #expect(throws: SpatialLayoutError.invalidBlur) {
            try SpatialSourcePlacement(sourceID: id, position: origin, blur: 0)
        }
        #expect(throws: SpatialLayoutError.invalidWidth) {
            try SpatialSourcePlacement(sourceID: id, position: origin, width: 1.5)
        }
        for count in [0, 3] {
            #expect(throws: SpatialLayoutError.invalidChannelCount(count)) {
                try SpatialSourcePlacement(sourceID: id, position: origin, channelCount: count)
            }
        }
        #expect(throws: SpatialLayoutError.tooMuchEvidence(2)) {
            try SpatialSourcePlacement(sourceID: id, position: origin, evidence: ["a", "b"])
        }
    }

    @Test func duplicateSpeakerIDRefused() throws {
        let speakers = [try Self.speaker("spk.a"), try Self.speaker("spk.b", 1), try Self.speaker("spk.a", -1)]
        #expect(throws: SpatialLayoutError.duplicateSpeaker(try SpeakerID("spk.a"))) {
            try SpatialLayout(speakers: speakers)
        }
    }

    @Test func speakerAndGroupCapsAreSixtyFour() throws {
        let speakers = try (0...SpatialLayout.maximumSpeakers).map { try Self.speaker("spk.\($0)") }
        let allowed = Array(speakers.prefix(64))
        #expect(try SpatialLayout(speakers: allowed).speakers.count == 64)
        #expect(throws: SpatialLayoutError.tooManySpeakers(65)) { try SpatialLayout(speakers: speakers) }
        let groups = try (0...SpatialLayout.maximumGroups).map {
            SpeakerGroup(id: try SpeakerGroupID("grp.\($0)"), speakers: [allowed[0].id])
        }
        #expect(try SpatialLayout(speakers: allowed, groups: Array(groups.prefix(64))).groups.count == 64)
        #expect(throws: SpatialLayoutError.tooManyGroups(65)) { try SpatialLayout(speakers: allowed, groups: groups) }
    }

    @Test func missingOrUnmappedRouteIsInert() throws {
        let speakers = [try Self.speaker("spk.a", route: "route.out.1"), try Self.speaker("spk.b")]
        let layout = try SpatialLayout(speakers: speakers)
        let mapped = try SpeakerID("spk.a")
        let route = try RouteID("route.out.1")
        #expect(layout.route(for: mapped) == route)
        #expect(layout.route(for: mapped, available: [route]) == route)
        #expect(layout.route(for: mapped, available: [try RouteID("route.out.2")]) == nil)
        #expect(layout.route(for: try SpeakerID("spk.b")) == nil)
        #expect(layout.route(for: try SpeakerID("spk.missing"), available: [route]) == nil)
    }

    @Test func importIsUnroutedAndCarriesNamesAndEvidence() throws {
        let ids = try Self.quadIDs()
        var inputs = try Self.quadInputs()
        inputs[0] = LegacySpeakerInput(id: ids[0], name: "Front L", x: 0, y: 0, drivesPanning: false,
                                       evidence: "main:1")
        let pair = LegacySpeakerPairInput(id: try Self.uuid(9), name: "Front", left: ids[0], right: ids[1])
        let source = LegacySourceInput(id: try Self.uuid(8), name: "Cello", x: 0.5, y: 0.5)
        let result = try LegacySpatialImport.importLegacy(speakers: inputs, pairs: [pair], sources: [source])
        #expect(result.layout.speakers.allSatisfy { $0.route == nil })
        #expect(result.layout.speakers.map(\.evidence) == ["main:1", "bus:2", "bus:3", "bus:4"])
        #expect(result.layout.speakers.map(\.participatesInPanning) == [false, true, true, true])
        #expect(result.layout.speakers[0].name == "Front L" && result.layout.speakers[1].name == nil)
        #expect(result.layout.groups == [SpeakerGroup(id: SpeakerGroupID(uuid: try Self.uuid(9)), name: "Front",
                                                      speakers: ids.prefix(2).map { SpeakerID(uuid: $0) })])
        #expect(result.sources.map(\.name) == ["Cello"])
    }

    @Test func importErrorsNameTheOffendingItem() throws {
        var speakers = try Self.quadInputs()
        speakers[2] = LegacySpeakerInput(id: try Self.uuid(2), x: .nan, y: 0)
        #expect(throws: LegacySpatialImportError.speaker(index: 2, .nonFiniteCoordinate)) {
            try LegacySpatialImport.importLegacy(speakers: speakers)
        }
        let good = LegacySourceInput(id: try Self.uuid(5), x: 0, y: 0)
        let bad = LegacySourceInput(id: try Self.uuid(6), x: 0, y: 0, width: .infinity)
        #expect(throws: LegacySpatialImportError.source(index: 1, .invalidWidth)) {
            try LegacySpatialImport.importLegacy(speakers: Self.quadInputs(), sources: [good, bad, good])
        }
        let duplicate = SpatialSourceID(uuid: try Self.uuid(5))
        #expect(throws: LegacySpatialImportError.collection(.duplicateSource(duplicate))) {
            try LegacySpatialImport.importLegacy(speakers: Self.quadInputs(), sources: [good, good])
        }
        let many = try (0...LegacySpatialImportResult.maximumSources).map {
            LegacySourceInput(id: try Self.uuid($0, prefix: "20000000"), x: 0, y: 0)
        }
        #expect(throws: LegacySpatialImportError.collection(.tooManySources(65))) {
            try LegacySpatialImport.importLegacy(speakers: Self.quadInputs(), sources: many)
        }
        #expect(try LegacySpatialImport.importLegacy(speakers: [], sources: Array(many.prefix(64))).sources.count == 64)
        let stray = LegacySpeakerPairInput(id: try Self.uuid(3), left: try Self.uuid(0), right: try Self.uuid(7))
        let strayError = LegacySpatialImportError.collection(
            .unknownGroupMember(SpeakerGroupID(uuid: try Self.uuid(3)), SpeakerID(uuid: try Self.uuid(7)))
        )
        #expect(throws: strayError) {
            try LegacySpatialImport.importLegacy(speakers: Self.quadInputs(), pairs: [stray])
        }
    }

    @Test func namesAreNormalisedAndBounded() throws {
        #expect(SpatialName.normalize("Front\nL\t\u{7}") == "Front L  ")
        #expect(SpatialName.normalize("") == nil && SpatialName.normalize(nil) == nil)
        let accented = SpatialName.normalize("a" + String(repeating: "é", count: 100))
        #expect(accented == "a" + String(repeating: "é", count: 63))
        #expect(accented?.utf8.count == 127)
        #expect(SpatialName.normalize(String(repeating: "x", count: 200))?.utf8.count == 128)
        let group = SpeakerGroup(id: try SpeakerGroupID("grp"), name: "Rear\r\n", speakers: [])
        #expect(group.name == "Rear ")
        let source = try SpatialSourcePlacement(sourceID: SpatialSourceID("src"), name: "\u{0}",
                                                position: NeutralPoint(x: 0, y: 0))
        #expect(source.name == " ")
    }

    @Test func versionPolicyUsesContractCheck() throws {
        let result = try LegacySpatialImport.importLegacy(speakers: Self.quadInputs())
        #expect(result.transform == .unitSquareV1)
        #expect(LegacySpatialTransformVersion.unitSquareV1.rawValue == "legacy.unit-square.v1")
        #expect(result.layout.version == SpatialLayout.currentVersion)
        let name = SpatialLayout.currentVersion.contract
        #expect(throws: SpatialLayoutError.version(.unsupportedVersion(found: 2, supported: 1))) {
            try SpatialLayout(version: ContractVersion(contract: name, version: 2), speakers: [])
        }
        #expect(throws: SpatialLayoutError.version(.wrongContract(expected: name, found: "other"))) {
            try SpatialLayout(version: ContractVersion(contract: "other", version: 1), speakers: [])
        }
        #expect(throws: SpatialLayoutError.version(.invalidVersion(found: 0))) {
            try SpatialLayout(version: ContractVersion(contract: name, version: 0), speakers: [])
        }
    }
}

extension SpatialAdapterTests {
    @Test func extremeFiniteLegacyCoordinatesClampBeforeTransform() throws {
        let big = Double.greatestFiniteMagnitude
        #expect(try LegacySpatialImport.point(x: big, y: 0) == NeutralPoint(x: 1, y: 1))
        #expect(try LegacySpatialImport.point(x: -big, y: 0) == NeutralPoint(x: -1, y: 1))
        #expect(try LegacySpatialImport.point(x: 0, y: big) == NeutralPoint(x: -1, y: -1))
        #expect(try LegacySpatialImport.point(x: 0, y: -big) == NeutralPoint(x: -1, y: 1))
        #expect(try LegacySpatialImport.point(x: big, y: -big) == NeutralPoint(x: 1, y: 1))
        let wide = LegacySourceInput(id: try Self.uuid(0), x: -big, y: big, width: big, isStereo: true)
        let source = try LegacySpatialImport.source(wide)
        #expect(source.position == (try NeutralPoint(x: -1, y: -1)) && source.width == 1)
        #expect(source.channelPositions().allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func tinyAndNegativeZeroLegacyCoordinates() throws {
        let tiny = Double.leastNonzeroMagnitude
        for value in [tiny, -tiny, -0.0, 0.0] {
            let point = try LegacySpatialImport.point(x: value, y: value)
            #expect(point.x == -1 && point.y == 1)
        }
        let nearOne = try LegacySpatialImport.point(x: 1 - tiny, y: 1 + tiny)
        #expect(nearOne.x == 1 && nearOne.y == -1)
        let decoded = try JSONDecoder().decode(
            NeutralPoint.self, from: JSONEncoder().encode(LegacySpatialImport.point(x: -0.0, y: -0.0)))
        #expect(decoded == (try NeutralPoint(x: -1, y: 1)))
    }

    @Test func extremeItemDoesNotAbortMixedImport() throws {
        var speakers = try Self.quadInputs()
        speakers.append(LegacySpeakerInput(id: try Self.uuid(9), x: .greatestFiniteMagnitude, y: -0.0))
        let sources = [
            LegacySourceInput(id: try Self.uuid(20), x: 0.5, y: 0.5),
            LegacySourceInput(id: try Self.uuid(21), x: -.greatestFiniteMagnitude, y: .leastNonzeroMagnitude)
        ]
        let result = try LegacySpatialImport.importLegacy(speakers: speakers, sources: sources)
        #expect(result.layout.speakers.count == 5)
        #expect(result.layout.speakers[4].position == (try NeutralPoint(x: 1, y: 1)))
        #expect(result.sources.map(\.position) == [try NeutralPoint(x: 0, y: 0), try NeutralPoint(x: -1, y: 1)])
    }
}
