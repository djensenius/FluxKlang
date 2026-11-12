import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct PatchVariationTests {
    static let gain = ParameterID(validated: "par.gain")
    static let mix = ParameterID(validated: "par.mix")
    static let mode = ParameterID(validated: "par.mode")
    static let routing = ParameterID(validated: "par.routing")
    static let danger = ParameterID(validated: "par.danger")
    static let verse = PatchVariationID(validated: "verse")
    static let chorus = PatchVariationID(validated: "chorus")
    static let key = PatchVariationExtension.key

    static func descriptor(
        _ id: ParameterID, unit: ParameterUnit, _ range: ClosedRange<Double>, ceiling: Double? = nil,
        curve: ParameterCurve = .linear, controlClass: ControlClass = .live
    ) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: range.lowerBound, upper: range.upperBound, defaultValue: range.lowerBound,
            ceiling: ceiling, curve: curve, ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }

    /// gain dB -90...10 (ceiling 6), mix 0...1, mode index 1...4 (live); routing structural; danger hazardous.
    static func table() throws -> PatchParameterTable {
        try PatchParameterTable(ParameterCatalog([
            descriptor(gain, unit: .decibels, -90...10, ceiling: 6, curve: .faderTaper),
            descriptor(mix, unit: .normalized, 0...1),
            descriptor(mode, unit: .index, 1...4, curve: .stepped),
            descriptor(routing, unit: .normalized, 0...1, controlClass: .structural),
            descriptor(danger, unit: .normalized, 0...1, controlClass: .hazardous)
        ]))
    }

    static func delta(_ parameter: ParameterID, _ value: Double, _ unit: ParameterUnit) -> PatchParameterDelta {
        PatchParameterDelta(parameter: parameter, value: ParameterValue(value: value, unit: unit))
    }

    static func patch(_ id: StaticString = "patch.a", extensions: [String: JSONValue]? = nil) -> ProjectPatch {
        ProjectPatch(id: PatchID(validated: id), label: "Patch", graph: GraphID(validated: "graph.main"),
                     extensions: extensions)
    }

    static func numbered(_ count: Int) throws -> [PatchVariation] {
        try (0..<count).map { try PatchVariation(id: PatchVariationID("v.\($0)"), label: "V \($0)") }
    }

    static func canonical(_ value: some Encodable) throws -> Data {
        try ContractCoding.makeEncoder().encode(value)
    }

    static func raw(_ set: PatchVariationSet) throws -> JSONValue {
        try ContractCoding.decode(JSONValue.self, from: canonical(set))
    }

    static func patch(raw: String) throws -> ProjectPatch {
        try ContractCoding.decode(ProjectPatch.self, from: Data(raw.utf8))
    }

    @Test
    func roundTripKeepsUnknownFieldsAtEveryLevelAndForeignKeys() throws {
        var delta = Self.delta(Self.gain, -3.5, .decibels)
        delta.extensions = ["note": .string("delta")]
        delta.unknownFields = ["deltaStray": .array([.int(1), .null])]
        var variation = PatchVariation(id: Self.verse, label: "Verse", deltas: [delta], extensions: ["v": .bool(true)])
        variation.unknownFields = ["variationStray": .object(["k": .double(0.25)])]
        var set = PatchVariationSet(variations: [variation], extensions: ["s": .int(7)])
        set.unknownFields = ["setStray": .string("kept")]
        var original = Self.patch(extensions: ["other": .object(["deep": .array([.double(1.5)])])])
        original.unknownFields = ["patchStray": .bool(false)]

        let written = try PatchVariationExtension.write(set, to: original)
        #expect(try PatchVariationExtension.read(from: written) == set)
        #expect(written.extensions?["other"] == original.extensions?["other"])
        #expect(written.unknownFields == original.unknownFields)
        let decoded = try ContractCoding.decode(ProjectPatch.self, from: Self.canonical(written))
        #expect(decoded == written)
        #expect(try PatchVariationExtension.read(from: decoded) == set)
        #expect(try PatchVariationExtension.write(PatchVariationExtension.read(from: decoded), to: decoded) == decoded)
    }

    @Test
    func readModifyWriteKeepsForeignKeysByteIdentical() throws {
        let source = #"{"extensions":{"a.first":{"list":[1,2.5,"x",null],"z":true},"#
            + #""fluxklang.patchVariations":{"variations":[],"version":1},"zz.last":-0.125},"#
            + #""graph":"graph.main","id":"patch.a","label":"Patch","stray":{"q":1}}"#
        let original = try Self.patch(raw: source)
        #expect(try Self.canonical(original) == Data(source.utf8))
        var set = try PatchVariationExtension.read(from: original)
        let added = PatchVariation(id: Self.verse, label: "Verse", deltas: [Self.delta(Self.mix, 0.5, .normalized)])
        set.variations.append(added)
        let updated = try ContractCoding.decode(ProjectPatch.self, from: Self.canonical(
            PatchVariationExtension.write(set, to: original)))
        for name in ["a.first", "zz.last"] {
            #expect(try Self.canonical(updated.extensions?[name]) == Self.canonical(original.extensions?[name]))
        }
        var strippedBefore = original, strippedAfter = updated
        strippedBefore.extensions?[Self.key] = nil
        strippedAfter.extensions?[Self.key] = nil
        #expect(try Self.canonical(strippedAfter) == Self.canonical(strippedBefore))
        #expect(updated.extensions?[Self.key] != original.extensions?[Self.key])
    }

    @Test
    func futureVersionIsPreservedByteForByteAndReadOnly() throws {
        let source = #"{"extensions":{"fluxklang.patchVariations":{"variations":"opaque","version":2,"#
            + #""wholly":{"new":[1,2]}}},"graph":"graph.main","id":"patch.a","label":"Patch"}"#
        let patch = try Self.patch(raw: source)
        #expect(try PatchVariationExtension.content(of: patch) == .future(version: 2))
        #expect(throws: PatchVariationError.futureVersionReadOnly(2)) { try PatchVariationExtension.read(from: patch) }
        #expect(throws: PatchVariationError.futureVersionReadOnly(2)) {
            try PatchVariationExtension.write(PatchVariationSet(), to: patch)
        }
        #expect(throws: PatchVariationError.futureVersionReadOnly(2)) {
            try PatchVariationExtension.write(PatchVariationSet(variations: Self.numbered(1)), to: patch)
        }
        #expect(throws: PatchVariationError.futureVersionReadOnly(2)) {
            try PatchRecallPlanner.plan(for: patch, table: Self.table(), baseline: .defaults(Self.table()),
                                        from: nil, to: nil)
        }
        var attempted = patch
        #expect(throws: PatchVariationError.futureVersionReadOnly(2)) {
            attempted = try PatchVariationExtension.write(PatchVariationSet(variations: Self.numbered(2)), to: patch)
        }
        let reencoded = try ContractCoding.decode(ProjectPatch.self, from: Self.canonical(attempted))
        #expect(try Self.canonical(reencoded) == Data(source.utf8))
    }

    @Test
    func versionPins() throws {
        let cases: [(JSONValue?, PatchVariationError?)] = [
            (.int(1), nil), (.uint(1), nil), (.double(1.0), nil), (.int(0), .malformed), (.int(-1), .malformed),
            (.uint(0), .malformed), (.double(0), .malformed), (.double(-0.0), .malformed), (.double(-2), .malformed),
            (nil, .malformed), (.string("1"), .malformed), (.double(1.5), .malformed), (.double(2.5), .malformed),
            (.double(.nan), .malformed), (.bool(true), .malformed), (.null, .malformed)
        ]
        for (version, expected) in cases {
            var members: [String: JSONValue] = ["variations": .array([])]
            members["version"] = version
            let patch = Self.patch(extensions: [Self.key: .object(members)])
            if let expected {
                #expect(throws: expected) { try PatchVariationExtension.read(from: patch) }
                #expect(throws: expected) { try PatchVariationExtension.write(PatchVariationSet(), to: patch) }
            } else {
                #expect(try PatchVariationExtension.read(from: patch) == PatchVariationSet())
            }
        }
        let futures: [(JSONValue, Int)] = [
            (.int(2), 2), (.double(2.0), 2), (.uint(2), 2), (.uint(UInt64(Int64.max) + 1), Int.max),
            (.uint(.max), Int.max), (.double(1e300), Int.max)
        ]
        for (version, expected) in futures {
            let future = Self.patch(extensions: [Self.key: .object(["version": version, "variations": .null])])
            #expect(try PatchVariationExtension.content(of: future) == .future(version: expected))
            #expect(throws: PatchVariationError.futureVersionReadOnly(expected)) {
                try PatchVariationExtension.write(PatchVariationSet(), to: future)
            }
        }
        let bigSource = #"{"extensions":{"fluxklang.patchVariations":{"version":18446744073709551615}},"#
            + #""graph":"graph.main","id":"patch.a","label":"Patch"}"#
        let decodedBig = try Self.patch(raw: bigSource)
        #expect(try PatchVariationExtension.content(of: decodedBig) == .future(version: Int.max))
        #expect(try Self.canonical(decodedBig) == Data(bigSource.utf8))
        #expect(throws: DecodingError.self) {
            try ContractCoding.decode(PatchVariationSet.self, from: Data(#"{"variations":[],"version":2}"#.utf8))
        }
    }

    @Test
    func malformedStoredValuesAreRefusedAndNeverOverwritten() throws {
        let validDelta: JSONValue = .object([
            "parameter": .string("par.mix"), "value": .int(1), "unit": .string("normalized")
        ])
        func stored(id: String = "verse", delta: JSONValue = validDelta) -> JSONValue {
            .object(["version": .int(1), "variations": .array([
                .object(["id": .string(id), "label": .string("Verse"), "deltas": .array([delta])])
            ])])
        }
        let badValues: [JSONValue] = [
            .string("nope"), .array([]), stored(id: "bad id"),
            stored(delta: .object(["parameter": .string("par.mix"), "value": .int(1), "unit": .string("furlongs")])),
            stored(delta: .object(["parameter": .string("par.mix"), "unit": .string("normalized")])),
            .object(["version": .int(1)])
        ]
        for value in badValues {
            let patch = Self.patch(extensions: [Self.key: value])
            #expect(throws: PatchVariationError.malformed) { try PatchVariationExtension.read(from: patch) }
            #expect(throws: PatchVariationError.malformed) {
                try PatchVariationExtension.write(PatchVariationSet(), to: patch)
            }
        }
        let good = Self.patch(extensions: [Self.key: stored()])
        #expect(try PatchVariationExtension.read(from: good).variations.map(\.id) == [Self.verse])
    }

    @Test
    func absentAndEmptySets() throws {
        let bare = Self.patch()
        #expect(try PatchVariationExtension.content(of: bare) == .absent)
        #expect(try PatchVariationExtension.read(from: bare) == PatchVariationSet())
        #expect(try PatchVariationExtension.write(PatchVariationSet(), to: bare) == bare)
        let foreign = Self.patch(extensions: ["other": .int(1)])
        let filled = try PatchVariationExtension.write(PatchVariationSet(variations: Self.numbered(1)), to: bare)
        #expect(filled.extensions?.keys.sorted() == [Self.key])
        #expect(try PatchVariationExtension.write(PatchVariationSet(), to: filled) == bare)
        let both = try PatchVariationExtension.write(PatchVariationSet(variations: Self.numbered(1)), to: foreign)
        #expect(try PatchVariationExtension.write(PatchVariationSet(), to: both) == foreign)
        let emptyBag = Self.patch(extensions: [:])
        #expect(try PatchVariationExtension.write(PatchVariationSet(), to: emptyBag).extensions == [:])
        let annotated = PatchVariationSet(extensions: ["keep": .null])
        let kept = try PatchVariationExtension.write(annotated, to: bare)
        #expect(try PatchVariationExtension.read(from: kept) == annotated)
    }

    @Test
    func variationCountPins() throws {
        let atLimit = PatchVariationSet(variations: try Self.numbered(128))
        let written = try PatchVariationExtension.write(atLimit, to: Self.patch())
        #expect(try PatchVariationExtension.read(from: written).variations.count == 128)
        let over = PatchVariationSet(variations: try Self.numbered(129))
        let refusal = PatchVariationError.tooManyVariations(count: 129, maximum: 128)
        #expect(throws: refusal) { try PatchVariationExtension.write(over, to: Self.patch()) }
        let stored = Self.patch(extensions: [Self.key: try Self.raw(over)])
        #expect(throws: refusal) { try PatchVariationExtension.read(from: stored) }
    }

    @Test
    func deltaCountPins() throws {
        let deltas = try (0...4096).map { Self.delta(try ParameterID("p.\($0)"), 0, .normalized) }
        let atLimit = PatchVariationSet(variations: [
            PatchVariation(id: Self.verse, label: "Verse", deltas: Array(deltas.prefix(4096)))
        ])
        #expect(throws: Never.self) { try atLimit.validateStructure() }
        let written = try PatchVariationExtension.write(atLimit, to: Self.patch())
        #expect(try PatchVariationExtension.read(from: written) == atLimit)
        let over = PatchVariationSet(variations: [PatchVariation(id: Self.verse, label: "Verse", deltas: deltas)])
        let refusal = PatchVariationError.tooManyDeltas(Self.verse, count: 4097, maximum: 4096)
        #expect(throws: refusal) { try PatchVariationExtension.write(over, to: Self.patch()) }
        #expect(throws: refusal) {
            try PatchVariationExtension.read(from: Self.patch(extensions: [Self.key: Self.raw(over)]))
        }
    }

    @Test
    func labelPins() throws {
        let accepted = [
            String(repeating: "a", count: 256), String(repeating: "\u{E9}", count: 128), "V", "Verse 2 \u{2014} lead",
            "e\u{301}", "a\u{00A0}b"
        ]
        let refused = [
            String(repeating: "a", count: 257), String(repeating: "\u{E9}", count: 128) + "a", "", " a", "a ",
            "a\u{00A0}", "\u{3000}a", "a\nb", "a\tb", "a\u{7}b", "a\u{7F}b", "a\u{200B}b", "a\u{FEFF}b",
            "a\u{202E}b", "a\u{2028}b", "a\u{2029}b"
        ]
        for label in accepted {
            #expect(PatchVariationLimits.isValidLabel(label), "\(label.unicodeScalars.map(\.value))")
        }
        for label in refused {
            let set = PatchVariationSet(variations: [PatchVariation(id: Self.verse, label: label)])
            #expect(throws: PatchVariationError.invalidLabel(Self.verse)) { try set.validateStructure() }
        }
    }

    @Test
    func duplicatesRefuseAtTheFirstInDocumentOrder() throws {
        let ids = try ["a", "b", "a", "b"].map { try PatchVariationID($0) }
        let repeated = PatchVariationSet(variations: ids.map { PatchVariation(id: $0, label: "L") })
        #expect(throws: PatchVariationError.duplicateVariation(try PatchVariationID("a"))) {
            try PatchVariationExtension.write(repeated, to: Self.patch())
        }
        let twice = PatchVariation(id: Self.chorus, label: "Chorus", deltas: [
            Self.delta(Self.mix, 0.1, .normalized), Self.delta(Self.gain, 0, .decibels),
            Self.delta(Self.mix, 0.2, .normalized)
        ])
        #expect(throws: PatchVariationError.duplicateDelta(Self.chorus, Self.mix)) {
            try PatchVariationSet(variations: [twice]).validateStructure()
        }
        let ordered = PatchVariationSet(variations: [PatchVariation(id: Self.verse, label: " bad"), twice])
        #expect(throws: PatchVariationError.invalidLabel(Self.verse)) { try ordered.validateStructure() }
    }
}
