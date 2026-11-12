//
//  LibraryPluginListTests+Search.swift
//  FluxKlangTests
//
//  Search of the Library plugin list (#99 LIB1) and the fixtures the root suite shares: whole-term substring match
//  on name, kind and status, case-insensitive, every term must match, blank queries, no match on ids or reasons, the
//  scan row, and the list's generation and order surviving a filter.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension LibraryPluginListTests {
    @Test func searchMatchesNameKindAndStatusIgnoringCase() throws {
        let all = try Fixture.everyStatus()
        let list = LibraryPluginList.make(catalog: all.catalog, incompatible: all.judgment)
        #expect(list.filtered(by: "missing").rows.map(\.title) == ["Charlie Echo"])
        #expect(list.filtered(by: "MISSING").rows.map(\.title) == ["Charlie Echo"])
        #expect(list.filtered(by: "verb").rows.map(\.title) == ["Alpha Verb"])
        #expect(list.filtered(by: "ECH").rows.map(\.title) == ["Charlie Echo", "Echo Chorus"])
        #expect(list.filtered(by: "inst").rows.map(\.title) == ["Alpha Verb", "Bravo Synth"])
        let effects = ["Alpha Verb", "Charlie Echo", "Delta Delay", "Echo Chorus"]
        #expect(list.filtered(by: "effect").rows.map(\.title) == effects)
        #expect(list.filtered(by: "quarantined").rows.map(\.title) == ["Foxtrot Fuzz", "Golf Gate"])
        #expect(list.filtered(by: "midi").rows.map(\.title) == ["Golf Gate"])
    }

    @Test func searchRequiresEveryTermAndSplitsOnWhitespace() throws {
        let all = try Fixture.everyStatus()
        let list = LibraryPluginList.make(catalog: all.catalog, incompatible: all.judgment)
        #expect(list.filtered(by: "delta failed").rows.map(\.title) == ["Delta Delay"])
        #expect(list.filtered(by: "delta\tfailed").rows.map(\.title) == ["Delta Delay"])
        #expect(list.filtered(by: "failed\ndelta ").rows.map(\.title) == ["Delta Delay"])
        #expect(list.filtered(by: "music effect").rows.map(\.title) == ["Echo Chorus"])
        #expect(list.filtered(by: "alpha missing").rows.isEmpty)
        #expect(list.filtered(by: "zzz").rows.isEmpty)
        #expect(list.filtered(by: "zzz").generation == list.generation)
    }

    @Test func aBlankQueryReturnsTheListUnchanged() throws {
        let all = try Fixture.everyStatus()
        let list = LibraryPluginList.make(catalog: all.catalog, incompatible: all.judgment)
        #expect(list.rows.count == 7)
        for query in ["", " ", "  \t\n "] {
            #expect(list.filtered(by: query) == list)
        }
        let unscanned = LibraryPluginList.make(catalog: PluginCatalog())
        #expect(unscanned.filtered(by: " ") == unscanned)
    }

    @Test func theSharedSearchTermsSplitOnWhitespaceAndLowercase() {
        #expect(LibrarySearchTerms.terms("  Foo\tBAR\n baz ") == ["foo", "bar", "baz"])
        #expect(LibrarySearchTerms.terms("").isEmpty)
        #expect(LibrarySearchTerms.terms("   ").isEmpty)
        #expect(LibrarySearchTerms.terms("É") == ["é"])
    }

    @Test func searchNeverMatchesTheIdOrTheReason() throws {
        let all = try Fixture.everyStatus()
        let list = LibraryPluginList.make(catalog: all.catalog, incompatible: all.judgment)
        #expect(list.rows.map(\.id.rawValue).allSatisfy { $0.hasPrefix("plg.au2.") })
        #expect(list.filtered(by: "plg").rows.isEmpty)
        #expect(list.filtered(by: "au2").rows.isEmpty)
        #expect(list.filtered(by: all.crashed.rawValue).rows.isEmpty)
        #expect(list.filtered(by: "crashed").rows.isEmpty)
        #expect(list.filtered(by: "timed").rows.isEmpty)
        #expect(list.filtered(by: "ports").rows.isEmpty)
        #expect(list.filtered(by: "wrong").rows.isEmpty)
    }

    @Test func theScanRowIsFoundByItsTitleAndStatusAndDroppedByOtherTerms() throws {
        let crashed = try Fixture.identity("Cras")
        var catalog = PluginCatalog()
        _ = try catalog.recordQuarantine([PluginQuarantineEvidence(identity: crashed, reason: .probeCrashed)])
        let list = LibraryPluginList.make(catalog: catalog)
        #expect(list.rows.count == 1)
        for query in ["scan", "SCAN", "not scanned", "(scan)", "not"] {
            let found = list.filtered(by: query)
            #expect(found.scanRow == list.scanRow)
            #expect(found.scanRow != nil)
            #expect(found.rows.isEmpty)
        }
        let quarantined = list.filtered(by: "quarantined")
        #expect(quarantined.scanRow == nil)
        #expect(quarantined.rows.map(\.id) == [crashed.id])
        #expect(list.filtered(by: "scan quarantined").scanRow == nil)
        #expect(list.filtered(by: "scan quarantined").rows.isEmpty)
        let scanned = LibraryPluginList.make(catalog: try Fixture.everyStatus().catalog)
        #expect(scanned.filtered(by: "scan").scanRow == nil)
        #expect(scanned.filtered(by: "scan").rows.map(\.title) == ["Delta Delay", "Echo Chorus"])
    }

    @Test func filteringKeepsGenerationAndOrderAndComposes() throws {
        let all = try Fixture.everyStatus()
        let list = LibraryPluginList.make(catalog: all.catalog, incompatible: all.judgment)
        let narrowed = list.filtered(by: "e")
        let effects = ["Alpha Verb", "Charlie Echo", "Delta Delay", "Echo Chorus"]
        #expect(narrowed.generation == list.generation)
        #expect(narrowed.generation == all.catalog.generation)
        #expect(narrowed.rows.count == 7)
        #expect(narrowed.rows.map(\.id) == list.rows.map(\.id))
        #expect(list.filtered(by: "e").filtered(by: "effect") == list.filtered(by: "e effect"))
        #expect(list.filtered(by: "e effect").rows.map(\.title) == effects)
    }
}

