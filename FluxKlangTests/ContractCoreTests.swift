//
//  ContractCoreTests.swift
//  FluxKlangTests
//
//  Shared contract primitives: IDs, version policy, JSON values, unknown-key
//  preservation and revision/generation counters.
//

import Foundation
import Testing
@testable import FluxKlang

private enum SampleTag: ContractIDTag {}
private typealias SampleID = ContractID<SampleTag>

/// A test-only contract record that models two keys and preserves the rest.
private struct SampleRecord: Codable, Equatable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case child
    }

    var id: SampleID
    var child: SampleChild?
    var extensions: [String: JSONValue] = [:]

    init(id: SampleID, child: SampleChild?, extensions: [String: JSONValue]) {
        self.id = id
        self.child = child
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SampleID.self, forKey: .id)
        child = try container.decodeIfPresent(SampleChild.self, forKey: .child)
        extensions = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(child, forKey: .child)
        try ExtensionFields.encode(extensions, to: encoder, knownKeys: CodingKeys.self)
    }
}

private struct SampleChild: Codable, Equatable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
    }

    var name: String
    var extensions: [String: JSONValue] = [:]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        extensions = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try ExtensionFields.encode(extensions, to: encoder, knownKeys: CodingKeys.self)
    }
}

private func sortedEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func json(_ text: String) -> Data {
    Data(text.utf8)
}

struct ContractCoreTests {}

extension ContractCoreTests {
    struct IDs {
        @Test(arguments: [
            "a",
            "par.mains.gain",
            "ex.01-name_x:y",
            String(repeating: "a", count: 128)
        ])
        func acceptsValidIDs(raw: String) throws {
            let id = try SampleID(raw)
            #expect(id.rawValue == raw)
            #expect(SampleID(rawValue: raw) == id)
        }

        @Test(arguments: [
            ("", ContractIDError.invalidLength(0)),
            (String(repeating: "a", count: 129), .invalidLength(129)),
            ("par mains", .invalidCharacter(" ")),
            ("par/mains", .invalidCharacter("/")),
            ("gaïn", .invalidCharacter("ï"))
        ])
        func rejectsInvalidIDs(raw: String, error: ContractIDError) {
            #expect(throws: error) { try SampleID(raw) }
            #expect(SampleID(rawValue: raw) == nil)
        }

        @Test func uuidRoundTripsAsUppercaseString() throws {
            let uuid = try #require(UUID(uuidString: "0f8fad5b-d9cb-469f-a165-70867728950e"))
            let id = SampleID(uuid: uuid)
            #expect(id.rawValue == "0F8FAD5B-D9CB-469F-A165-70867728950E")
            let legacy = try JSONEncoder().encode(uuid)
            let encoded = try JSONEncoder().encode(id)
            #expect(encoded == legacy)
            #expect(try JSONDecoder().decode(SampleID.self, from: encoded) == id)
            #expect(UUID(uuidString: id.rawValue) == uuid)
        }

        @Test func codesAsBareStringAndOrdersByRawValue() throws {
            let id = try SampleID("par.mains.gain")
            #expect(try JSONEncoder().encode(id) == json("\"par.mains.gain\""))
            #expect(try SampleID("a.b") < SampleID("a.c"))
        }

        @Test func decodingAnInvalidStringThrowsDataCorrupted() {
            #expect {
                try JSONDecoder().decode(SampleID.self, from: json("\"bad id\""))
            } throws: { error in
                guard case DecodingError.dataCorrupted = error else { return false }
                return true
            }
        }
    }
}

extension ContractCoreTests {
    struct Versions {
        private let supported = ContractVersion(contract: "fluxklang.media", version: 1)

        @Test func currentAndLegacyEnvelopes() throws {
            #expect(
                try ContractVersion.check(contract: "fluxklang.media", version: 1, supported: supported) == .current
            )
            #expect(try ContractVersion.check(contract: nil, version: nil, supported: supported) == .legacyUnversioned)
            #expect(
                try ContractVersion.check(contract: "fluxklang.media", version: nil, supported: supported)
                    == .legacyUnversioned
            )
            let decoded = try JSONDecoder().decode(
                ContractVersion.self,
                from: json(#"{"contract":"fluxklang.media","version":1}"#)
            )
            #expect(try decoded.check(supported: supported) == .current)
        }

        @Test(arguments: [
            ("fluxklang.media", 2, ContractVersionError.unsupportedVersion(found: 2, supported: 1)),
            ("fluxklang.graph", 1, .wrongContract(expected: "fluxklang.media", found: "fluxklang.graph")),
            ("fluxklang.media", 0, .invalidVersion(found: 0))
        ])
        func rejectsUnreadableEnvelopes(contract: String, version: Int, error: ContractVersionError) {
            #expect(throws: error) {
                try ContractVersion.check(contract: contract, version: version, supported: supported)
            }
        }

        @Test func rejectsVersionWithoutContractAndOlderMajors() {
            #expect(throws: ContractVersionError.wrongContract(expected: "fluxklang.media", found: nil)) {
                try ContractVersion.check(contract: nil, version: 1, supported: supported)
            }
            let versionTwo = ContractVersion(contract: "fluxklang.media", version: 2)
            #expect(throws: ContractVersionError.olderVersion(found: 1, supported: 2)) {
                try ContractVersion.check(contract: "fluxklang.media", version: 1, supported: versionTwo)
            }
        }
    }
}

