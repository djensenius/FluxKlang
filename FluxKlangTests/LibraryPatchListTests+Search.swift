//
//  LibraryPatchListTests+Search.swift
//  FluxKlangTests
//
//  Search of the Library patch list (#99 LIB2) and the fixtures the root suite shares: whole-term substring match on
//  name, kind and detail text, case-insensitive, every term must match, a variation matching through its patch, the
//  kept variations of a filtered row, no match on ids, and `filtered(by: a).filtered(by: b)` equal to
//  `filtered(by: a + " " + b)`.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension LibraryPatchListTests {
    /// Sorted: Bridge, Broken, Chorus, Newer, Verse. Chorus and Verse both hold a variation with the id `v.soft`.
    static func searchList() throws -> LibraryPatchList {
        let verse = [Fixture.variation("v.soft", "Soft"), Fixture.variation("v.wet", "Verse, wetter", deltas: 2)]
        let chorus = [Fixture.variation("v.wide", "Wide", deltas: 1), Fixture.variation("v.soft", "Soft", deltas: 2)]
        return try LibraryPatchList.make(
            patches: [
                Fixture.patch("patch.verse", "Verse", verse), Fixture.patch("patch.chorus", "Chorus", chorus),
                Fixture.patch("patch.bridge", "Bridge"),
                Fixture.stored("patch.newer", "Newer", .object(["version": .int(2)])),
                Fixture.stored("patch.broken", "Broken", .string("x"))
            ],
            prepared: [Fixture.preparedID("patch.chorus", "v.wide")]
        )
    }

    @Test func searchMatchesPatchLabelAndVariationLabelIgnoringCase() throws {
        let list = try Self.searchList()
        #expect(list.rows.map(\.title) == ["Bridge", "Broken", "Chorus", "Newer", "Verse"])
        #expect(list.filtered(by: "chor").rows.map(\.title) == ["Chorus"])
        #expect(list.filtered(by: "CHOR").rows.map(\.title) == ["Chorus"])
        let wetter = list.filtered(by: "WETTER").rows
        #expect(wetter.map(\.title) == ["Verse"])
        #expect(wetter.map { $0.variations.map(\.title) } == [["Verse, wetter"]])
        #expect(list.filtered(by: "wide").rows.map { $0.variations.map(\.title) } == [["Wide"]])
    }

    @Test func searchMatchesKindTextAndDetailText() throws {
        let list = try Self.searchList()
        let withVariationText = list.filtered(by: "variation").rows
        #expect(withVariationText.map(\.title) == ["Bridge", "Broken", "Chorus", "Verse"])
        #expect(withVariationText.map(\.variations.count) == [0, 0, 2, 2])
        let prepared = list.filtered(by: "prepared").rows
        #expect(prepared.map(\.title) == ["Chorus"])
        #expect(prepared.map { $0.variations.map(\.title) } == [["Wide"]])
        let deltas = list.filtered(by: "delta").rows
        #expect(deltas.map(\.title) == ["Chorus", "Verse"])
        #expect(deltas.map { $0.variations.map(\.title) } == [["Wide", "Soft"], ["Soft", "Verse, wetter"]])
        #expect(list.filtered(by: "newer").rows.map(\.title) == ["Newer"])
        #expect(list.filtered(by: "could not").rows.map(\.title) == ["Broken"])
    }

    @Test func searchRequiresEveryTermAndSplitsOnWhitespace() throws {
        let list = try Self.searchList()
        let expected = list.filtered(by: "soft chorus")
        #expect(expected.rows.map(\.title) == ["Chorus"])
        #expect(expected.rows.map { $0.variations.map(\.title) } == [["Soft"]])
        #expect(list.filtered(by: "soft\tchorus") == expected)
        #expect(list.filtered(by: "chorus\nsoft ") == expected)
        #expect(list.filtered(by: "patch 2").rows.map(\.title) == ["Chorus", "Verse"])
        #expect(list.filtered(by: "chorus wetter").rows.isEmpty)
        #expect(list.filtered(by: "zzz").rows.isEmpty)
    }

    @Test func aBlankQueryReturnsTheListUnchanged() throws {
        let list = try Self.searchList()
        for query in ["", " ", "  \t\n "] {
            #expect(list.filtered(by: query) == list)
        }
    }

    @Test func aPatchOnlyMatchKeepsAllVariationsAndAVariationOnlyMatchKeepsTheParent() throws {
        let list = try Self.searchList()
        let patchOnly = try #require(list.filtered(by: "chorus").rows.first)
        #expect(patchOnly.variations.map(\.title) == ["Wide", "Soft"])
        let variationOnly = list.filtered(by: "wide")
        let parent = try #require(variationOnly.rows.first)
        #expect(variationOnly.rows.count == 1)
        #expect(parent.title == "Chorus")
        #expect(parent.detailText == "2 variations")
        #expect(parent.variations.map(\.title) == ["Wide"])
        #expect(parent.accessibilityLabel == "Chorus, Patch, 2 variations")
    }

    @Test func aQueryNamingThePatchAndAVariationKeepsOnlyThatVariation() throws {
        let list = try Self.searchList()
        let verse = list.filtered(by: "verse soft")
        #expect(verse.rows.map(\.title) == ["Verse"])
        #expect(verse.rows.map { $0.variations.map(\.id.variation.rawValue) } == [["v.soft"]])
        #expect(verse.rows.map(\.detailText) == ["2 variations"])
        let both = list.filtered(by: "verse wetter")
        #expect(both.rows.map { $0.variations.map(\.title) } == [["Verse, wetter"]])
    }

    @Test func searchNeverMatchesAnId() throws {
        let list = try Self.searchList()
        for query in ["patch.verse", "patch.", "v.soft", "v.wet", "par.p0", "par.", "graph.main", "v."] {
            #expect(list.filtered(by: query).rows.isEmpty)
        }
    }

    @Test func filteringComposesWithTheQueriesJoinedByASpace() throws {
        let list = try Self.searchList()
        let pairs = [
            ("verse", "soft"), ("soft", "verse"), ("chorus", "wide"), ("variation", "delta"), ("patch", "wetter"),
            ("verse", "zzz"), ("newer", "patch"), ("2", "delta"), ("", "soft"), ("soft", ""), ("could", "not"),
            ("prepared", "wide"), ("patch", "prepared"), ("variation", "variation"), ("e", "o")
        ]
        for (first, second) in pairs {
            #expect(list.filtered(by: first).filtered(by: second) == list.filtered(by: first + " " + second))
        }
        let patchThenVariation = list.filtered(by: "patch").filtered(by: "wetter")
        #expect(patchThenVariation.rows.map { $0.variations.map(\.title) } == [["Verse, wetter"]])
    }

    @Test func filteringKeepsRowOrderAndVariationOrder() throws {
        let list = try Self.searchList()
        let titles = list.rows.map(\.title)
        for query in ["e", "o", "variation", "patch", "s"] {
            let kept = list.filtered(by: query).rows.map(\.title)
            #expect(kept == titles.filter(kept.contains))
        }
        let soft = list.filtered(by: "e").rows.first { $0.title == "Verse" }
        #expect(soft?.variations.map(\.title) == ["Soft", "Verse, wetter"])
    }
}

