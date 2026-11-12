//
//  LibraryPluginListTests.swift
//  FluxKlangTests
//
//  The Library "Plugins" section as a value (#99 LIB1): rows built from the plugin catalog, their statuses and
//  precedence (quarantine first), the caller's incompatibility judgment, nameless rows, the byte order of rows, the
//  scan row of a never-scanned catalog, the accessibility labels and the pinned fixed texts. Search is in
//  LibraryPluginListTests+Search.swift. The list is a pure value: nothing here scans, reads a view or opens a file.
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
struct LibraryPluginListTests {
    @Test func emptyScannedCatalogHasNoRowsAndNoScanRow() throws {
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [])
        let list = LibraryPluginList.make(catalog: catalog)
        #expect(list.rows.isEmpty)
        #expect(list.scanRow == nil)
        #expect(list.generation == catalog.generation)
        #expect(list.generation.value == 2)
    }

    @Test func neverScannedCatalogHasAScanRowAndNoRows() throws {
        let list = LibraryPluginList.make(catalog: PluginCatalog())
        let scan = try #require(list.scanRow)
        #expect(scan.title == "(scan)")
        #expect(scan.statusText == "Not scanned")
        #expect(scan.actions.map(\.kind) == [.scan])
        #expect(scan.actions.map(\.title) == ["Scan..."])
        #expect(scan.actions.map(\.isEnabled) == [true])
        #expect(scan.accessibilityLabel == "Plugin catalog, not scanned")
        #expect(list.rows.isEmpty)
        #expect(list.generation == .initial)
    }

    @Test func installedRowShowsNameKindStatusAndTwoActions() throws {
        let verb = try Fixture.identity("Verb")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb")])
        let list = LibraryPluginList.make(catalog: catalog)
        let row = try #require(list.rows.first)
        #expect(list.rows.count == 1)
        #expect(row.id == verb.id)
        #expect(row.title == "Room Verb")
        #expect(row.secondaryText == nil)
        #expect(row.kind == .effect)
        #expect(row.kindText == "Effect")
        #expect(row.status == .installed)
        #expect(row.statusText == "Installed")
        #expect(row.reasonText == nil)
        #expect(row.actions.map(\.kind) == [.addToWiring, .showInfo])
        #expect(row.actions.map(\.title) == ["Add to Wiring", "Show info"])
        #expect(row.actions.map(\.isEnabled) == [true, true])
        #expect(row.accessibilityLabel == "Room Verb, Effect, Installed")
        #expect(list.scanRow == nil)
    }

    @Test func everyComponentKindHasItsText() throws {
        let kinds = [
            ("aufx", "Effect"), ("aumf", "Music effect"), ("aumu", "Instrument"), ("augn", "Generator"),
            ("aumi", "MIDI processor")
        ]
        var catalog = PluginCatalog()
        var expected: [PluginID: String] = [:]
        var entries: [PluginScanEntry] = []
        for (type, text) in kinds {
            let identity = try Fixture.identity("Test", type: type)
            expected[identity.id] = text
            entries.append(try Fixture.described(identity, text))
        }
        try Fixture.scan(&catalog, entries)
        let list = LibraryPluginList.make(catalog: catalog)
        #expect(list.rows.count == 5)
        #expect(list.rows.map(\.title) == ["Effect", "Generator", "Instrument", "MIDI processor", "Music effect"])
        for row in list.rows {
            #expect(row.kindText == expected[row.id])
            #expect(row.title == row.kindText)
        }
    }

    @Test func missingRowKeepsItsNameAndOffersThePlaceholderActions() throws {
        let verb = try Fixture.identity("Verb")
        let echo = try Fixture.identity("Echo")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb"), Fixture.described(echo, "Tape Echo")])
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb")])
        let row = try Fixture.row(LibraryPluginList.make(catalog: catalog), echo.id)
        #expect(row.title == "Tape Echo")
        #expect(row.secondaryText == nil)
        #expect(row.status == .missing)
        #expect(row.statusText == "Missing")
        #expect(row.reasonText == nil)
        #expect(row.actions.map(\.kind) == [.locate, .replaceWith, .keepPlaceholder])
        #expect(row.actions.map(\.title) == ["Locate...", "Replace with...", "Keep placeholder"])
        #expect(row.actions.map(\.isEnabled) == [true, true, true])
    }

    @Test func failedRowKeepsItsNameOrIsUnnamedWithTheIdAsSecondaryText() throws {
        let known = try Fixture.identity("Knwn")
        let unknown = try Fixture.identity("Unkn")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [Fixture.described(known, "Room Verb")])
        try Fixture.scan(&catalog, [
            Fixture.outcome(known, .failed(.validationFailed)), Fixture.outcome(unknown, .failed(.metadataUnavailable))
        ])
        let list = LibraryPluginList.make(catalog: catalog)
        let named = try Fixture.row(list, known.id)
        let nameless = try Fixture.row(list, unknown.id)
        #expect(named.title == "Room Verb")
        #expect(named.secondaryText == nil)
        #expect(named.status == .failed)
        #expect(named.statusText == "Scan failed")
        #expect(named.actions.map(\.title) == ["Scan...", "Show info"])
        #expect(named.actions.map(\.kind) == [.scan, .showInfo])
        #expect(nameless.title == "Unnamed plugin")
        #expect(nameless.secondaryText == unknown.id.rawValue)
        #expect(nameless.status == .failed)
        #expect(nameless.accessibilityLabel == "Unnamed plugin, Effect, Scan failed")
        #expect(list.rows.map(\.id) == [known.id, unknown.id])
    }

    @Test func releasedQuarantineNeedsARescan() throws {
        let verb = try Fixture.identity("Verb")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb")])
        try Fixture.scan(&catalog, [Fixture.outcome(verb, .probeCrashed)], depth: .instantiatingProbe)
        let crashed = try Fixture.row(LibraryPluginList.make(catalog: catalog), verb.id)
        #expect(crashed.status == .quarantined(.probeCrashed))
        _ = try catalog.releaseQuarantine(verb.id)
        let row = try Fixture.row(LibraryPluginList.make(catalog: catalog), verb.id)
        #expect(row.title == "Room Verb")
        #expect(row.status == .needsRescan)
        #expect(row.statusText == "Needs rescan")
        #expect(row.reasonText == nil)
        #expect(row.actions.map(\.kind) == [.scan, .showInfo])
    }

    @Test func bareQuarantineInANeverScannedCatalogIsARowAlongsideTheScanRow() throws {
        let crashed = try Fixture.identity("Cras")
        let hung = try Fixture.identity("Hung", type: "aumu")
        var catalog = PluginCatalog()
        _ = try catalog.recordQuarantine([
            PluginQuarantineEvidence(identity: crashed, reason: .probeCrashed),
            PluginQuarantineEvidence(identity: hung, reason: .probeTimedOut)
        ])
        let list = LibraryPluginList.make(catalog: catalog)
        #expect(list.scanRow != nil)
        #expect(list.rows.count == 2)
        let first = try Fixture.row(list, crashed.id)
        let second = try Fixture.row(list, hung.id)
        #expect(first.status == .quarantined(.probeCrashed))
        #expect(first.statusText == "Quarantined")
        #expect(first.reasonText == "Crashed while probed")
        #expect(second.status == .quarantined(.probeTimedOut))
        #expect(second.reasonText == "Timed out while probed")
        #expect(first.title == "Unnamed plugin")
        #expect(first.secondaryText == crashed.id.rawValue)
        #expect(second.secondaryText == hung.id.rawValue)
        #expect(first.actions.map(\.kind) == [.showInfo])
        #expect(second.actions.map(\.title) == ["Show info"])
    }

    @Test func quarantineWinsOverPresenceAndOverAnIncompatibilityJudgment() throws {
        let verb = try Fixture.identity("Verb")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb")])
        try Fixture.scan(&catalog, [Fixture.outcome(verb, .probeCrashed)], depth: .instantiatingProbe)
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb")])
        #expect(catalog.entries[verb.id]?.presence == .installed)
        #expect(catalog.entries[verb.id]?.quarantine == .probeCrashed)
        let plain = try Fixture.row(LibraryPluginList.make(catalog: catalog), verb.id)
        let judged = try Fixture.row(
            LibraryPluginList.make(catalog: catalog, incompatible: [verb.id: .wrongKind]), verb.id
        )
        #expect(plain.status == .quarantined(.probeCrashed))
        #expect(plain.title == "Room Verb")
        #expect(judged == plain)
    }

    @Test func anInstalledEntryWithoutADescriptorNeedsARescanWhateverTheJudgment() throws {
        let verb = try Fixture.identity("Verb")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb")])
        var entry = try #require(catalog.entries[verb.id])
        #expect(LibraryPluginStatus.of(entry, judgment: .wrongKind) == .incompatible(.wrongKind))
        entry.lastKnown = nil
        #expect(entry.presence == .installed)
        #expect(LibraryPluginStatus.of(entry, judgment: .wrongKind) == .needsRescan)
        #expect(LibraryPluginStatus.of(entry, judgment: nil) == .needsRescan)
    }

    @Test func incompatibleRowDisablesAddWithTheReason() throws {
        let verb = try Fixture.identity("Verb")
        let synth = try Fixture.identity("Synt", type: "aumu")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [Fixture.described(verb, "Room Verb"), Fixture.described(synth, "Soft Synth")])
        let list = LibraryPluginList.make(
            catalog: catalog, incompatible: [verb.id: .wrongKind, synth.id: .wrongPorts]
        )
        let kind = try Fixture.row(list, verb.id)
        let ports = try Fixture.row(list, synth.id)
        #expect(kind.status == .incompatible(.wrongKind))
        #expect(kind.statusText == "Incompatible")
        #expect(kind.reasonText == "Wrong kind of plugin")
        #expect(ports.status == .incompatible(.wrongPorts))
        #expect(ports.reasonText == "Ports do not match")
        #expect(kind.actions.map(\.kind) == [.addToWiring, .showInfo])
        #expect(kind.actions.map(\.title) == ["Add to Wiring", "Show info"])
        #expect(kind.actions.map(\.isEnabled) == [false, true])
        #expect(kind.actions.map(\.disabledReason) == ["Wrong kind of plugin", nil])
        #expect(ports.actions.map(\.disabledReason) == ["Ports do not match", nil])
        #expect(kind.accessibilityLabel == "Room Verb, Effect, Incompatible: Wrong kind of plugin")
        #expect(ports.accessibilityLabel == "Soft Synth, Instrument, Incompatible: Ports do not match")
    }

    @Test func aJudgmentIsIgnoredUnlessTheRowIsInstalled() throws {
        let all = try Fixture.everyStatus()
        let plain = LibraryPluginList.make(catalog: all.catalog)
        let unknown = try Fixture.identity("Nope").id
        let ignored = [all.missing, all.failed, all.needsRescan, all.crashed, all.timedOut, unknown]
        let judgments = Dictionary(uniqueKeysWithValues: ignored.map { ($0, LibraryPluginIncompatibility.wrongKind) })
        #expect(LibraryPluginList.make(catalog: all.catalog, incompatible: judgments) == plain)
        #expect(LibraryPluginList.make(catalog: all.catalog, incompatible: [:]) == plain)
        #expect(try Fixture.row(plain, all.missing).status == .missing)
        #expect(try Fixture.row(plain, all.failed).status == .failed)
        #expect(try Fixture.row(plain, all.needsRescan).status == .needsRescan)
        #expect(try Fixture.row(plain, all.installed).status == .installed)
        #expect(try Fixture.row(plain, all.incompatible).status == .installed)
        let judged = LibraryPluginList.make(catalog: all.catalog, incompatible: all.judgment)
        #expect(try Fixture.row(judged, all.incompatible).status == .incompatible(.wrongPorts))
        #expect(judged.rows.count == plain.rows.count)
    }

    @Test func rowsAreOrderedByLowercasedNameThenExactNameThenId() throws {
        let people = [("Zebra", "Zzzz"), ("alpha", "Aaaa"), ("Beta", "Bbbb"), ("Alpha", "Cccc"), ("alpha", "Dddd")]
        let entries = try people.map { try Fixture.described(Fixture.identity($0.1), $0.0) }
        let expected = try ["Cccc", "Aaaa", "Dddd", "Bbbb", "Zzzz"].map { try Fixture.identity($0).id }
        for order in [entries, entries.reversed(), Array(entries[2...] + entries[..<2])] {
            var catalog = PluginCatalog()
            try Fixture.scan(&catalog, order)
            let list = LibraryPluginList.make(catalog: catalog)
            #expect(list.rows.map(\.title) == ["Alpha", "alpha", "alpha", "Beta", "Zebra"])
            #expect(list.rows.map(\.id) == expected)
        }
    }

    @Test func rowsAreOrderedByUTF8BytesNotBySwiftStringOrder() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        let first = try Fixture.identity("Aaaa")
        let second = try Fixture.identity("Zzzz")
        let accented = try Fixture.identity("Eccl")
        let plain = try Fixture.identity("Zebr")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [
            Fixture.described(first, composed), Fixture.described(second, decomposed),
            Fixture.described(accented, "\u{C9}clair"), Fixture.described(plain, "Zebra")
        ])
        let list = LibraryPluginList.make(catalog: catalog)
        #expect(list.rows.map(\.id) == [second.id, first.id, plain.id, accented.id])
    }

    @Test func aRescanThatChangesStatusesKeepsEveryRowsPlaceAndTheGenerationFollows() throws {
        let alpha = try Fixture.identity("Alph")
        let bravo = try Fixture.identity("Brav")
        let charlie = try Fixture.identity("Char")
        var catalog = PluginCatalog()
        try Fixture.scan(&catalog, [
            Fixture.described(alpha, "Alpha"), Fixture.described(bravo, "Bravo"), Fixture.described(charlie, "Charlie")
        ])
        let before = LibraryPluginList.make(catalog: catalog)
        try Fixture.scan(&catalog, [
            Fixture.outcome(bravo, .failed(.validationFailed)), Fixture.described(charlie, "Charlie")
        ])
        let after = LibraryPluginList.make(catalog: catalog)
        #expect(before.rows.map(\.id) == [alpha.id, bravo.id, charlie.id])
        #expect(after.rows.map(\.id) == before.rows.map(\.id))
        #expect(before.rows.map(\.status) == [.installed, .installed, .installed])
        #expect(after.rows.map(\.status) == [.missing, .failed, .installed])
        #expect(after.generation == catalog.generation)
        #expect(after.generation != before.generation)
    }

    @Test func accessibilityLabelsNameTitleKindStatusAndReason() throws {
        let all = try Fixture.everyStatus()
        let list = LibraryPluginList.make(catalog: all.catalog, incompatible: all.judgment)
        #expect(list.rows.map(\.accessibilityLabel) == [
            "Alpha Verb, Effect, Installed",
            "Bravo Synth, Instrument, Incompatible: Ports do not match",
            "Charlie Echo, Effect, Missing",
            "Delta Delay, Effect, Scan failed",
            "Echo Chorus, Music effect, Needs rescan",
            "Foxtrot Fuzz, Generator, Quarantined: Crashed while probed",
            "Golf Gate, MIDI processor, Quarantined: Timed out while probed"
        ])
        for row in list.rows {
            let first = try #require(row.actions.first)
            #expect(!row.accessibilityLabel.contains(first.title))
        }
    }

    @Test func fixedTextsAndActionSetsArePinned() {
        #expect(PluginComponentKind.allCases.map(LibraryPluginText.kind) == [
            "Effect", "Music effect", "Instrument", "Generator", "MIDI processor"
        ])
        let statuses: [LibraryPluginStatus] = [
            .installed, .missing, .incompatible(.wrongKind), .failed, .needsRescan, .quarantined(.probeCrashed)
        ]
        #expect(statuses.map(LibraryPluginText.status) == [
            "Installed", "Missing", "Incompatible", "Scan failed", "Needs rescan", "Quarantined"
        ])
        let reasons = statuses.map(LibraryPluginText.reason)
        #expect(reasons == [nil, nil, "Wrong kind of plugin", nil, nil, "Crashed while probed"])
        #expect(LibraryPluginText.reason(of: .incompatible(.wrongPorts)) == "Ports do not match")
        #expect(LibraryPluginText.reason(of: .quarantined(.probeTimedOut)) == "Timed out while probed")
        #expect(LibraryPluginText.namelessTitle == "Unnamed plugin")
        #expect(LibraryPluginText.scanRowTitle == "(scan)")
        #expect(LibraryPluginText.notScannedText == "Not scanned")
        let table = statuses.map { status in
            LibraryPluginAction.actions(for: status).map { "\($0.kind) \($0.title) \($0.disabledReason ?? "-")" }
        }
        #expect(table == [
            ["addToWiring Add to Wiring -", "showInfo Show info -"],
            ["locate Locate... -", "replaceWith Replace with... -", "keepPlaceholder Keep placeholder -"],
            ["addToWiring Add to Wiring Wrong kind of plugin", "showInfo Show info -"],
            ["scan Scan... -", "showInfo Show info -"],
            ["scan Scan... -", "showInfo Show info -"],
            ["showInfo Show info -"]
        ])
    }
}
