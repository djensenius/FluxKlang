//
//  LibraryPatchListTests.swift
//  FluxKlangTests
//
//  The Library "Patches & Variations" section as a value (#99 LIB2): rows built from the project's patches, the
//  variations nested in stored order, the status of a newer or unreadable set, the byte order of rows, duplicate
//  patch ids, the caller's prepared set, the accessibility labels and the pinned fixed texts. Search is in
//  LibraryPatchListTests+Search.swift. The list is a pure value: nothing here opens a view, a file or a clock.
//

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
struct LibraryPatchListTests {
    @Test func noPatchesHaveNoRows() throws {
        #expect(try LibraryPatchList.make(patches: []).rows.isEmpty)
    }

    @Test func aPatchWithNoVariationKeyIsReady() throws {
        let list = try LibraryPatchList.make(patches: [Fixture.patch("patch.verse", "Verse")])
        let row = try #require(list.rows.first)
        #expect(list.rows.count == 1)
        #expect(row.id == Fixture.patchID("patch.verse"))
        #expect(row.title == "Verse")
        #expect(row.kindText == "Patch")
        #expect(row.status == .ready)
        #expect(row.detailText == "No variations")
        #expect(row.variations.isEmpty)
        #expect(row.actions.map(\.kind) == [.recall, .open])
        #expect(row.actions.map(\.title) == ["Recall", "Open"])
        #expect(row.actions.map(\.isEnabled) == [true, true])
        #expect(row.actions.map(\.disabledReason) == [nil, nil])
    }

    @Test func variationsKeepTheirStoredOrderAndLabels() throws {
        let stored = [
            Fixture.variation("v.zulu", "Zulu"), Fixture.variation("v.alpha", "Alpha"),
            Fixture.variation("v.mike", "Mike")
        ]
        let patch = try Fixture.patch("patch.verse", "Verse", stored)
        let row = try #require(try LibraryPatchList.make(patches: [patch]).rows.first)
        #expect(row.status == .ready)
        #expect(row.detailText == "3 variations")
        #expect(row.variations.map(\.title) == ["Zulu", "Alpha", "Mike"])
        #expect(row.variations.map(\.id.variation.rawValue) == ["v.zulu", "v.alpha", "v.mike"])
        #expect(row.variations.map(\.id.patch.rawValue) == ["patch.verse", "patch.verse", "patch.verse"])
    }

    @Test func oneVariationReadsSingular() throws {
        let patch = try Fixture.patch("patch.verse", "Verse", [Fixture.variation("v.a", "Soft")])
        let row = try #require(try LibraryPatchList.make(patches: [patch]).rows.first)
        #expect(row.detailText == "1 variation")
        #expect(row.variations.count == 1)
    }

    @Test func variationRowsShowTheirDeltaCountAndOnlyRecall() throws {
        let stored = [
            Fixture.variation("v.none", "None"), Fixture.variation("v.one", "One", deltas: 1),
            Fixture.variation("v.two", "Two", deltas: 2)
        ]
        let patch = try Fixture.patch("patch.verse", "Verse", stored)
        let row = try #require(try LibraryPatchList.make(patches: [patch]).rows.first)
        #expect(row.variations.map(\.deltaCount) == [0, 1, 2])
        #expect(row.variations.map(\.detailText) == ["No deltas", "1 delta", "2 deltas"])
        #expect(row.variations.map(\.kindText) == ["Variation", "Variation", "Variation"])
        #expect(row.variations.map(\.isPrepared) == [false, false, false])
        for variation in row.variations {
            #expect(variation.actions.map(\.kind) == [.recall])
            #expect(variation.actions.map(\.title) == ["Recall"])
            #expect(variation.actions.map(\.isEnabled) == [true])
        }
    }