extension LibraryPluginListTests {
    struct Statuses {
        let catalog: PluginCatalog
        let installed: PluginID
        let incompatible: PluginID
        let missing: PluginID
        let failed: PluginID
        let needsRescan: PluginID
        let crashed: PluginID
        let timedOut: PluginID

        /// The caller's judgment that makes `incompatible` read as incompatible.
        var judgment: [PluginID: LibraryPluginIncompatibility] { [incompatible: .wrongPorts] }
    }

    /// Fixtures shared with the root suite: every catalog is built through the catalog's own API.
    enum Fixture {
        static func identity(_ subtype: String, type: String = "aufx") throws -> PluginIdentity {
            try PluginIdentity(
                format: .audioUnitV2, type: PluginFourCharacterCode(type),
                subtype: PluginFourCharacterCode(subtype), manufacturer: PluginFourCharacterCode("Fxkl")
            )
        }

        static func described(_ identity: PluginIdentity, _ name: String) throws -> PluginScanEntry {
            let descriptor = try PluginDescriptor(
                identity: identity, name: name, manufacturerName: "Fixture Audio",
                version: PluginVersion(rawValue: 0x0001_0000),
                buses: PluginBusLayout(inputChannels: [2], outputChannels: [2])
            )
            return PluginScanEntry(identity: identity, outcome: .described(descriptor))
        }

        static func outcome(_ identity: PluginIdentity, _ outcome: PluginScanOutcome) -> PluginScanEntry {
            PluginScanEntry(identity: identity, outcome: outcome)
        }

        static func scan(
            _ catalog: inout PluginCatalog, _ entries: [PluginScanEntry], depth: PluginScanDepth = .metadataOnly
        ) throws {
            _ = try catalog.apply(PluginScanReport(entries: entries), for: catalog.request(depth: depth))
        }

        static func row(_ list: LibraryPluginList, _ id: PluginID) throws -> LibraryPluginRow {
            try #require(list.rows.first { $0.id == id })
        }

        /// One plugin per status, titled Alpha to Golf, so the rows come out in that order.
        static func everyStatus() throws -> Statuses {
            let alpha = try identity("Alph")
            let bravo = try identity("Brav", type: "aumu")
            let charlie = try identity("Char")
            let delta = try identity("Delt")
            let echo = try identity("Echo", type: "aumf")
            let foxtrot = try identity("Foxt", type: "augn")
            let golf = try identity("Golf", type: "aumi")
            var catalog = PluginCatalog()
            try scan(&catalog, [
                described(alpha, "Alpha Verb"), described(bravo, "Bravo Synth"), described(charlie, "Charlie Echo"),
                described(delta, "Delta Delay"), described(echo, "Echo Chorus"), described(foxtrot, "Foxtrot Fuzz"),
                described(golf, "Golf Gate")
            ])
            try scan(&catalog, [
                described(alpha, "Alpha Verb"), described(bravo, "Bravo Synth"),
                outcome(delta, .failed(.validationFailed)), outcome(echo, .probeCrashed),
                outcome(foxtrot, .probeCrashed), outcome(golf, .probeTimedOut)
            ], depth: .instantiatingProbe)
            _ = try catalog.releaseQuarantine(echo.id)
            return Statuses(
                catalog: catalog, installed: alpha.id, incompatible: bravo.id, missing: charlie.id,
                failed: delta.id, needsRescan: echo.id, crashed: foxtrot.id, timedOut: golf.id
            )
        }
    }
}
