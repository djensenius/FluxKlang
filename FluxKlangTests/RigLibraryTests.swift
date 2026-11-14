import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builders for the rig library suite. Rig ids are `rig.a`, names are plain words.
private enum LibraryFixture {
    typealias Fixture = RigIdentityFixture

    static func rigID(_ raw: String) throws -> RigProfileID { try RigProfileID(raw) }

    static func entry(_ id: String, _ name: String, _ devices: [RigSavedDevice] = []) throws -> RigLibraryEntry {
        try RigLibraryEntry.make(name: name, rig: Fixture.rig(id, devices))
    }

    /// An entry built without validation, as a caller could.
    static func handEntry(_ id: String, _ name: String, _ devices: [RigSavedDevice]) throws -> RigLibraryEntry {
        try RigLibraryEntry(name: RigUID(name), rig: Fixture.handBuilt(id, devices))
    }

    static func library(_ entries: [RigLibraryEntry], selected: String? = nil) throws -> RigLibrary {
        try RigLibrary.make(entries: entries, selected: selected.map { try RigProfileID($0) })
    }

    /// `rig.a` Alpha (two devices), `rig.b` Bravo (one), `rig.c` Charlie (none).
    static func trio(selected: String? = nil) throws -> RigLibrary {
        let alpha = try entry("rig.a", "Alpha", [Fixture.saved("dev.a1", required: false),
                                                 Fixture.saved("dev.a2", role: "rol.main")])
        let bravo = try entry("rig.b", "Bravo", [Fixture.saved("dev.b1")])
        return try library([entry("rig.c", "Charlie"), alpha, bravo], selected: selected)
    }

    /// `count` empty rigs `rig.00`... named `Rig 00`...
    static func many(_ count: Int) throws -> RigLibrary {
        try library((0..<count).map { try entry("rig.\(Fixture.pad($0))", "Rig \(Fixture.pad($0))") })
    }

    static func refusal<Value>(_ body: () throws -> Value) -> RigLibraryRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? RigLibraryRefusal
        }
    }

    static func ids(_ library: RigLibrary) -> [String] { library.entries.map(\.id.rawValue) }
    static func names(_ library: RigLibrary) -> [String] { library.entries.map(\.name.text) }
    static func spaces(_ count: Int) -> String { String(repeating: " ", count: count) }
}

@Suite("Rig library: values, names and construction", .productionAccessAudit)
struct RigLibraryTests {
    private typealias Lib = LibraryFixture
    typealias Fixture = RigIdentityFixture

    // MARK: make

    @Test func emptyLibraryIsValidAndHasNoSelection() throws {
        let made = try RigLibrary.make(entries: [], selected: nil)
        #expect(made == RigLibrary.empty)
        #expect(made.entries.isEmpty)
        #expect(made.selected == nil)
        #expect(made.savedRigs.isEmpty)
    }

    @Test func makeAcceptsSixteenEntriesAndRefusesSeventeen() throws {
        let sixteen = try Lib.many(16)
        #expect(sixteen.entries.count == 16)
        let seventeen = try (0..<17).map { try Lib.entry("rig.\(Fixture.pad($0))", "Rig \(Fixture.pad($0))") }
        let refusal = Lib.refusal { try RigLibrary.make(entries: seventeen, selected: nil) }
        #expect(refusal == .rig(.tooManyRigs(count: 17, maximum: 16)))
    }

    @Test func makeOrdersEntriesByIDBytesWithCapitalsFirst() throws {
        let made = try Lib.library([Lib.entry("rig.b", "B"), Lib.entry("rig.a", "a"), Lib.entry("Rig.A", "Z")])
        let ids = Lib.ids(made)
        #expect(ids == ["Rig.A", "rig.a", "rig.b"])
        let rigs = made.savedRigs.map(\.id.rawValue)
        #expect(rigs == ["Rig.A", "rig.a", "rig.b"])
    }

