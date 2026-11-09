import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builders for the rig library limit suite.
private enum LimitFixture {
    typealias Fixture = RigIdentityFixture

    static func rigID(_ raw: String) throws -> RigProfileID { try RigProfileID(raw) }

    static func entry(_ id: String, _ name: String, _ devices: [RigSavedDevice] = []) throws -> RigLibraryEntry {
        try RigLibraryEntry.make(name: name, rig: Fixture.rig(id, devices))
    }

    static func library(_ entries: [RigLibraryEntry], selected: String? = nil) throws -> RigLibrary {
        try RigLibrary.make(entries: entries, selected: selected.map { try RigProfileID($0) })
    }

    /// `rig.a` Alpha (`dev.a1` optional, `dev.a2` with a role), `rig.b` Bravo (`dev.b1`), `rig.c` Charlie (none).
    static func trio(selected: String? = nil) throws -> RigLibrary {
        let alpha = try entry("rig.a", "Alpha", [Fixture.saved("dev.a1", required: false),
                                                 Fixture.saved("dev.a2", role: "rol.main")])
        let bravo = try entry("rig.b", "Bravo", [Fixture.saved("dev.b1")])
        return try library([entry("rig.c", "Charlie"), alpha, bravo], selected: selected)
    }

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

    static func selectedID(_ library: RigLibrary) -> String? { library.selected?.rawValue }
}

/// Reads the four production files of the library from the checkout or from the pure mirror.
private enum LibrarySources {
    static let names = ["RigLibrary", "RigLibrary+Edits", "RigLibraryEntry", "RigLibraryRefusal"]

    static func directory() -> URL? {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let candidates = [root.appendingPathComponent("Shared/Rig/Library"),
                          root.appendingPathComponent("Sources/FluxKlang/Shared/Rig/Library")]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("RigLibrary.swift").path)
        }
    }

    static func texts() throws -> [String] {
        let directory = try #require(directory())
        return try names.map {
            try String(contentsOf: directory.appendingPathComponent($0 + ".swift"), encoding: .utf8)
        }
    }
}

@Suite("Rig library: removal, selection, devices and limits")
struct RigLibraryLimitTests {
    private typealias Lib = LimitFixture
    typealias Fixture = RigIdentityFixture

    // MARK: remove and select

    @Test func removingTheSelectedRigSelectsTheNextRigInIDOrder() throws {
        let first = try Lib.trio(selected: "rig.a").removing(Lib.rigID("rig.a"))
        #expect(first.change == .changed)
        #expect(Lib.selectedID(first.library) == "rig.b")
        let middle = try Lib.trio(selected: "rig.b").removing(Lib.rigID("rig.b"))
        #expect(Lib.selectedID(middle.library) == "rig.c")
        let left = middle.library.entries.map(\.id.rawValue)
        #expect(left == ["rig.a", "rig.c"])
    }

    @Test func removingTheSelectedLastRigSelectsThePreviousRig() throws {
        let edit = try Lib.trio(selected: "rig.c").removing(Lib.rigID("rig.c"))
        #expect(Lib.selectedID(edit.library) == "rig.b")
        let pair = try Lib.library([Lib.entry("rig.a", "A"), Lib.entry("rig.b", "B")], selected: "rig.b")
        let again = try pair.removing(Lib.rigID("rig.b"))
        #expect(Lib.selectedID(again.library) == "rig.a")
    }

    @Test func removingTheSoleRigYieldsTheEmptyLibrary() throws {
        let chosen = try Lib.library([Lib.entry("rig.a", "A")], selected: "rig.a")
        let edit = try chosen.removing(Lib.rigID("rig.a"))
        #expect(edit.change == .changed)
        #expect(edit.library == RigLibrary.empty)
        let unchosen = try Lib.library([Lib.entry("rig.a", "A")]).removing(Lib.rigID("rig.a"))
        #expect(unchosen.library == RigLibrary.empty)
    }

    @Test func removingAnotherRigKeepsTheSelection() throws {
        let trio = try Lib.trio(selected: "rig.b")
        let first = try trio.removing(Lib.rigID("rig.a"))
        #expect(Lib.selectedID(first.library) == "rig.b")
        let last = try trio.removing(Lib.rigID("rig.c"))
        #expect(Lib.selectedID(last.library) == "rig.b")
        let none = try Lib.trio().removing(Lib.rigID("rig.a"))
        #expect(none.library.selected == nil)
    }

