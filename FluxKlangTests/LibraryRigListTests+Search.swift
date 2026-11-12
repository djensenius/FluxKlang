//
//  LibraryRigListTests+Search.swift
//  FluxKlangTests
//
//  Search of the Library rig list (#99 LIB3): whole-term substring match on name, kind, status, detail and selected
//  text, case-insensitive and locale independent, every term must match, blank queries, no match on ids, UIDs or
//  roles, rows that are never rewritten, and filters that compose.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension LibraryRigListTests {
    private typealias Search = LibraryRigFixture

    /// Six rigs, in name order: Alpha (selected, partial), Bravo (full, all matched), Charlie (manual, one missing),
    /// Delta (no devices), Echo (manual, one stale and one ambiguous) and Foxtrot (full, one renumbered).
    private static func sixRigs() throws -> LibraryRigList {
        let entries = try [
            Search.entry("rig.a", "Alpha", [Search.saved("dev.a1", role: "rol.main"), Search.saved("dev.a2")]),
            Search.entry("rig.b", "Bravo", [Search.saved("dev.b1")]),
            Search.entry("rig.c", "Charlie", [Search.saved("dev.c1")]),
            Search.entry("rig.d", "Delta"),
            Search.entry("rig.e", "Echo", [Search.saved("dev.e1"), Search.saved("dev.e2")]),
            Search.entry("rig.f", "Foxtrot", [Search.saved("dev.f1"), Search.saved("dev.f2")])
        ]
        let observed = try [
            Search.device("dev.a1"), Search.device("dev.b1"), Search.device("dev.e1", presence: .stale),
            Search.device("dev.x1", uid: "uid-dev.e2"), Search.device("dev.x2", uid: "uid-dev.e2"),
            Search.device("dev.f9", uid: "uid-dev.f1"), Search.device("dev.f2")
        ]
        return try Search.list(entries, selected: "rig.a", observed: observed)
    }

    private func titles(_ list: LibraryRigList, _ query: String) -> [String] {
        list.filtered(by: query).rows.map(\.title)
    }

    @Test func searchMatchesNameKindStatusDetailAndSelectedTextIgnoringCase() throws {
        let list = try Self.sixRigs()
        #expect(list.rows.map(\.title) == ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"])
        #expect(titles(list, "alpha") == ["Alpha"])
        #expect(titles(list, "ALPHA") == ["Alpha"])
        #expect(titles(list, "RIG") == ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"])
        #expect(titles(list, "partial") == ["Alpha"])
        #expect(titles(list, "Full") == ["Bravo", "Delta", "Foxtrot"])
        #expect(titles(list, "manual") == ["Charlie", "Echo"])
        #expect(titles(list, "REMOTE") == ["Charlie", "Echo"])
        #expect(titles(list, "missing") == ["Alpha", "Charlie"])
        #expect(titles(list, "stale") == ["Echo"])
        #expect(titles(list, "ambiguous") == ["Echo"])
        #expect(titles(list, "renumbered") == ["Foxtrot"])
        #expect(titles(list, "devices") == ["Alpha", "Delta", "Echo", "Foxtrot"])
        #expect(titles(list, "all matched") == ["Bravo"])
        #expect(titles(list, "no devices") == ["Delta"])
        #expect(titles(list, "selected") == ["Alpha"])
        #expect(titles(list, "SELECTED") == ["Alpha"])
    }

    @Test func searchRequiresEveryTermAndSplitsOnWhitespace() throws {
        let list = try Self.sixRigs()
        #expect(titles(list, "alpha missing") == ["Alpha"])
        #expect(titles(list, "bravo missing").isEmpty)
        #expect(titles(list, "full matched") == ["Bravo"])
        #expect(titles(list, "rig\tmanual\nremote") == ["Charlie", "Echo"])
        #expect(titles(list, "manual\tstale") == ["Echo"])
        #expect(titles(list, " stale\nambiguous ") == ["Echo"])
        #expect(titles(list, "zzz").isEmpty)
        #expect(titles(list, "alpha zzz").isEmpty)
    }

    @Test func aBlankQueryReturnsTheListUnchanged() throws {
        let list = try Self.sixRigs()
        for query in ["", " ", "  \t\n "] {
            #expect(list.filtered(by: query) == list)
        }
        #expect(try LibraryRigList.make(library: .empty, observed: []).filtered(by: "x").rows.isEmpty)
    }

    @Test func searchKeepsTheOrderOfTheList() throws {
        let list = try Self.sixRigs()
        #expect(titles(list, "ch") == ["Bravo", "Charlie", "Echo"])
        let kept = list.filtered(by: "ch").rows
        #expect(kept == list.rows.filter { kept.contains($0) })
    }

    @Test func searchNeverMatchesAnIdAUIDOrARole() throws {
        let list = try Self.sixRigs()
        let queries = ["rig.a", "rig.b", "rig.", "dev.a1", "dev.b1", "dev.x1", "uid-dev", "uid-dev.a1", "rol.main"]
        for query in queries {
            #expect(titles(list, query).isEmpty, Comment(rawValue: query))
        }
    }

    @Test func aFilteredRowIsTheUnfilteredRow() throws {
        let list = try Self.sixRigs()
        for query in ["rig", "missing", "stale", "all matched", "selected", "ch", "manual remote"] {
            let filtered = list.filtered(by: query)
            #expect(!filtered.rows.isEmpty, Comment(rawValue: query))
            for row in filtered.rows {
                let original = try #require(list.rows.first { $0.id == row.id })
                #expect(row == original, Comment(rawValue: query))
            }
        }
    }

    @Test func filteringComposes() throws {
        let list = try Self.sixRigs()
        let pairs = [
            ("full", "matched"), ("rig", "missing"), ("alpha", "partial"), ("selected", "alpha"), ("zzz", "rig"),
            ("", "full"), ("full", ""), ("stale", "ambiguous"), ("manual", "remote"), ("devices", "renumbered")
        ]
        for (first, second) in pairs {
            let stepwise = list.filtered(by: first).filtered(by: second)
            #expect(stepwise == list.filtered(by: first + " " + second), Comment(rawValue: first + "|" + second))
        }
    }

    @Test func searchFoldsNonASCIICaseWithoutALocale() throws {
        let entries = try [
            Search.entry("rig.a", "Éclair"), Search.entry("rig.b", "ÉCLAIR"), Search.entry("rig.c", "Zed")
        ]
        let list = try Search.list(entries)
        #expect(list.rows.map(\.title) == ["Zed", "ÉCLAIR", "Éclair"])
        #expect(titles(list, "éclair") == ["ÉCLAIR", "Éclair"])
        #expect(titles(list, "ÉCL") == ["ÉCLAIR", "Éclair"])
        #expect(titles(list, "éCLAIR") == ["ÉCLAIR", "Éclair"])
        #expect(titles(list, "eclair").isEmpty)
        #expect(titles(list, "zed") == ["Zed"])
    }
}