    @Test func makeRefusesARepeatedRigIDAndNamesTheSmallest() throws {
        let entries = try [Lib.entry("rig.c", "One"), Lib.entry("rig.c", "Two"), Lib.entry("rig.a", "Five"),
                           Lib.entry("rig.b", "Three"), Lib.entry("rig.b", "Four")]
        let refusal = Lib.refusal { try RigLibrary.make(entries: entries, selected: nil) }
        #expect(refusal == .rig(.duplicateRig(try Lib.rigID("rig.b"))))
    }

    @Test func makeReportsTooManyRigsBeforeARepeatedRigID() throws {
        var entries = try (0..<16).map { try Lib.entry("rig.\(Fixture.pad($0))", "Rig \(Fixture.pad($0))") }
        entries.append(try Lib.entry("rig.0000", "Again"))
        let refusal = Lib.refusal { try RigLibrary.make(entries: entries, selected: nil) }
        #expect(refusal == .rig(.tooManyRigs(count: 17, maximum: 16)))
    }

    @Test func makeReportsARepeatedRigIDBeforeAnInvalidRig() throws {
        let twin = try Fixture.saved("dev.x", uid: "same")
        let other = try Fixture.saved("dev.y", uid: "same")
        let entries = try [Lib.handEntry("rig.a", "Bad", [twin, other]), Lib.entry("rig.c", "One"),
                           Lib.entry("rig.c", "Two")]
        let refusal = Lib.refusal { try RigLibrary.make(entries: entries, selected: nil) }
        #expect(refusal == .rig(.duplicateRig(try Lib.rigID("rig.c"))))
    }

    @Test func makeRefusesAHandBuiltRigThatRepeatsAUID() throws {
        let first = try Fixture.saved("dev.x", uid: "same")
        let second = try Fixture.saved("dev.y", uid: "same")
        let entries = try [Lib.entry("rig.a", "Fine"), Lib.handEntry("rig.b", "Bad", [first, second])]
        let refusal = Lib.refusal { try RigLibrary.make(entries: entries, selected: nil) }
        let expected = RigLibraryRefusal.rig(.duplicateUID(first: try DeviceID("dev.x"), second: try DeviceID("dev.y")))
        #expect(refusal == expected)
    }

    @Test func makeReportsAnInvalidRigBeforeARepeatedName() throws {
        let first = try Fixture.saved("dev.x", uid: "same")
        let second = try Fixture.saved("dev.y", uid: "same")
        let entries = try [Lib.entry("rig.a", "Shared"), Lib.handEntry("rig.b", "Shared", [first, second])]
        let refusal = Lib.refusal { try RigLibrary.make(entries: entries, selected: nil) }
        let expected = RigLibraryRefusal.rig(.duplicateUID(first: try DeviceID("dev.x"), second: try DeviceID("dev.y")))
        #expect(refusal == expected)
    }

    @Test func makeReportsARepeatedNameBeforeAnUnknownSelection() throws {
        let entries = try [Lib.entry("rig.a", "Shared"), Lib.entry("rig.b", "Shared")]
        let refusal = Lib.refusal { try Lib.library(entries, selected: "rig.zz") }
        #expect(refusal == .duplicateName(try Lib.rigID("rig.b")))
    }

    @Test func makeNamesTheLaterHolderOfARepeatedName() throws {
        let entries = try [Lib.entry("rig.a", "Shared"), Lib.entry("rig.b", "Other"), Lib.entry("rig.c", "Shared")]
        let refusal = Lib.refusal { try RigLibrary.make(entries: entries, selected: nil) }
        #expect(refusal == .duplicateName(try Lib.rigID("rig.c")))
    }

    @Test func makeKeepsCanonicallyEqualNamesApartAndMergesEqualScalars() throws {
        let both = try Lib.library([Lib.entry("rig.a", Fixture.precomposed), Lib.entry("rig.b", Fixture.decomposed)])
        #expect(both.entries.count == 2)
        let same = try [Lib.entry("rig.a", Fixture.precomposed), Lib.entry("rig.b", Fixture.precomposed)]
        let refusal = Lib.refusal { try RigLibrary.make(entries: same, selected: nil) }
        #expect(refusal == .duplicateName(try Lib.rigID("rig.b")))
    }