    @Test func removingAnUnknownRigIsUnchangedAndEqualToTheInput() throws {
        let trio = try Lib.trio(selected: "rig.a")
        let edit = try trio.removing(Lib.rigID("rig.zz"))
        #expect(edit.change == .unchanged)
        #expect(edit.library == trio)
        let empty = try RigLibrary.empty.removing(Lib.rigID("rig.a"))
        #expect(empty.change == .unchanged)
    }

    @Test func selectingAKnownRigChangesTheSelectionAndNothingElse() throws {
        let trio = try Lib.trio()
        let edit = try trio.selecting(Lib.rigID("rig.b"))
        #expect(edit.change == .changed)
        #expect(Lib.selectedID(edit.library) == "rig.b")
        #expect(edit.library.entries == trio.entries)
    }

    @Test func selectingAnUnknownRigIsRefusedAndNilClearsTheSelection() throws {
        let trio = try Lib.trio(selected: "rig.a")
        let refusal = Lib.refusal { try trio.selecting(Lib.rigID("rig.zz")) }
        #expect(refusal == .unknownRig(try Lib.rigID("rig.zz")))
        let cleared = try trio.selecting(nil)
        #expect(cleared.change == .changed)
        #expect(cleared.library.selected == nil)
    }

    @Test func selectingTheCurrentSelectionIsUnchanged() throws {
        let trio = try Lib.trio(selected: "rig.a")
        let same = try trio.selecting(Lib.rigID("rig.a"))
        #expect(same.change == .unchanged)
        #expect(same.library == trio)
        let none = try Lib.trio().selecting(nil)
        #expect(none.change == .unchanged)
    }

    // MARK: roles and required flags

    @Test func settingARoleChangesThatDeviceAlone() throws {
        let trio = try Lib.trio(selected: "rig.c")
        let edit = try trio.settingRole(RoleID("rol.sub"), of: DeviceID("dev.a1"), in: Lib.rigID("rig.a"))
        #expect(edit.change == .changed)
        let rig = try #require(edit.library.entry(for: Lib.rigID("rig.a"))).rig
        let roles = rig.devices.map { $0.role?.rawValue }
        #expect(roles == ["rol.sub", "rol.main"])
        let required = rig.devices.map(\.required)
        #expect(required == [false, true])
        #expect(Lib.selectedID(edit.library) == "rig.c")
        let others = Array(edit.library.entries.dropFirst())
        #expect(others == Array(trio.entries.dropFirst()))
        let name = try #require(edit.library.entry(for: Lib.rigID("rig.a"))).name.text
        #expect(name == "Alpha")
    }

    @Test func settingARoleToNilClearsItAndTheSameRoleIsUnchanged() throws {
        let trio = try Lib.trio()
        let cleared = try trio.settingRole(nil, of: DeviceID("dev.a2"), in: Lib.rigID("rig.a"))
        #expect(cleared.change == .changed)
        let rig = try #require(cleared.library.entry(for: Lib.rigID("rig.a"))).rig
        let roles = rig.devices.map { $0.role?.rawValue }
        #expect(roles == [nil, nil])
        let same = try trio.settingRole(RoleID("rol.main"), of: DeviceID("dev.a2"), in: Lib.rigID("rig.a"))
        #expect(same.change == .unchanged)
        #expect(same.library == trio)
        let alreadyNil = try trio.settingRole(nil, of: DeviceID("dev.a1"), in: Lib.rigID("rig.a"))
        #expect(alreadyNil.change == .unchanged)
    }

    @Test func twoDevicesOfOneRigMayShareARole() throws {
        let edit = try Lib.trio().settingRole(RoleID("rol.main"), of: DeviceID("dev.a1"), in: Lib.rigID("rig.a"))
        let rig = try #require(edit.library.entry(for: Lib.rigID("rig.a"))).rig
        let roles = rig.devices.map { $0.role?.rawValue }
        #expect(roles == ["rol.main", "rol.main"])
    }