    @Test func blankLabelsReadUnnamedAndPaddedLabelsAreKeptExactly() throws {
        let patches = try [
            Fixture.patch("patch.a", ""), Fixture.patch("patch.b", "   "), Fixture.patch("patch.c", "\t"),
            Fixture.patch("patch.d", " Verse ")
        ]
        let list = try LibraryPatchList.make(patches: patches)
        let titles = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.id.rawValue, $0.title) })
        #expect(titles == [
            "patch.a": "Unnamed patch", "patch.b": "Unnamed patch", "patch.c": "Unnamed patch",
            "patch.d": " Verse "
        ])
        let unnamed = list.rows.first { $0.id.rawValue == "patch.a" }
        #expect(unnamed?.accessibilityLabel == "Unnamed patch, Patch, No variations")
    }

    @Test func rowsSortCaseInsensitivelyThenByExactBytesThenById() throws {
        let patches = try [
            Fixture.patch("patch.1", "beta"), Fixture.patch("patch.2", "alpha"), Fixture.patch("patch.3", "Alpha"),
            Fixture.patch("patch.4", "ALPHA"), Fixture.patch("patch.6", "same"), Fixture.patch("patch.5", "same"),
            Fixture.patch("patch.7", "Zulu")
        ]
        let list = try LibraryPatchList.make(patches: patches)
        #expect(list.rows.map(\.title) == ["ALPHA", "Alpha", "alpha", "beta", "same", "same", "Zulu"])
        #expect(list.rows.map(\.id.rawValue) == [
            "patch.4", "patch.3", "patch.2", "patch.1", "patch.5", "patch.6", "patch.7"
        ])
    }

    @Test func nonASCIITitlesSortAfterASCIITitlesNotByLocale() throws {
        let patches = try [
            Fixture.patch("patch.1", "\u{00C9}dith"), Fixture.patch("patch.2", "Zed"), Fixture.patch("patch.3", "Eve")
        ]
        let list = try LibraryPatchList.make(patches: patches)
        #expect(list.rows.map(\.title) == ["Eve", "Zed", "\u{00C9}dith"])
    }

    @Test func orderNeverDependsOnTheInputOrder() throws {
        let patches = try [
            Fixture.patch("patch.1", "beta"), Fixture.patch("patch.2", "Alpha"), Fixture.patch("patch.3", "alpha"),
            Fixture.patch("patch.4", "same"), Fixture.patch("patch.5", "same")
        ]
        let expected = try LibraryPatchList.make(patches: patches)
        let orders = Fixture.permutations(patches)
        #expect(orders.count == 120)
        for order in orders {
            #expect(try LibraryPatchList.make(patches: order) == expected)
        }
    }

    @Test func storedVariationOrderIsNotSortedWithThePatchOrder() throws {
        let stored = [Fixture.variation("v.b", "b"), Fixture.variation("v.a", "A"), Fixture.variation("v.c", "C")]
        let list = try LibraryPatchList.make(patches: [
            Fixture.patch("patch.2", "Beta", stored), Fixture.patch("patch.1", "Alpha", stored.reversed())
        ])
        #expect(list.rows.map(\.title) == ["Alpha", "Beta"])
        #expect(list.rows.map { $0.variations.map(\.title) } == [["C", "A", "b"], ["b", "A", "C"]])
    }

    @Test func duplicatePatchIDsAreRefusedWithTheFirstRepeat() throws {
        let patches = try [
            Fixture.patch("patch.a", "One"), Fixture.patch("patch.b", "Two"), Fixture.patch("patch.b", "Other label"),
            Fixture.patch("patch.a", "Three")
        ]
        #expect(throws: LibraryPatchListRefusal.duplicatePatch(Fixture.patchID("patch.b"))) {
            try LibraryPatchList.make(patches: patches)
        }
        #expect(throws: LibraryPatchListRefusal.duplicatePatch(Fixture.patchID("patch.a"))) {
            try LibraryPatchList.make(patches: [patches[0], patches[3]])
        }
    }

    @Test func aNewerVersionSetListsNoVariationsAndDisablesRecall() throws {
        let hidden = JSONValue.object(["id": .string("v.hidden"), "label": .string("Hidden"), "deltas": .array([])])
        let stored = JSONValue.object(["version": .int(2), "variations": .array([hidden])])
        let patch = Fixture.stored("patch.future", "Future", stored)
        let row = try #require(try LibraryPatchList.make(patches: [patch]).rows.first)
        #expect(row.status == .newerVersion(2))
        #expect(row.title == "Future")
        #expect(row.variations.isEmpty)
        #expect(row.detailText == "Contains fields from a newer version (kept)")
        #expect(row.status.reasonText == "Contains fields from a newer version (kept)")
        #expect(row.actions.map(\.kind) == [.recall, .open])
        #expect(row.actions.map(\.isEnabled) == [false, true])
        #expect(row.actions.map(\.disabledReason) == ["Contains fields from a newer version (kept)", nil])
        #expect(patch.extensions?[PatchVariationExtension.key] == stored)
    }

    @Test func unreadableSetsCarryTheTypedErrorAndListNoVariations() throws {
        let twins = [Fixture.variation("v.a", "A"), Fixture.variation("v.a", "B")]
        let duplicate = try Fixture.raw(PatchVariationSet(variations: twins))
        let emptyLabel = try Fixture.raw(PatchVariationSet(variations: [Fixture.variation("v.a", "")]))
        let tooMany = try Fixture.raw(PatchVariationSet(variations: Fixture.numbered(129)))
        let cases: [(JSONValue, PatchVariationError)] = [
            (.string("not an object"), .malformed),
            (.object(["variations": .array([])]), .malformed),
            (.object(["version": .int(0), "variations": .array([])]), .malformed),
            (tooMany, .tooManyVariations(count: 129, maximum: 128)),
            (duplicate, .duplicateVariation(Fixture.variationID("v.a"))),
            (emptyLabel, .invalidLabel(Fixture.variationID("v.a")))
        ]
        for (value, error) in cases {
            let list = try LibraryPatchList.make(patches: [Fixture.stored("patch.bad", "Bad", value)])
            let row = try #require(list.rows.first)
            #expect(row.status == .unreadable(error))
            #expect(row.variations.isEmpty)
            #expect(row.detailText == "Variations could not be read")
            #expect(row.actions.map(\.isEnabled) == [false, true])
            #expect(row.actions.map(\.disabledReason) == ["Variations could not be read", nil])
            #expect(row.title == "Bad")
        }
    }

    @Test func theSameVariationIDUnderTwoPatchesGivesTwoRows() throws {
        let shared = [Fixture.variation("v.soft", "Soft")]
        let list = try LibraryPatchList.make(
            patches: [Fixture.patch("patch.a", "A", shared), Fixture.patch("patch.b", "B", shared)],
            prepared: [LibraryVariationID(patch: Fixture.patchID("patch.a"), variation: Fixture.variationID("v.soft"))]
        )
        let variations = list.rows.flatMap(\.variations)
        #expect(variations.count == 2)
        #expect(Set(variations.map(\.id)).count == 2)
        #expect(variations.map(\.id.patch.rawValue) == ["patch.a", "patch.b"])
        #expect(variations.map(\.isPrepared) == [true, false])
    }

    @Test func preparedMarksOnlyTheListedVariations() throws {
        let stored = [Fixture.variation("v.none", "None"), Fixture.variation("v.two", "Two", deltas: 2)]
        let patches = try [Fixture.patch("patch.a", "A", stored), Fixture.patch("patch.n", "N", nil)]
        let plain = try LibraryPatchList.make(patches: patches)
        let prepared: Set = [
            Fixture.preparedID("patch.a", "v.none"), Fixture.preparedID("patch.a", "v.two"),
            Fixture.preparedID("patch.a", "v.absent"), Fixture.preparedID("patch.missing", "v.none"),
            Fixture.preparedID("patch.n", "v.none")
        ]
        let list = try LibraryPatchList.make(patches: patches, prepared: prepared)
        try #require(list.rows.count == 2)
        let row = try #require(list.rows.first)
        #expect(row.variations.map(\.isPrepared) == [true, true])
        #expect(row.variations.map(\.detailText) == ["No deltas, prepared", "2 deltas, prepared"])
        #expect(row.detailText == "2 variations")
        #expect(!list.rows[1].detailText.contains("prepared"))
        #expect(list.rows.map(\.title) == plain.rows.map(\.title))
        #expect(list.rows.map(\.actions) == plain.rows.map(\.actions))
        #expect(list.rows.map { $0.variations.map(\.actions) } == plain.rows.map { $0.variations.map(\.actions) })
    }

    @Test func preparedIDsOfPatchesThatAreNotReadyAreIgnored() throws {
        let stored = JSONValue.object(["version": .int(2)])
        let prepared: Set = [Fixture.preparedID("patch.future", "v.a"), Fixture.preparedID("patch.bad", "v.a")]
        let list = try LibraryPatchList.make(
            patches: [Fixture.stored("patch.future", "Future", stored), Fixture.stored("patch.bad", "Bad", .null)],
            prepared: prepared
        )
        #expect(list.rows.count == 2)
        #expect(list.rows.allSatisfy { $0.variations.isEmpty })
        #expect(list == (try LibraryPatchList.make(patches: [
            Fixture.stored("patch.future", "Future", stored), Fixture.stored("patch.bad", "Bad", .null)
        ])))
    }

    @Test func accessibilityLabelsReadTitleKindAndDetail() throws {
        let stored = [Fixture.variation("v.wet", "Verse, wetter", deltas: 2), Fixture.variation("v.dry", "Dry")]
        let future = Fixture.stored("patch.future", "Future", .object(["version": .int(3)]))
        let broken = Fixture.stored("patch.broken", "Broken", .array([]))
        let list = try LibraryPatchList.make(
            patches: [Fixture.patch("patch.verse", "Verse", stored), future, broken],
            prepared: [Fixture.preparedID("patch.verse", "v.wet")]
        )
        #expect(list.rows.map(\.accessibilityLabel) == [
            "Broken, Patch, Variations could not be read",
            "Future, Patch, Contains fields from a newer version (kept)",
            "Verse, Patch, 2 variations"
        ])
        let verse = try #require(list.rows.last)
        #expect(verse.variations.map(\.accessibilityLabel) == [
            "Verse, wetter, Variation, 2 deltas, prepared", "Dry, Variation, No deltas"
        ])
    }

    @Test func fixedTextsArePinnedInOnePlace() throws {
        #expect(LibraryPatchText.patchKind == "Patch")
        #expect(LibraryPatchText.variationKind == "Variation")
        #expect(LibraryPatchText.unnamedPatchTitle == "Unnamed patch")
        #expect([0, 1, 2, 10].map(LibraryPatchText.variationCount) == [
            "No variations", "1 variation", "2 variations", "10 variations"
        ])
        #expect([0, 1, 2].map { LibraryPatchText.deltaCount($0, isPrepared: false) } == [
            "No deltas", "1 delta", "2 deltas"
        ])
        #expect([0, 1, 2].map { LibraryPatchText.deltaCount($0, isPrepared: true) } == [
            "No deltas, prepared", "1 delta, prepared", "2 deltas, prepared"
        ])
        #expect(LibraryPatchStatus.ready.reasonText == nil)
        #expect(LibraryPatchStatus.newerVersion(2).reasonText == "Contains fields from a newer version (kept)")
        #expect(LibraryPatchStatus.unreadable(.malformed).reasonText == "Variations could not be read")
        #expect(LibraryPatchActionKind.allCases == [.recall, .open])
        #expect(LibraryPatchAction.recall.title == "Recall")
        #expect(LibraryPatchAction.recall.kind == .recall)
        #expect(LibraryPatchAction.recall.isEnabled)
        let open = try #require(LibraryPatchAction.actions(for: .ready).last)
        #expect(open.kind == .open)
        #expect(open.title == "Open")
        #expect(open.disabledReason == nil)
    }
}
