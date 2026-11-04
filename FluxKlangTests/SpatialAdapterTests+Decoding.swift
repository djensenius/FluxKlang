import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialAdapterTests {
    static let versionJSON = #"{"contract":"fluxklang.spatial-layout","version":1}"#
    static let speakerA = #"{"id":"a","position":{"x":0,"y":0}}"#
    static let speakerB = #"{"id":"b","position":{"x":1,"y":1}}"#

    static func layoutJSON(version: String = versionJSON, speakers: [String], groups: [String] = []) -> String {
        #"{"version":\#(version),"speakers":[\#(speakers.joined(separator: ","))],"#
            + #""groups":[\#(groups.joined(separator: ","))]}"#
    }

    static func decodeError<Value: Decodable>(_ type: Value.Type, _ json: String) -> SpatialLayoutError? {
        do {
            _ = try JSONDecoder().decode(type, from: Data(json.utf8))
            return nil
        } catch let DecodingError.dataCorrupted(context) {
            return context.underlyingError as? SpatialLayoutError
        } catch {
            return nil
        }
    }

    static func speakerList(_ count: Int) -> [String] {
        (0..<count).map { #"{"id":"s\#($0)","position":{"x":0,"y":0}}"# }
    }

    static let layoutDecodeCases: [(String, SpatialLayoutError)] = {
        let idA = SpeakerID(validated: "a")
        let idB = SpeakerID(validated: "b")
        let group = SpeakerGroupID(validated: "g")
        let long = String(repeating: "e", count: 257)
        return [
            (layoutJSON(speakers: [speakerA], groups: [#"{"id":"g","speakers":[]}"#]), .emptyGroup(group)),
            (layoutJSON(speakers: [speakerA], groups: Array(repeating: #"{"id":"g","speakers":["a"]}"#, count: 2)),
             .duplicateGroup(group)),
            (layoutJSON(speakers: [speakerA], groups: [#"{"id":"g","speakers":["a","a"]}"#]),
             .duplicateGroupMember(group, idA)),
            (layoutJSON(speakers: [speakerA], groups: [#"{"id":"g","speakers":["b"]}"#]),
             .unknownGroupMember(group, idB)),
            (layoutJSON(speakers: speakerList(65)), .tooManySpeakers(65)),
            (layoutJSON(speakers: [speakerA],
                        groups: (0..<65).map { #"{"id":"g\#($0)","speakers":["a"]}"# }), .tooManyGroups(65)),
            (layoutJSON(version: #"{"contract":"fluxklang.spatial-layout","version":2}"#, speakers: []),
             .version(.unsupportedVersion(found: 2, supported: 1))),
            (layoutJSON(version: #"{"contract":"other","version":1}"#, speakers: []),
             .version(.wrongContract(expected: "fluxklang.spatial-layout", found: "other"))),
            (layoutJSON(speakers: [#"{"id":"a","position":{"x":0,"y":0},"evidence":"\#(long)"}"#]),
             .evidenceTooLong(257)),
            (layoutJSON(speakers: [#"{"id":"a","position":{"x":1.5,"y":0}}"#]), .coordinateOutOfRange),
            (layoutJSON(speakers: [speakerA, speakerB, speakerA]), .duplicateSpeaker(idA))
        ]
    }()

    @Test func layoutDecodeRefusesWithSpecificTypedErrors() {
        for (json, expected) in Self.layoutDecodeCases {
            #expect(Self.decodeError(SpatialLayout.self, json) == expected, "\(json.prefix(120))")
        }
        let valid = Self.layoutJSON(speakers: [Self.speakerA, Self.speakerB],
                                    groups: [#"{"id":"g","speakers":["a","b"]}"#])
        #expect((try? JSONDecoder().decode(SpatialLayout.self, from: Data(valid.utf8)))?.groups.count == 1)
    }

    @Test func importResultDecodeRevalidatesSources() throws {
        let layout = Self.layoutJSON(speakers: [Self.speakerA])
        let source = { (id: String) in
            #"{"sourceID":"\#(id)","position":{"x":0,"y":0},"blur":0.3,"width":0.5,"channelCount":1}"#
        }
        func result(_ sources: [String]) -> String {
            #"{"transform":"legacy.unit-square.v1","layout":\#(layout),"sources":[\#(sources.joined(separator: ","))]}"#
        }
        #expect(Self.decodeError(LegacySpatialImportResult.self, result([source("s"), source("s")]))
            == .duplicateSource(SpatialSourceID(validated: "s")))
        #expect(Self.decodeError(LegacySpatialImportResult.self, result((0..<65).map { source("s\($0)") }))
            == .tooManySources(65))
        let badLayout = #"{"transform":"legacy.unit-square.v1","layout":"#
            + Self.layoutJSON(speakers: [Self.speakerA, Self.speakerA]) + #","sources":[]}"#
        #expect(Self.decodeError(LegacySpatialImportResult.self, badLayout)
            == .duplicateSpeaker(SpeakerID(validated: "a")))
        let decoded = try JSONDecoder().decode(LegacySpatialImportResult.self, from: Data(result([source("s")]).utf8))
        #expect(decoded.sources.count == 1 && decoded.layout.speakers[0].participatesInPanning)
    }

    @Test func codableRoundTripIsStable() throws {
        var speakers = try Self.quadInputs()
        speakers[3] = LegacySpeakerInput(id: speakers[3].id, name: "Sub", x: 1, y: 1, drivesPanning: false)
        let sources = [LegacySourceInput(id: try Self.uuid(2), name: "Keys", x: 0.2, y: 0.6, width: 0.7,
                                         isStereo: true, evidence: ["ch:3", "ch:4"])]
        let pair = LegacySpeakerPairInput(id: try Self.uuid(7), name: "Front",
                                          left: speakers[0].id, right: speakers[1].id)
        let result = try LegacySpatialImport.importLegacy(speakers: speakers, pairs: [pair], sources: sources)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let decoded = try JSONDecoder().decode(LegacySpatialImportResult.self, from: data)
        #expect(decoded == result)
        #expect(try encoder.encode(decoded) == data)
        #expect(String(data: data, encoding: .utf8)?.contains(#""participatesInPanning":false"#) == true)
    }
}
