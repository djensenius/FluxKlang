//
//  LibraryMediaListTests.swift
//  FluxKlangTests
//
//  The Library "Charts & media" section as a value (#99 LIB4): rows built from the project's assets, the status and
//  Locate action of a stale bookmark, the kind words, the byte order of rows, nameless rows, the caller's available
//  set, duplicate asset ids, determinism, the accessibility labels and the pinned fixed texts. Search and the
//  Templates placeholder are in LibraryMediaListTests+Search.swift. The list is a pure value: nothing here opens a
//  view, a file or a clock.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Library media list", .productionAccessAudit)
struct LibraryMediaListTests {
    @Test func aStaleDocumentRowReadsAsTheDocMocksIt() throws {
        let list = try LibraryMediaList.make(
            assets: [Fixture.asset("a.verse", "Verse chart", .document)], availableContent: []
        )
        let row = try #require(list.rows.first)
        #expect(list.rows.count == 1)
        #expect(row.id == Fixture.id("a.verse"))
        #expect(row.title == "Verse chart")
        #expect(row.kindText == "Chart")
        #expect(row.media == .document)
        #expect(row.status == .staleBookmark)
        #expect(row.statusText == "Stale bookmark")
        #expect(row.secondaryText == nil)
        #expect(row.actions.map(\.kind) == [.locate])
        #expect(row.actions.map(\.title) == ["Locate..."])
        #expect(row.actions.map(\.isEnabled) == [true])
        #expect(row.actions.map(\.disabledReason) == [nil])
        #expect(row.accessibilityLabel == "Verse chart, Chart, Stale bookmark")
    }

    @Test func anAvailableRowHasNoAction() throws {
        let list = try Fixture.list()
        let row = try #require(list.rows.first { $0.id == Fixture.id("a.bridge") })
        #expect(row.status == .available)
        #expect(row.statusText == "Available")
        #expect(row.actions.isEmpty)
        #expect(row.accessibilityLabel == "Bridge chart, Chart, Available")
    }