extension LibraryPatchListTests {
    /// Fixtures built only through the production API. Internal, not private:
    /// the root suite file uses them too.
    enum Fixture {
        static let graph = GraphID(validated: "graph.main")
        static let parameters = [
            ParameterID(validated: "par.p0"), ParameterID(validated: "par.p1"), ParameterID(validated: "par.p2")
        ]

        static func patchID(_ id: StaticString) -> PatchID { PatchID(validated: id) }

        static func variationID(_ id: StaticString) -> PatchVariationID { PatchVariationID(validated: id) }

        static func preparedID(_ patch: StaticString, _ variation: StaticString) -> LibraryVariationID {
            LibraryVariationID(patch: patchID(patch), variation: variationID(variation))
        }

        /// A variation with `deltas` deltas (at most three).
        static func variation(_ id: StaticString, _ label: String, deltas: Int = 0) -> PatchVariation {
            PatchVariation(id: variationID(id), label: label, deltas: parameters.prefix(deltas).map {
                PatchParameterDelta(parameter: $0, value: ParameterValue(value: 0.5, unit: .normalized))
            })
        }

        static func numbered(_ count: Int) throws -> [PatchVariation] {
            try (0..<count).map { try PatchVariation(id: PatchVariationID("v.\($0)"), label: "V \($0)") }
        }

        /// A patch whose variations are stored through `PatchVariationExtension.write`; nil stores nothing.
        static func patch(
            _ id: StaticString, _ label: String, _ variations: [PatchVariation]? = nil
        ) throws -> ProjectPatch {
            let patch = ProjectPatch(id: patchID(id), label: label, graph: graph)
            guard let variations else { return patch }
            return try PatchVariationExtension.write(PatchVariationSet(variations: variations), to: patch)
        }

        /// A patch whose variation key holds exactly `value`.
        static func stored(_ id: StaticString, _ label: String, _ value: JSONValue) -> ProjectPatch {
            ProjectPatch(
                id: patchID(id), label: label, graph: graph, extensions: [PatchVariationExtension.key: value]
            )
        }

        static func raw(_ set: PatchVariationSet) throws -> JSONValue {
            try ContractCoding.decode(JSONValue.self, from: ContractCoding.makeEncoder().encode(set))
        }

        static func permutations<Element>(_ items: [Element]) -> [[Element]] {
            guard items.count > 1 else { return [items] }
            return items.indices.flatMap { index -> [[Element]] in
                var rest = items
                let head = rest.remove(at: index)
                return permutations(rest).map { [head] + $0 }
            }
        }
    }
}