extension ContractCoreTests {
    struct JSONValues {
        @Test(arguments: [
            ("1", JSONValue.int(1)),
            ("-7", .int(-7)),
            ("1.5", .double(1.5)),
            ("9223372036854775807", .int(Int64.max)),
            ("9223372036854775808", .double(9_223_372_036_854_775_808)),
            ("true", .bool(true)),
            ("null", .null),
            (#""x""#, .string("x"))
        ])
        func decodesScalars(text: String, expected: JSONValue) throws {
            #expect(try JSONDecoder().decode(JSONValue.self, from: json(text)) == expected)
        }

        @Test func nestedValuesRoundTripByteEqual() throws {
            let canonical = #"{"a":[1,1.5,false,null,{"b":[]}],"c":{"d":"e","f":9223372036854775807}}"#
            let value = try JSONDecoder().decode(JSONValue.self, from: json(canonical))
            #expect(value == .object([
                "a": .array([.int(1), .double(1.5), .bool(false), .null, .object(["b": .array([])])]),
                "c": .object(["d": .string("e"), "f": .int(Int64.max)])
            ]))
            #expect(try sortedEncoder().encode(value) == json(canonical))
        }

        @Test(arguments: [Double.nan, .infinity, -.infinity])
        func rejectsNonFiniteDoublesOnEncode(value: Double) {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
            )
            #expect(throws: EncodingError.self) { try encoder.encode(JSONValue.array([.double(value)])) }
        }
    }
}

extension ContractCoreTests {
    struct Extensions {
        @Test func preservesUnknownTopLevelAndNestedKeysByteEqual() throws {
            let canonical = #"{"child":{"name":"n","zeta":[1,{"q":2.5}]},"future":{"x":true},"id":"rec.1","more":null}"#
            let record = try JSONDecoder().decode(SampleRecord.self, from: json(canonical))
            #expect(record.id.rawValue == "rec.1")
            #expect(record.extensions == ["future": .object(["x": .bool(true)]), "more": .null])
            #expect(record.child?.extensions == ["zeta": .array([.int(1), .object(["q": .double(2.5)])])])
            #expect(try sortedEncoder().encode(record) == json(canonical))
        }

        @Test func knownKeysWinOverExtensions() throws {
            let record = SampleRecord(
                id: try SampleID("rec.real"),
                child: nil,
                extensions: ["id": .string("rec.stray"), "child": .int(3), "extra": .int(1)]
            )
            let encoded = try sortedEncoder().encode(record)
            #expect(encoded == json(#"{"extra":1,"id":"rec.real"}"#))
            let decoded = try JSONDecoder().decode(SampleRecord.self, from: encoded)
            #expect(decoded.id.rawValue == "rec.real")
            #expect(decoded.extensions == ["extra": .int(1)])
        }
    }
}

extension ContractCoreTests {
    struct Revisions {
        @Test func revisionsOrderAndAdvance() throws {
            let first = ContractRevision.initial
            #expect(first.value == 0)
            #expect(first < first.next())
            #expect(try first.next() == ContractRevision(1))
            #expect(throws: RevisionError.negativeRevision(-1)) { try ContractRevision(-1) }
        }

        @Test func validatesStrictlyIncreasingSequences() throws {
            let revisions = try [0, 2, 5].map { try ContractRevision($0) }
            try ContractRevision.validateStrictlyIncreasing(revisions)
            let repeated = try [0, 2, 2].map { try ContractRevision($0) }
            #expect(throws: RevisionError.notStrictlyIncreasing(
                index: 2, previous: repeated[1], found: repeated[2]
            )) {
                try ContractRevision.validateStrictlyIncreasing(repeated)
            }
        }

        @Test func revisionDecodingRejectsNegatives() throws {
            #expect(try JSONDecoder().decode(ContractRevision.self, from: json("3")) == ContractRevision(3))
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ContractRevision.self, from: json("-1")) }
        }

        @Test func generationsStartAtOneAndStepByOne() throws {
            let first = Generation.initial
            #expect(first.value == 1)
            #expect(first.next().value == 2)
            #expect(first.next() == (try Generation(2)))
            #expect(first != first.next())
            #expect(try JSONEncoder().encode(first.next()) == json("2"))
        }

        @Test(arguments: [0, -1])
        func generationRejectsNonPositive(raw: Int) {
            #expect(throws: RevisionError.invalidGeneration(raw)) { try Generation(raw) }
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Generation.self, from: json(String(raw))) }
        }
    }
}
