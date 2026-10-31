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

/// A test-only contract record that models three keys, including the explicit
/// `extensions` bag, and preserves stray keys in `unknownFields`.
private struct SampleRecord: Codable, Equatable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case child
        case extensions
    }

    var id: SampleID
    var child: SampleChild?
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(id: SampleID, unknownFields: [String: JSONValue]) {
        self.id = id
        self.unknownFields = unknownFields
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SampleID.self, forKey: .id)
        child = try container.decodeIfPresent(SampleChild.self, forKey: .child)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(child, forKey: .child)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

private struct SampleChild: Codable, Equatable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
    }

    var name: String
    var unknownFields: [String: JSONValue] = [:]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// Collects every key as unknown; used to probe non-object inputs.
private struct StrayKeysOnly: Decodable {
    let unknownFields: [String: JSONValue]

    init(from decoder: any Decoder) throws {
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: [])
    }
}

private func json(_ text: String) -> Data {
    Data(text.utf8)
}

private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try ContractCoding.decode(type, from: json(text))
}

/// Case-exact comparison, since `JSONValue` equality compares numbers by value.
private func sameCase(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    String(describing: lhs) == String(describing: rhs)
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
            ("gaïn", .invalidCharacter("ï")),
            ("id\u{1F600}", .invalidCharacter("\u{1F600}")),
            ("\u{FF21}bc", .invalidCharacter("\u{FF21}")),
            ("e\u{301}x", .invalidCharacter("e\u{301}")),
            (String(repeating: "é", count: 65), .invalidLength(130))
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
            #expect(SampleID(validated: "par.mains.gain") == id)
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
            let decoded = try decode(ContractVersion.self, #"{"contract":"fluxklang.media","version":1}"#)
            #expect(try decoded.check(supported: supported) == .current)
        }

        @Test(arguments: [
            ("fluxklang.media", 2, ContractVersionError.unsupportedVersion(found: 2, supported: 1)),
            ("fluxklang.graph", 1, .wrongContract(expected: "fluxklang.media", found: "fluxklang.graph")),
            ("fluxklang.media", 0, .invalidVersion(found: 0)),
            ("fluxklang.media", -1, .invalidVersion(found: -1))
        ])
        func rejectsUnreadableEnvelopes(contract: String, version: Int, error: ContractVersionError) {
            #expect(throws: error) {
                try ContractVersion.check(contract: contract, version: version, supported: supported)
            }
        }

        @Test func versionWithoutContractIsRejectedAndOlderMajorsNeedMigration() throws {
            #expect(throws: ContractVersionError.wrongContract(expected: "fluxklang.media", found: nil)) {
                try ContractVersion.check(contract: nil, version: 1, supported: supported)
            }
            let versionTwo = ContractVersion(contract: "fluxklang.media", version: 2)
            #expect(
                try ContractVersion.check(contract: "fluxklang.media", version: 1, supported: versionTwo)
                    == .needsMigration(from: 1)
            )
        }
    }
}

