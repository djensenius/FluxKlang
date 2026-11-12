//
//  LibraryMediaListTests+Search.swift
//  FluxKlangTests
//
//  Search of the Library "Charts & media" section (#99 LIB4; library-inspector.md "Search filters by name, kind and
//  status"), the Templates placeholder and the shared fixture. Rows, order and refusals are in
//  LibraryMediaListTests.swift.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension LibraryMediaListTests {
    @Test func searchByStatusWord() throws {
        let list = try Fixture.list()
        let stale = ["Drum loop", "Unnamed asset", "Verse chart"]
        #expect(list.filtered(by: "stale").rows.map(\.title) == stale)
        #expect(list.filtered(by: "bookmark").rows.map(\.title) == stale)
        #expect(list.filtered(by: "STALE BOOKMARK").rows.map(\.title) == stale)
    }

    @Test func searchByKindAndAvailableWords() throws {
        let list = try Fixture.list()
        #expect(list.filtered(by: "audio").rows.map(\.title) == ["Click track", "Drum loop"])
        #expect(list.filtered(by: "midi").rows.map(\.title) == ["Arp"])
        #expect(list.filtered(by: "available").rows.map(\.title) == ["Arp", "Bridge chart", "Click track"])
    }

    @Test func searchByNameIsCaseInsensitive() throws {
        let list = try Fixture.list()
        #expect(list.filtered(by: "chart").rows.map(\.title) == ["Bridge chart", "Unnamed asset", "Verse chart"])
        #expect(list.filtered(by: "verse").rows.map(\.title) == ["Verse chart"])
        #expect(list.filtered(by: "CLICK").rows.map(\.title) == ["Click track"])
    }

    @Test func everyTermMustMatch() throws {
        let list = try Fixture.list()
        #expect(list.filtered(by: "chart stale").rows.map(\.title) == ["Unnamed asset", "Verse chart"])
        #expect(list.filtered(by: "audio chart").rows.isEmpty)
    }

    @Test func idsAndSecondaryTextNeverMatch() throws {
        let list = try Fixture.list()
        #expect(list.filtered(by: "a.verse").rows.isEmpty)
        #expect(list.filtered(by: "a.blank").rows.isEmpty)
    }

    @Test func aBlankQueryKeepsTheListAndNoMatchEmptiesIt() throws {
        let list = try Fixture.list()
        #expect(list.filtered(by: "") == list)
        #expect(list.filtered(by: "  \t ") == list)
        #expect(list.filtered(by: "zzz").rows.isEmpty)
    }

    @Test func filteringIsIncremental() throws {
        let list = try Fixture.list()
        #expect(list.filtered(by: "chart").filtered(by: "stale") == list.filtered(by: "chart stale"))
    }

    @Test func aFilteredRowEqualsTheUnfilteredRow() throws {
        let list = try Fixture.list()
        let kept = list.filtered(by: "stale").rows
        let all = list.rows
        try #require(!kept.isEmpty)
        for row in kept {
            let original = try #require(all.first { $0.id == row.id })
            #expect(row == original)
        }
    }

    @Test func theTemplatesPlaceholderReadsAsTheDocMocksIt() {
        let section = LibraryTemplatesSection()
        #expect(section.title == "Templates")
        #expect(section.placeholderText == "(none yet)")
        #expect(section.accessibilityLabel == "Templates, none yet")
    }

    @Test func theTemplatesPlaceholderMatchesByItsOwnTextOnly() {
        let section = LibraryTemplatesSection()
        for query in ["", "   ", "none", "YET", "(none", "none yet"] {
            #expect(section.matches(query: query), "query \(query)")
        }
        for query in ["template", "stale", "none stale"] {
            #expect(!section.matches(query: query), "query \(query)")
        }
    }

    /// Fixtures built only through the production API. Internal, not private:
    /// the root suite file uses them too.
    enum Fixture {
        static let digest = "sha256:" + String(repeating: "a", count: 64)

        static func id(_ id: StaticString) -> AssetID { AssetID(validated: id) }

        static func asset(_ id: StaticString, _ label: String, _ media: AssetMedia) -> ProjectAsset {
            ProjectAsset(id: Self.id(id), label: label, media: media, contentDigest: digest)
        }

        static let assets = [
            asset("a.verse", "Verse chart", .document),
            asset("a.bridge", "Bridge chart", .document),
            asset("a.click", "Click track", .audio),
            asset("a.loop", "Drum loop", .audio),
            asset("a.arp", "Arp", .midi),
            asset("a.blank", "  ", .document)
        ]

        static let available: Set<AssetID> = [id("a.bridge"), id("a.click"), id("a.arp")]

        static func list() throws -> LibraryMediaList {
            try LibraryMediaList.make(assets: assets, availableContent: available)
        }
    }
}