    @Test func makeRefusesAnUnknownSelectionAndAcceptsAKnownOne() throws {
        let entries = try [Lib.entry("rig.a", "Alpha")]
        let refusal = Lib.refusal { try Lib.library(entries, selected: "rig.b") }
        #expect(refusal == .unknownSelection(try Lib.rigID("rig.b")))
        let chosen = try Lib.library(entries, selected: "rig.a")
        #expect(chosen.selected == (try Lib.rigID("rig.a")))
        let onEmpty = Lib.refusal { try Lib.library([], selected: "rig.a") }
        #expect(onEmpty == .unknownSelection(try Lib.rigID("rig.a")))
    }

    @Test func makeRefusesHandBuiltBlankAndOverlongNames() throws {
        let blank = Lib.refusal { try RigLibrary.make(entries: [Lib.handEntry("rig.a", "  ", [])], selected: nil) }
        #expect(blank == .blankName)
        let long = String(repeating: "n", count: 129)
        let over = Lib.refusal { try RigLibrary.make(entries: [Lib.handEntry("rig.a", long, [])], selected: nil) }
        #expect(over == .nameTooLong(129))
    }

    @Test func makeChecksAnEntrysNameBeforeItsRig() throws {
        let first = try Fixture.saved("dev.x", uid: "same")
        let second = try Fixture.saved("dev.y", uid: "same")
        let bad = try Lib.handEntry("rig.a", " ", [first, second])
        let refusal = Lib.refusal { try RigLibrary.make(entries: [bad], selected: nil) }
        #expect(refusal == .blankName)
    }

    @Test func savedRigsAreTheEntryRigsInIDOrder() throws {
        let trio = try Lib.trio()
        let expected = try [Fixture.rig("rig.a", [Fixture.saved("dev.a1", required: false),
                                                  Fixture.saved("dev.a2", role: "rol.main")]),
                            Fixture.rig("rig.b", [Fixture.saved("dev.b1")]), Fixture.rig("rig.c", [])]
        #expect(trio.savedRigs == expected)
    }

    @Test func entryLookupFindsTheNamedRigAndNoOther() throws {
        let trio = try Lib.trio()
        let found = trio.entry(for: try Lib.rigID("rig.b"))
        #expect(found?.name.text == "Bravo")
        let absent = trio.entry(for: try Lib.rigID("rig.zz"))
        #expect(absent == nil)
    }

    // MARK: entry

    @Test func entryAcceptsA128ByteNameAndRefuses129() throws {
        let rig = try Fixture.rig("rig.a", [])
        let atLimit = String(repeating: "n", count: 128)
        let accepted = try RigLibraryEntry.make(name: atLimit, rig: rig)
        #expect(accepted.name.text == atLimit)
        let over = Lib.refusal { try RigLibraryEntry.make(name: String(repeating: "n", count: 129), rig: rig) }
        #expect(over == .nameTooLong(129))
    }

    @Test func entryCountsNameBytesRatherThanCharacters() throws {
        let rig = try Fixture.rig("rig.a", [])
        let fits = String(repeating: "\u{20AC}", count: 42)
        #expect(fits.utf8.count == 126)
        _ = try RigLibraryEntry.make(name: fits, rig: rig)
        let tooLong = String(repeating: "\u{20AC}", count: 100)
        let refusal = Lib.refusal { try RigLibraryEntry.make(name: tooLong, rig: rig) }
        #expect(refusal == .nameTooLong(300))
    }

    @Test func entryRefusesBlankNamesAndKeepsPaddedNamesVerbatim() throws {
        let rig = try Fixture.rig("rig.a", [])
        for blank in ["", " ", "\n\t "] {
            let refusal = Lib.refusal { try RigLibraryEntry.make(name: blank, rig: rig) }
            #expect(refusal == .blankName)
        }
        let padded = try RigLibraryEntry.make(name: "  Mains \n", rig: rig)
        #expect(padded.name.text == "  Mains \n")
        #expect(padded.id == rig.id)
    }