extension ContractCoreTests {
    struct JSONValues {
        @Test(arguments: [
            ("1", JSONValue.int(1)),
            ("-7", .int(-7)),
            ("0", .int(0)),
            ("false", .bool(false)),
            ("true", .bool(true)),
            ("1.5", .double(1.5)),
            ("1.0", .int(1)),
            ("-0.0", .int(0)),
            ("1e300", .double(1e300)),
            ("null", .null),
            (#""x""#, .string("x"))
        ])
        func decodesScalarsToTheExpectedCase(text: String, expected: JSONValue) throws {
            let value = try decode(JSONValue.self, text)
            #expect(sameCase(value, expected))
            #expect(value == expected)
        }

        @Test(arguments: [
            ("9223372036854775807", JSONValue.int(Int64.max)),
            ("-9223372036854775808", .int(Int64.min)),
            ("9223372036854775808", .uint(1 << 63)),
            ("18446744073709551615", .uint(UInt64.max))
        ])
        func sixtyFourBitIntegersRoundTripExactly(text: String, expected: JSONValue) throws {
            let value = try decode(JSONValue.self, text)
            #expect(sameCase(value, expected))
            #expect(try ContractCoding.makeEncoder().encode(value) == json(text))
        }

        @Test func integersBeyondSixtyFourBitsLosePrecision() throws {
            let text = "18446744073709551617"
            let value = try decode(JSONValue.self, text)
            #expect(sameCase(value, .double(18_446_744_073_709_551_616)))
            #expect(try ContractCoding.makeEncoder().encode(value) != json(text))
        }

        @Test func numbersCompareAndHashByValue() {
            let equalPairs: [(JSONValue, JSONValue)] = [
                (.double(1.0), .int(1)),
                (.uint(5), .int(5)),
                (.double(-0.0), .int(0)),
                (.double(-0.0), .double(0)),
                (.double(9_223_372_036_854_775_808), .uint(1 << 63)),
                (.array([.double(2)]), .array([.uint(2)]))
            ]
            for (lhs, rhs) in equalPairs {
                #expect(lhs == rhs)
                #expect(lhs.hashValue == rhs.hashValue)
            }
            #expect(JSONValue.double(0.5) != .int(0))
            #expect(JSONValue.double(1e300) != .int(Int64.max))
            #expect(JSONValue.int(-1) != .uint(UInt64.max))
            #expect(JSONValue.bool(true) != .int(1))
        }

        @Test func nestedValuesRoundTripByteEqual() throws {
            let canonical = #"{"a":[1,1.5,false,null,{"b":[]}],"c":{"d":"e/f","g":9223372036854775807}}"#
            let value = try decode(JSONValue.self, canonical)
            #expect(value == .object([
                "a": .array([.int(1), .double(1.5), .bool(false), .null, .object(["b": .array([])])]),
                "c": .object(["d": .string("e/f"), "g": .int(Int64.max)])
            ]))
            #expect(try ContractCoding.makeEncoder().encode(value) == json(canonical))
        }

        @Test func contractEncoderOutputIsIdenticalAcrossEncodes() throws {
            let members = Dictionary(uniqueKeysWithValues: (0..<24).map { ("k\($0)", JSONValue.int(Int64($0))) })
            let record = SampleRecord(id: SampleID(validated: "rec.1"), unknownFields: members)
            let outputs = try (0..<8).map { _ in
                try ContractCoding.makeEncoder().encode(JSONValue.object(members))
                    + ContractCoding.makeEncoder().encode(record)
            }
            #expect(Set(outputs).count == 1)
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
            let record = try decode(SampleRecord.self, canonical)
            #expect(record.id.rawValue == "rec.1")
            #expect(record.unknownFields == ["future": .object(["x": .bool(true)]), "more": .null])
            #expect(record.child?.unknownFields == ["zeta": .array([.int(1), .object(["q": .double(2.5)])])])
            #expect(try ContractCoding.makeEncoder().encode(record) == json(canonical))
        }

        @Test func knownKeysWinOverUnknownFields() throws {
            let record = SampleRecord(
                id: SampleID(validated: "rec.real"),
                unknownFields: ["id": .string("rec.stray"), "extensions": .int(3), "extra": .int(1)]
            )
            let encoded = try ContractCoding.makeEncoder().encode(record)
            #expect(encoded == json(#"{"extra":1,"id":"rec.real"}"#))
            let decoded = try ContractCoding.makeDecoder().decode(SampleRecord.self, from: encoded)
            #expect(decoded.id.rawValue == "rec.real")
            #expect(decoded.unknownFields == ["extra": .int(1)])
        }

        @Test func explicitExtensionsBagAndStrayKeysAreSeparate() throws {
            let canonical = #"{"extensions":{"vendor.x":1},"id":"rec.2","stray":true}"#
            let record = try decode(SampleRecord.self, canonical)
            #expect(record.extensions == ["vendor.x": .int(1)])
            #expect(record.unknownFields == ["stray": .bool(true)])
            #expect(try ContractCoding.makeEncoder().encode(record) == json(canonical))
            // A strict validator rejects the document because the stray-key bag is non-empty;
            // the same data under `extensions` alone passes.
            let strict = try decode(SampleRecord.self, #"{"extensions":{"stray":true},"id":"rec.2"}"#)
            #expect(strict.unknownFields.isEmpty)
        }

        @Test(arguments: ["[1]", "3", #""x""#])
        func nonObjectInputThrowsTypeMismatch(text: String) {
            #expect {
                try decode(StrayKeysOnly.self, text)
            } throws: { error in
                guard case DecodingError.typeMismatch = error else { return false }
                return true
            }
        }
    }
}

extension ContractCoreTests {
    struct Revisions {
        @Test func revisionsOrderAndAdvance() throws {
            let first = ContractRevision.initial
            #expect(first.value == 0)
            #expect(try first < first.next())
            #expect(try first.next() == ContractRevision(1))
        }

        @Test(arguments: [-1, ContractRevision.maximumValue + 1])
        func revisionRejectsOutOfRange(raw: Int) {
            #expect(throws: RevisionError.outOfRange(raw)) { try ContractRevision(raw) }
            #expect(throws: DecodingError.self) { try decode(ContractRevision.self, String(raw)) }
        }

        @Test func countersThrowOverflowAtTheMaximum() throws {
            #expect(ContractRevision.maximumValue == 9_007_199_254_740_991)
            #expect(Generation.maximumValue == ContractRevision.maximumValue)
            #expect(throws: RevisionError.overflow) {
                try ContractRevision(ContractRevision.maximumValue).next()
            }
            #expect(throws: RevisionError.overflow) { try Generation(Generation.maximumValue).next() }
            #expect(try decode(ContractRevision.self, "9007199254740991").value == ContractRevision.maximumValue)
        }