    @Test func kindAndStatusWordsFollowTheMediaAndTheAvailableSet() throws {
        let rows = try Fixture.list().rows
        #expect(rows.map(\.kindText) == ["MIDI", "Chart", "Audio", "Audio", "Chart", "Chart"])
        #expect(
            rows.map(\.statusText)
                == ["Available", "Available", "Available", "Stale bookmark", "Stale bookmark", "Stale bookmark"]
        )
    }

    @Test func noAssetsHaveNoRows() throws {
        #expect(try LibraryMediaList.make(assets: [], availableContent: []).rows.isEmpty)
    }

    @Test func rowsAreOrderedByTitleBytes() throws {
        #expect(
            try Fixture.list().rows.map(\.title)
                == ["Arp", "Bridge chart", "Click track", "Drum loop", "Unnamed asset", "Verse chart"]
        )
    }

    @Test func caseTiesFallBackToExactTitleThenId() throws {
        let cases = [
            Fixture.asset("a.1", "beta", .audio), Fixture.asset("a.2", "alpha", .audio),
            Fixture.asset("a.3", "Alpha", .audio), Fixture.asset("a.4", "ALPHA", .audio),
            Fixture.asset("a.7", "Zulu", .audio)
        ]
        let rows = try LibraryMediaList.make(assets: cases, availableContent: []).rows
        #expect(rows.map(\.title) == ["ALPHA", "Alpha", "alpha", "beta", "Zulu"])
        let same = [Fixture.asset("a.6", "same", .midi), Fixture.asset("a.5", "same", .midi)]
        let tied = try LibraryMediaList.make(assets: same, availableContent: []).rows
        #expect(tied.map(\.id.rawValue) == ["a.5", "a.6"])
    }

    @Test func nonAsciiTitlesSortByUTF8BytesNotByLocale() throws {
        let assets = [
            Fixture.asset("a.1", "\u{00C9}dith", .audio), Fixture.asset("a.2", "Zed", .audio),
            Fixture.asset("a.3", "Eve", .audio)
        ]
        let rows = try LibraryMediaList.make(assets: assets, availableContent: []).rows
        #expect(rows.map(\.title) == ["Eve", "Zed", "\u{00C9}dith"])
    }

    @Test func canonicallyEqualTitlesSortByTheirBytesNotByTheirId() throws {
        let assets = [Fixture.asset("a.1", "\u{00E9}", .audio), Fixture.asset("a.2", "e\u{0301}", .audio)]
        let rows = try LibraryMediaList.make(assets: assets, availableContent: []).rows
        #expect(rows.map(\.id.rawValue) == ["a.2", "a.1"])
    }

    @Test func statusNeverRanksARow() throws {
        let assets = [Fixture.asset("a.1", "Beta", .document), Fixture.asset("a.2", "Alpha", .document)]
        let rows = try LibraryMediaList.make(assets: assets, availableContent: [Fixture.id("a.2")]).rows
        #expect(rows.map(\.title) == ["Alpha", "Beta"])
        #expect(rows.map(\.status) == [.available, .staleBookmark])
    }

    @Test func aBlankLabelReadsUnnamedAndKeepsTheIdAsSecondaryText() throws {
        for label in ["", "   ", "\t"] {
            let list = try LibraryMediaList.make(
                assets: [Fixture.asset("a.blank", label, .document)], availableContent: []
            )
            let row = try #require(list.rows.first)
            #expect(row.title == "Unnamed asset")
            #expect(row.secondaryText == "a.blank")
            #expect(row.accessibilityLabel == "Unnamed asset, Chart, Stale bookmark")
        }
        let padded = try LibraryMediaList.make(
            assets: [Fixture.asset("a.pad", " Verse ", .document)], availableContent: []
        )
        let row = try #require(padded.rows.first)
        #expect(row.title == " Verse ")
        #expect(row.secondaryText == nil)
    }

    @Test func anAvailableIdWithNoAssetIsIgnoredAndRepeatsChangeNothing() throws {
        let assets = [Fixture.asset("a.verse", "Verse chart", .document)]
        let base = try LibraryMediaList.make(assets: assets, availableContent: [])
        let extra = try LibraryMediaList.make(assets: assets, availableContent: [Fixture.id("a.other")])
        #expect(extra == base)
        let ids: [AssetID] = [Fixture.id("a.verse"), Fixture.id("a.verse")]
        let twice = try LibraryMediaList.make(assets: assets, availableContent: Set(ids))
        let once = try LibraryMediaList.make(assets: assets, availableContent: [Fixture.id("a.verse")])
        #expect(twice == once)
        #expect(once.rows.map(\.status) == [.available])
    }

    @Test func aDuplicateAssetIdIsRefusedAtTheFirstRepeat() {
        let doubled = [
            Fixture.asset("a.x", "X", .document), Fixture.asset("a.y", "Y", .document),
            Fixture.asset("a.x", "X", .document), Fixture.asset("a.y", "Y", .document)
        ]
        #expect(throws: LibraryMediaListRefusal.duplicateAsset(Fixture.id("a.x"))) {
            try LibraryMediaList.make(assets: doubled, availableContent: [])
        }
        let reversed = [
            Fixture.asset("a.b", "B", .document), Fixture.asset("a.a", "A", .document),
            Fixture.asset("a.b", "B", .document), Fixture.asset("a.a", "A", .document)
        ]
        #expect(throws: LibraryMediaListRefusal.duplicateAsset(Fixture.id("a.b"))) {
            try LibraryMediaList.make(assets: reversed, availableContent: [])
        }
        let crossed = [
            Fixture.asset("a.x", "X", .document), Fixture.asset("a.y", "Y", .document),
            Fixture.asset("a.y", "Y", .document), Fixture.asset("a.x", "X", .document)
        ]
        #expect(throws: LibraryMediaListRefusal.duplicateAsset(Fixture.id("a.y"))) {
            try LibraryMediaList.make(assets: crossed, availableContent: [])
        }
        let differing = [Fixture.asset("a.d", "One", .audio), Fixture.asset("a.d", "Two", .midi)]
        #expect(throws: LibraryMediaListRefusal.duplicateAsset(Fixture.id("a.d"))) {
            try LibraryMediaList.make(assets: differing, availableContent: [])
        }
    }

    @Test func inputOrderDoesNotChangeTheList() throws {
        let forward = try LibraryMediaList.make(assets: Fixture.assets, availableContent: Fixture.available)
        let backward = try LibraryMediaList.make(
            assets: Fixture.assets.reversed(), availableContent: Fixture.available
        )
        #expect(forward == backward)
        #expect(forward.rows.map(\.id.rawValue) == backward.rows.map(\.id.rawValue))
    }

    @Test func fixedTextsArePinned() {
        let texts: [(String, String)] = [
            (LibraryMediaList.title, "Charts & media"),
            (LibraryMediaText.unnamedAsset, "Unnamed asset"),
            (LibraryMediaText.staleBookmark, "Stale bookmark"),
            (LibraryMediaText.available, "Available"),
            (LibraryMediaText.locate, "Locate..."),
            (LibraryMediaText.kind(.document), "Chart"),
            (LibraryMediaText.kind(.audio), "Audio"),
            (LibraryMediaText.kind(.midi), "MIDI"),
            (LibraryMediaText.templatesTitle, "Templates"),
            (LibraryMediaText.templatesPlaceholder, "(none yet)")
        ]
        for (actual, expected) in texts {
            #expect(actual == expected)
        }
    }
}