    @Test func entryReportsAnOverlongBlankNameAsTooLong() throws {
        let rig = try Fixture.rig("rig.a", [])
        let blankAndLong = Lib.spaces(129)
        let refusal = Lib.refusal { try RigLibraryEntry.make(name: blankAndLong, rig: rig) }
        #expect(refusal == .nameTooLong(129))
    }

    @Test func entryWrapsTheRefusalOfAnInvalidRig() throws {
        let first = try Fixture.saved("dev.x", uid: "same")
        let second = try Fixture.saved("dev.y", uid: "same")
        let bad = try Fixture.handBuilt("rig.a", [first, second])
        let refusal = Lib.refusal { try RigLibraryEntry.make(name: "Bad", rig: bad) }
        let expected = RigLibraryRefusal.rig(.duplicateUID(first: try DeviceID("dev.x"), second: try DeviceID("dev.y")))
        #expect(refusal == expected)
    }

    @Test func entryReportsABlankNameBeforeAnInvalidRig() throws {
        let first = try Fixture.saved("dev.x", uid: "same")
        let second = try Fixture.saved("dev.y", uid: "same")
        let bad = try Fixture.handBuilt("rig.a", [first, second])
        let refusal = Lib.refusal { try RigLibraryEntry.make(name: " ", rig: bad) }
        #expect(refusal == .blankName)
    }

    // MARK: capture