    @Test func settingRequiredChangesThatDeviceAlone() throws {
        let trio = try Lib.trio(selected: "rig.b")
        let edit = try trio.settingRequired(false, of: DeviceID("dev.a2"), in: Lib.rigID("rig.a"))
        #expect(edit.change == .changed)
        let rig = try #require(edit.library.entry(for: Lib.rigID("rig.a"))).rig
        let required = rig.devices.map(\.required)
        #expect(required == [false, false])
        let roles = rig.devices.map { $0.role?.rawValue }
        #expect(roles == [nil, "rol.main"])
        #expect(Lib.selectedID(edit.library) == "rig.b")
        let others = Array(edit.library.entries.dropFirst())
        #expect(others == Array(trio.entries.dropFirst()))
    }

    @Test func settingRequiredToTheCurrentValueIsUnchangedAndFalseClearsIt() throws {
        let trio = try Lib.trio()
        let same = try trio.settingRequired(false, of: DeviceID("dev.a1"), in: Lib.rigID("rig.a"))
        #expect(same.change == .unchanged)
        #expect(same.library == trio)
        let cleared = try trio.settingRequired(false, of: DeviceID("dev.a2"), in: Lib.rigID("rig.a"))
        #expect(cleared.change == .changed)
        let rig = try #require(cleared.library.entry(for: Lib.rigID("rig.a"))).rig
        let required = rig.devices.map(\.required)
        #expect(required == [false, false])
    }

    @Test func deviceEditsRefuseAnUnknownRigBeforeAnUnknownDevice() throws {
        let trio = try Lib.trio()
        let role = Lib.refusal { try trio.settingRole(nil, of: DeviceID("dev.zz"), in: Lib.rigID("rig.zz")) }
        #expect(role == .unknownRig(try Lib.rigID("rig.zz")))
        let flag = Lib.refusal { try trio.settingRequired(true, of: DeviceID("dev.zz"), in: Lib.rigID("rig.zz")) }
        #expect(flag == .unknownRig(try Lib.rigID("rig.zz")))
    }

    @Test func deviceEditsRefuseAnUnknownDeviceAndNameTheRigAndDevice() throws {
        let trio = try Lib.trio()
        let expected = RigLibraryRefusal.unknownDevice(rig: try Lib.rigID("rig.b"), device: try DeviceID("dev.a1"))
        let role = Lib.refusal { try trio.settingRole(nil, of: DeviceID("dev.a1"), in: Lib.rigID("rig.b")) }
        #expect(role == expected)
        let flag = Lib.refusal { try trio.settingRequired(true, of: DeviceID("dev.a1"), in: Lib.rigID("rig.b")) }
        #expect(flag == expected)
    }

    // MARK: capture limits