        @Test func validatesStrictlyIncreasingSequences() throws {
            let revisions = try [0, 2, 5].map { try ContractRevision($0) }
            try ContractRevision.validateStrictlyIncreasing(revisions)
            for values in [[0, 2, 2], [5, 3]] {
                let bad = try values.map { try ContractRevision($0) }
                let index = bad.count - 1
                #expect(throws: RevisionError.notStrictlyIncreasing(
                    index: index, previous: bad[index - 1], found: bad[index]
                )) {
                    try ContractRevision.validateStrictlyIncreasing(bad)
                }
            }
        }

        @Test func generationsStartAtOneAndStepByOne() throws {
            let first = Generation.initial
            #expect(first.value == 1)
            #expect(try first.next().value == 2)
            #expect(try first.next() == Generation(2))
            #expect(try first != first.next())
            #expect(try ContractCoding.makeEncoder().encode(first.next()) == json("2"))
        }

        @Test(arguments: [0, -1, Generation.maximumValue + 1])
        func generationRejectsOutOfRange(raw: Int) {
            #expect(throws: RevisionError.outOfRange(raw)) { try Generation(raw) }
            #expect(throws: DecodingError.self) { try decode(Generation.self, String(raw)) }
        }
    }
}

extension ContractCoreTests {
    struct DuplicateNames {
        @Test(arguments: [
            (#"{"x":{"\u00e9":1,"e\u0301":2}}"#, "$.x"),
            (#"{"list":[{"a":1,"a":2}]}"#, "$.list[0]"),
            (#"{"\u0041":1,"A":2}"#, "$")
        ])
        func duplicateMemberNamesAreRejected(text: String, path: String) {
            #expect {
                try decode(JSONValue.self, text)
            } throws: { error in
                guard case DecodingError.dataCorrupted(let context) = error else { return false }
                return context.debugDescription.hasSuffix(" at \(path)")
            }
        }

        @Test func strayKeyCollisionIsRejected() {
            let text = #"{"id":"r.1","\u00e9":1,"e\u0301":2}"#
            #expect(throws: DecodingError.self) { try decode(SampleRecord.self, text) }
        }

        @Test func escapedAndSiblingNamesDecode() throws {
            let text = #"{"\u0041":[{"a":1},{"a":2}],"\ud83d\ude00":{"a":{"a":3}},"q\"k":4}"#
            #expect(try decode(JSONValue.self, text) == .object([
                "A": .array([.object(["a": .int(1)]), .object(["a": .int(2)])]),
                "\u{1F600}": .object(["a": .object(["a": .int(3)])]),
                "q\"k": .int(4)
            ]))
        }

        /// Why `ContractCoding.decode` exists: plain JSONDecoder keeps one of each duplicate.
        @Test func plainJSONDecoderCollapsesDuplicates() throws {
            let value = try JSONDecoder().decode(JSONValue.self, from: json(#"{"\u00e9":1,"e\u0301":2,"a":3,"a":4}"#))
            #expect(value == .object(["\u{E9}": .int(1), "a": .int(3)]))
        }

        @Test(arguments: [
            encoded(#"{"a":1,"a":2}"#, width: 1, bigEndian: false, bom: true),
            encoded(#"{"a":1}"#, width: 1, bigEndian: false, bom: true),
            encoded(#"{"a":1,"a":2}"#, width: 2, bigEndian: false, bom: false),
            encoded(#"{"a":1,"a":2}"#, width: 2, bigEndian: false, bom: true),
            encoded(#"{"a":1,"a":2}"#, width: 2, bigEndian: true, bom: false),
            encoded(#"{"a":1,"a":2}"#, width: 2, bigEndian: true, bom: true),
            encoded(#"{"a":1}"#, width: 4, bigEndian: false, bom: true),
            encoded(#"{"a":1}"#, width: 4, bigEndian: true, bom: false)
        ])
        func nonUTF8OrByteOrderMarkIsRejected(bytes: [UInt8]) {
            #expect {
                try ContractCoding.decode(JSONValue.self, from: Data(bytes))
            } throws: { error in
                guard case DecodingError.dataCorrupted(let context) = error else { return false }
                return context.debugDescription == "Contract documents must be UTF-8 without a byte order mark"
            }
        }
    }
}

/// `text` as UTF-8 (`width` 1), UTF-16 (2) or UTF-32 (4), optionally with a BOM.
private func encoded(_ text: String, width: Int, bigEndian: Bool, bom: Bool) -> [UInt8] {
    if width == 1 { return (bom ? [0xEF, 0xBB, 0xBF] : []) + Array(text.utf8) }
    let body: [UInt32] = width == 2 ? text.utf16.map(UInt32.init) : text.unicodeScalars.map(\.value)
    let units: [UInt32] = (bom ? [0xFEFF] : []) + body
    return units.flatMap { unit -> [UInt8] in
        let little = (0..<width).map { UInt8(truncatingIfNeeded: unit >> (8 * $0)) }
        return bigEndian ? little.reversed() : little
    }
}