    @Test func captureKeepsPresentDevicesInIDOrderWithNoRoleAndNotRequired() throws {
        let observed = try [Fixture.device("dev.c"), Fixture.device("dev.a", presence: .missing),
                            Fixture.device("dev.b", evidence: [.endpointUID]),
                            Fixture.device("dev.d", presence: .stale),
                            Fixture.device("dev.a2")]
        let edit = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: " Stage ", observed: observed)
        #expect(edit.change == .changed)
        let entry = try #require(edit.library.entries.first)
        #expect(entry.name.text == " Stage ")
        let kept = entry.rig.devices.map(\.id.rawValue)
        #expect(kept == ["dev.a2", "dev.b", "dev.c"])
        let roles = entry.rig.devices.map(\.role)
        #expect(roles == [nil, nil, nil])
        let required = entry.rig.devices.map(\.required)
        #expect(required == [false, false, false])
        let uids = entry.rig.devices.map(\.uid)
        #expect(uids == ["uid-dev.a2", "uid-dev.b", "uid-dev.c"])
    }

    @Test func captureOfNoPresentDeviceYieldsAnEmptyRig() throws {
        let observed = try [Fixture.device("dev.a", presence: .missing), Fixture.device("dev.b", presence: .stale)]
        let edit = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Empty", observed: observed)
        let entry = try #require(edit.library.entries.first)
        #expect(entry.rig.devices.isEmpty)
        let none = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Empty", observed: [])
        #expect(none.change == .changed)
    }

    @Test func captureLeavesTheSelectionAndOtherRigsAsTheyWere() throws {
        let trio = try Lib.trio(selected: "rig.b")
        let edit = try trio.capturing(id: Lib.rigID("rig.d"), name: "Delta", observed: [Fixture.device("dev.d1")])
        #expect(edit.library.selected == (try Lib.rigID("rig.b")))
        let kept = Array(edit.library.entries.prefix(3))
        #expect(kept == trio.entries)
        #expect(Lib.ids(edit.library) == ["rig.a", "rig.b", "rig.c", "rig.d"])
        let unselected = try Lib.trio().capturing(id: Lib.rigID("rig.d"), name: "Delta", observed: [])
        #expect(unselected.library.selected == nil)
    }

    @Test func captureReportsTooManyObservedBeforeARepeatedObservedID() throws {
        var observed = try Fixture.observedRun(1_024)
        observed.append(try Fixture.device("dev.0000"))
        let refusal = Lib.refusal {
            try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "N", observed: observed)
        }
        #expect(refusal == .rig(.tooManyObserved(count: 1_025, maximum: 1_024)))
    }

    @Test func captureReportsARepeatedObservedIDBeforeAnOverlongName() throws {
        let observed = try [Fixture.device("dev.a"), Fixture.device("dev.a", uid: "other")]
        let long = String(repeating: "n", count: 129)
        let refusal = Lib.refusal {
            try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: long, observed: observed)
        }
        #expect(refusal == .rig(.duplicateObservedDevice(try DeviceID("dev.a"))))
    }

    @Test func captureReportsABlankNameBeforeAnExistingRigID() throws {
        let trio = try Lib.trio()
        let refusal = Lib.refusal { try trio.capturing(id: Lib.rigID("rig.a"), name: " ", observed: []) }
        #expect(refusal == .blankName)
    }

    @Test func captureReportsAnExistingRigIDBeforeAnExistingName() throws {
        let trio = try Lib.trio()
        let refusal = Lib.refusal { try trio.capturing(id: Lib.rigID("rig.a"), name: "Bravo", observed: []) }
        #expect(refusal == .rig(.duplicateRig(try Lib.rigID("rig.a"))))
    }

    @Test func captureReportsAnExistingNameBeforeAFullLibrary() throws {
        let full = try Lib.many(16)
        let refusal = Lib.refusal { try full.capturing(id: Lib.rigID("rig.new"), name: "Rig 0003", observed: []) }
        #expect(refusal == .duplicateName(try Lib.rigID("rig.0003")))
    }

    @Test func captureReportsAFullLibraryBeforeTooManyPresentDevices() throws {
        let full = try Lib.many(16)
        let observed = try Fixture.observedRun(65)
        let refusal = Lib.refusal { try full.capturing(id: Lib.rigID("rig.new"), name: "New", observed: observed) }
        #expect(refusal == .rig(.tooManyRigs(count: 17, maximum: 16)))
    }

    @Test func captureAcceptsADeviceNameThatIsCanonicallyEqualToAnotherRigsName() throws {
        let start = try Lib.library([Lib.entry("rig.a", Fixture.precomposed)])
        let edit = try start.capturing(id: Lib.rigID("rig.b"), name: Fixture.decomposed, observed: [])
        #expect(edit.library.entries.count == 2)
        let same = Lib.refusal { try start.capturing(id: Lib.rigID("rig.b"), name: Fixture.precomposed, observed: []) }
        #expect(same == .duplicateName(try Lib.rigID("rig.a")))
    }

    // MARK: duplicate

    @Test func duplicateCopiesTheDevicesUnderANewIDAndName() throws {
        let trio = try Lib.trio(selected: "rig.c")
        let edit = try trio.duplicating(Lib.rigID("rig.a"), as: Lib.rigID("rig.d"), name: "Alpha copy")
        #expect(edit.change == .changed)
        let source = try #require(edit.library.entry(for: Lib.rigID("rig.a")))
        let copy = try #require(edit.library.entry(for: Lib.rigID("rig.d")))
        #expect(copy.rig.devices == source.rig.devices)
        #expect(copy.name.text == "Alpha copy")
        #expect(source.name.text == "Alpha")
        #expect(edit.library.selected == (try Lib.rigID("rig.c")))
        let kept = Array(edit.library.entries.prefix(3))
        #expect(kept == trio.entries)
    }

    @Test func duplicateReportsAnUnknownSourceBeforeABlankName() throws {
        let trio = try Lib.trio()
        let refusal = Lib.refusal { try trio.duplicating(Lib.rigID("rig.zz"), as: Lib.rigID("rig.d"), name: " ") }
        #expect(refusal == .unknownRig(try Lib.rigID("rig.zz")))
    }

    @Test func duplicateReportsABlankNameBeforeAnExistingRigID() throws {
        let trio = try Lib.trio()
        let refusal = Lib.refusal { try trio.duplicating(Lib.rigID("rig.a"), as: Lib.rigID("rig.b"), name: " ") }
        #expect(refusal == .blankName)
    }

    @Test func duplicateReportsAnExistingRigIDBeforeAnExistingName() throws {
        let trio = try Lib.trio()
        let refusal = Lib.refusal { try trio.duplicating(Lib.rigID("rig.a"), as: Lib.rigID("rig.b"), name: "Charlie") }
        #expect(refusal == .rig(.duplicateRig(try Lib.rigID("rig.b"))))
    }

    @Test func duplicateReportsAnExistingNameBeforeAFullLibrary() throws {
        let full = try Lib.many(16)
        let refusal = Lib.refusal {
            try full.duplicating(Lib.rigID("rig.0001"), as: Lib.rigID("rig.new"), name: "Rig 0002")
        }
        #expect(refusal == .duplicateName(try Lib.rigID("rig.0002")))
    }

    @Test func duplicateRefusesTheSeventeenthRig() throws {
        let sixteen = try Lib.many(16)
        let refusal = Lib.refusal {
            try sixteen.duplicating(Lib.rigID("rig.0001"), as: Lib.rigID("rig.new"), name: "New")
        }
        #expect(refusal == .rig(.tooManyRigs(count: 17, maximum: 16)))
        let fifteen = try Lib.many(15)
        let edit = try fifteen.duplicating(Lib.rigID("rig.0001"), as: Lib.rigID("rig.new"), name: "New")
        #expect(edit.library.entries.count == 16)
    }

    // MARK: rename

    @Test func renameChangesTheNameAndKeepsTheRigAndTheSelection() throws {
        let trio = try Lib.trio(selected: "rig.b")
        let edit = try trio.renaming(Lib.rigID("rig.b"), to: " Bravo two ")
        #expect(edit.change == .changed)
        let names = Lib.names(edit.library)
        #expect(names == ["Alpha", " Bravo two ", "Charlie"])
        #expect(edit.library.selected == (try Lib.rigID("rig.b")))
        let before = try #require(trio.entry(for: Lib.rigID("rig.b")))
        let after = try #require(edit.library.entry(for: Lib.rigID("rig.b")))
        #expect(after.rig == before.rig)
    }

    @Test func renameToTheScalarsAlreadyHeldIsUnchanged() throws {
        let trio = try Lib.trio(selected: "rig.a")
        let edit = try trio.renaming(Lib.rigID("rig.b"), to: "Bravo")
        #expect(edit.change == .unchanged)
        #expect(edit.library == trio)
    }

    @Test func renameToACanonicallyEqualSpellingIsChanged() throws {
        let start = try Lib.library([Lib.entry("rig.a", Fixture.precomposed)])
        let edit = try start.renaming(Lib.rigID("rig.a"), to: Fixture.decomposed)
        #expect(edit.change == .changed)
        let names = Lib.names(edit.library)
        #expect(names == [Fixture.decomposed])
        let name = try #require(Lib.names(edit.library).first)
        #expect(name.unicodeScalars.count == 5)
    }

    @Test func renameToANameAnotherRigHoldsNamesTheHolder() throws {
        let trio = try Lib.trio()
        let refusal = Lib.refusal { try trio.renaming(Lib.rigID("rig.c"), to: "Alpha") }
        #expect(refusal == .duplicateName(try Lib.rigID("rig.a")))
    }

    @Test func renameReportsAnUnknownRigBeforeABlankName() throws {
        let trio = try Lib.trio()
        let refusal = Lib.refusal { try trio.renaming(Lib.rigID("rig.zz"), to: " ") }
        #expect(refusal == .unknownRig(try Lib.rigID("rig.zz")))
    }

    @Test func renameRefusesBlankAndOverlongNames() throws {
        let trio = try Lib.trio()
        let blank = Lib.refusal { try trio.renaming(Lib.rigID("rig.a"), to: "") }
        #expect(blank == .blankName)
        let long = String(repeating: "n", count: 129)
        let over = Lib.refusal { try trio.renaming(Lib.rigID("rig.a"), to: long) }
        #expect(over == .nameTooLong(129))
        let atLimit = try trio.renaming(Lib.rigID("rig.a"), to: String(repeating: "n", count: 128))
        #expect(atLimit.change == .changed)
    }
}