    @Test func captureAcceptsSixtyFourPresentDevicesAndRefusesSixtyFive() throws {
        let sixtyFour = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Big",
                                                       observed: Fixture.observedRun(64))
        let rig = try #require(sixtyFour.library.entries.first).rig
        #expect(rig.devices.count == 64)
        let over = Lib.refusal {
            try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Big", observed: Fixture.observedRun(65))
        }
        #expect(over == .rig(.tooManyDevices(count: 65, maximum: 64)))
        let wayOver = Lib.refusal {
            try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Big", observed: Fixture.observedRun(70))
        }
        #expect(wayOver == .rig(.tooManyDevices(count: 65, maximum: 64)))
    }

    @Test func captureRefusesTwoPresentDevicesThatShareAUID() throws {
        let observed = try [Fixture.device("dev.b", uid: "same"), Fixture.device("dev.a", uid: "same")]
        let refusal = Lib.refusal {
            try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Twin", observed: observed)
        }
        let expected = RigLibraryRefusal.rig(.duplicateUID(first: try DeviceID("dev.a"), second: try DeviceID("dev.b")))
        #expect(refusal == expected)
    }

    @Test func captureIgnoresAnAbsentDeviceThatSharesAUIDWithAPresentOne() throws {
        let absent = try Fixture.device("dev.b", uid: "same", presence: .missing)
        let observed = try [Fixture.device("dev.a", uid: "same"), absent]
        let edit = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "One", observed: observed)
        let rig = try #require(edit.library.entries.first).rig
        let kept = rig.devices.map(\.id.rawValue)
        #expect(kept == ["dev.a"])
    }

    @Test func captureAccepts1024ObservedDescriptorsAndRefuses1025() throws {
        let missing = try (0..<1_024).map { try Fixture.device("dev.\(Fixture.pad($0))", presence: .missing) }
        let edit = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Many", observed: missing)
        let rig = try #require(edit.library.entries.first).rig
        #expect(rig.devices.isEmpty)
        let over = try missing + [Fixture.device("dev.9999", presence: .missing)]
        let refusal = Lib.refusal {
            try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Many", observed: over)
        }
        #expect(refusal == .rig(.tooManyObserved(count: 1_025, maximum: 1_024)))
    }

    @Test func captureAcceptsTheSixteenthRigAndRefusesTheSeventeenth() throws {
        let fifteen = try Lib.many(15)
        let edit = try fifteen.capturing(id: Lib.rigID("rig.new"), name: "New", observed: [])
        #expect(edit.library.entries.count == 16)
        let refusal = Lib.refusal { try edit.library.capturing(id: Lib.rigID("rig.more"), name: "More", observed: []) }
        #expect(refusal == .rig(.tooManyRigs(count: 17, maximum: 16)))
    }

    @Test func captureAndDuplicateAccept128ByteNamesAndRefuse129() throws {
        let atLimit = String(repeating: "n", count: 128)
        let over = String(repeating: "n", count: 129)
        let trio = try Lib.trio()
        let captured = try trio.capturing(id: Lib.rigID("rig.d"), name: atLimit, observed: [])
        #expect(captured.change == .changed)
        let capturedRefusal = Lib.refusal { try trio.capturing(id: Lib.rigID("rig.d"), name: over, observed: []) }
        #expect(capturedRefusal == .nameTooLong(129))
        let copied = try trio.duplicating(Lib.rigID("rig.a"), as: Lib.rigID("rig.d"), name: atLimit)
        #expect(copied.change == .changed)
        let copiedRefusal = Lib.refusal { try trio.duplicating(Lib.rigID("rig.a"), as: Lib.rigID("rig.d"), name: over) }
        #expect(copiedRefusal == .nameTooLong(129))
    }

    @Test func makeAcceptsSixtyFourDevicesAndRefusesAHandBuiltRigWithSixtyFive() throws {
        let fits = try Fixture.handBuilt("rig.a", Fixture.savedRun(64))
        _ = try RigLibraryEntry.make(name: "Fits", rig: fits)
        let over = try Fixture.handBuilt("rig.a", Fixture.savedRun(65))
        let entry = RigLibraryEntry(name: RigUID("Over"), rig: over)
        let refusal = Lib.refusal { try RigLibrary.make(entries: [entry], selected: nil) }
        #expect(refusal == .rig(.tooManyDevices(count: 65, maximum: 64)))
    }

    // MARK: composition and purity

    @Test func chooseAcceptsAllSixteenRigsOfALibrary() throws {
        let sixteen = try Lib.many(16)
        let result = try RigSelection.choose(rigs: sixteen.savedRigs, observed: [])
        let expected = sixteen.entries.map(\.id)
        #expect(result.choice == .ambiguous(expected))
        #expect(result.reports.count == 16)
    }

    @Test func aCapturedRigIsSelectedUntilADeviceIsMarkedRequired() throws {
        let observed = try [Fixture.device("dev.a")]
        let one = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "One", observed: observed)
        let nothingPresent = try RigSelection.choose(rigs: one.library.savedRigs, observed: [])
        #expect(nothingPresent.choice == .selected(try Lib.rigID("rig.a")))
        let two = try one.library.capturing(id: Lib.rigID("rig.b"), name: "Two", observed: observed)
        let both = try RigSelection.choose(rigs: two.library.savedRigs, observed: observed)
        #expect(both.choice == .ambiguous([try Lib.rigID("rig.a"), try Lib.rigID("rig.b")]))
    }

    @Test func markingTheCapturedDeviceRequiredMakesTheRigDependOnIt() throws {
        let observed = try [Fixture.device("dev.a")]
        let one = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "One", observed: observed)
        let marked = try one.library.settingRequired(true, of: DeviceID("dev.a"), in: Lib.rigID("rig.a"))
        let absent = try RigSelection.choose(rigs: marked.library.savedRigs, observed: [])
        #expect(absent.choice == .none)
        let present = try RigSelection.choose(rigs: marked.library.savedRigs, observed: observed)
        #expect(present.choice == .selected(try Lib.rigID("rig.a")))
    }

    @Test func settingRoleOnALaterRigChangesThatDeviceAlone() throws {
        let trio = try Lib.trio(selected: "rig.c")
        let edit = try trio.settingRole(RoleID("rol.sub"), of: DeviceID("dev.b1"), in: Lib.rigID("rig.b"))
        #expect(edit.change == .changed)
        let rig = try #require(edit.library.entry(for: Lib.rigID("rig.b"))).rig
        let roles = rig.devices.map { $0.role?.rawValue }
        #expect(roles == ["rol.sub"])
        let ids = rig.devices.map(\.id.rawValue)
        #expect(ids == ["dev.b1"])
        let name = try #require(edit.library.entry(for: Lib.rigID("rig.b"))).name.text
        #expect(name == "Bravo")
        #expect(Lib.selectedID(edit.library) == "rig.c")
        #expect(edit.library.entries.first == trio.entries.first)
        #expect(edit.library.entries.last == trio.entries.last)
    }

    @Test func settingRequiredOnALaterRigChangesThatDeviceAlone() throws {
        let trio = try Lib.trio(selected: "rig.c")
        let edit = try trio.settingRequired(false, of: DeviceID("dev.b1"), in: Lib.rigID("rig.b"))
        #expect(edit.change == .changed)
        let rig = try #require(edit.library.entry(for: Lib.rigID("rig.b"))).rig
        let required = rig.devices.map(\.required)
        #expect(required == [false])
        let ids = rig.devices.map(\.id.rawValue)
        #expect(ids == ["dev.b1"])
        #expect(edit.library.entries.first == trio.entries.first)
        #expect(edit.library.entries.last == trio.entries.last)
    }

    @Test func duplicatingALaterRigCopiesThatRigsDevices() throws {
        let trio = try Lib.trio(selected: "rig.c")
        let edit = try trio.duplicating(Lib.rigID("rig.b"), as: Lib.rigID("rig.d"), name: "Bravo copy")
        #expect(edit.change == .changed)
        let source = try #require(trio.entry(for: Lib.rigID("rig.b")))
        let copy = try #require(edit.library.entry(for: Lib.rigID("rig.d")))
        #expect(copy.rig.devices == source.rig.devices)
        #expect(copy.name.text == "Bravo copy")
        let kept = Array(edit.library.entries.prefix(3))
        #expect(kept == trio.entries)
        #expect(Lib.selectedID(edit.library) == "rig.c")
    }

    @Test func captureAcceptsOneBelowEachLimit() throws {
        let sixtyThree = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Big",
                                                        observed: Fixture.observedRun(63))
        let rig = try #require(sixtyThree.library.entries.first).rig
        #expect(rig.devices.count == 63)
        let missing = try (0..<1_023).map { try Fixture.device("dev.\(Fixture.pad($0))", presence: .missing) }
        let many = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: "Many", observed: missing)
        #expect(many.change == .changed)
        let name = String(repeating: "n", count: 127)
        let named = try RigLibrary.empty.capturing(id: Lib.rigID("rig.a"), name: name, observed: [])
        #expect(named.change == .changed)
    }

    @Test func libraryEqualityTellsCanonicallyEqualNamesApart() throws {
        let precomposed = try Lib.library([Lib.entry("rig.a", Fixture.precomposed)])
        let decomposed = try Lib.library([Lib.entry("rig.a", Fixture.decomposed)])
        #expect(precomposed != decomposed)
        let again = try Lib.library([Lib.entry("rig.a", Fixture.precomposed)])
        #expect(precomposed == again)
    }

    @Test(.enabled(if: LibrarySources.directory() != nil))
    func theLibrarySourcesNameNoBannedApi() throws {
        let banned = ["Task", "Clock", "Date", "Double", "Float", "default:", "mutating", "static var", "DispatchQueue",
                      "FileManager", "UserDefaults", "CloudKit", "Codable", "try!", "fatalError", "String(decoding"]
        let texts = try LibrarySources.texts()
        #expect(texts.count == 4)
        for text in texts {
            let found = banned.filter { text.contains($0) }
            #expect(found.isEmpty)
        }
    }
}
