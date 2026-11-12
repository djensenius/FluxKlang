//
//  LibraryRigListTests.swift
//  FluxKlangTests
//
//  The Library "Rigs" section as a value (#99 LIB3): one row per saved rig built from the rig library and the
//  observed devices, the matcher's operating mode as the status, the counts of saved devices by outcome, the
//  detail text, selection that is never inferred, the byte order of rows, the refusals of the observed list, the
//  accessibility labels and the pinned fixed texts. Search is in LibraryRigListTests+Search.swift. The list is a
//  pure value: nothing here scans, reads a view or opens a file.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builders for the rig list suites, all through the production API. Device ids are `dev.<x>`, UIDs `uid-dev.<x>`.
enum LibraryRigFixture {
    static func device(_ id: String, uid: String? = nil,
                       presence: DevicePresence = .present) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: DeviceID(id), kind: .audioInterface, layout: nil, binding: .reported,
            identity: DeviceIdentity(.init(uid: uid ?? "uid-\(id)", evidence: [.deviceUID])), presence: presence
        )
    }

    static func saved(_ id: String, uid: String? = nil, required: Bool = true,
                      role: String? = nil) throws -> RigSavedDevice {
        try RigSavedDevice.make(id: DeviceID(id), uid: uid ?? "uid-\(id)",
                                role: role.map { try RoleID($0) }, required: required)
    }

    static func entry(_ id: String, _ name: String, _ devices: [RigSavedDevice] = []) throws -> RigLibraryEntry {
        try RigLibraryEntry.make(name: name, rig: RigSavedRig.make(id: RigProfileID(id), devices: devices))
    }

    static func library(_ entries: [RigLibraryEntry], selected: String? = nil) throws -> RigLibrary {
        try RigLibrary.make(entries: entries, selected: selected.map { try RigProfileID($0) })
    }

    static func list(_ entries: [RigLibraryEntry], selected: String? = nil,
                     observed: [DeviceDescriptor] = []) throws -> LibraryRigList {
        try LibraryRigList.make(library: library(entries, selected: selected), observed: observed)
    }

    /// The one row of a library holding the single rig `rig.solo` named `Solo`.
    static func solo(_ devices: [RigSavedDevice], observed: [DeviceDescriptor]) throws -> LibraryRigRow {
        let list = try list([entry("rig.solo", "Solo", devices)], observed: observed)
        return try #require(list.rows.first)
    }

    static func row(_ list: LibraryRigList, _ title: String) throws -> LibraryRigRow {
        try #require(list.rows.first { $0.title == title })
    }

    /// matched, renumbered, ambiguous, missing, stale.
    static func tally(_ counts: LibraryRigCounts) -> [Int] {
        [counts.matched, counts.renumbered, counts.ambiguous, counts.missing, counts.stale]
    }

    static func pad(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 4 - text.count)) + text
    }

    static func observedRun(_ count: Int) throws -> [DeviceDescriptor] {
        try (0..<count).map { try device("dev.\(pad($0))") }
    }

    static func permutations<Element>(_ items: [Element]) -> [[Element]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[Element]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    static func refusal<Value>(_ body: () throws -> Value) -> RigIdentityRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? RigIdentityRefusal
        }
    }

    /// Three rigs: Alpha (`rig.a`, one device matched), Bravo (`rig.b`, one device never observed) and Charlie
    /// (`rig.c`, no device), with the observed descriptor of Alpha's device.
    static func trio(selected: String? = nil) throws -> LibraryRigList {
        let entries = try [
            entry("rig.c", "Charlie"),
            entry("rig.b", "Bravo", [saved("dev.b1")]),
            entry("rig.a", "Alpha", [saved("dev.a1")])
        ]
        return try list(entries, selected: selected, observed: [device("dev.a1")])
    }
}

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct LibraryRigListTests {
    private typealias Fixture = LibraryRigFixture

    @Test func anEmptyLibraryHasNoRows() throws {
        #expect(try LibraryRigList.make(library: .empty, observed: []).rows.isEmpty)
        #expect(try LibraryRigList.make(library: .empty, observed: [Fixture.device("dev.a")]).rows.isEmpty)
    }

    @Test func aRigWithNoDevicesGetsARow() throws {
        let row = try Fixture.solo([], observed: [])
        #expect(row.detailText == "No devices")
        #expect(row.status == .full)
        #expect(row.statusText == "Full")
        #expect(Fixture.tally(row.counts) == [0, 0, 0, 0, 0])
        #expect(row.counts.total == 0)
    }

    @Test func aRigWhoseDevicesAllMatchReadsAllMatched() throws {
        let two = try Fixture.solo([Fixture.saved("dev.a"), Fixture.saved("dev.b")],
                                   observed: [Fixture.device("dev.a"), Fixture.device("dev.b")])
        #expect(two.detailText == "2 devices, all matched")
        #expect(two.status == .full)
        let one = try Fixture.solo([Fixture.saved("dev.a")], observed: [Fixture.device("dev.a")])
        #expect(one.detailText == "1 device, all matched")
        #expect(one.status == .full)
        #expect(Fixture.tally(one.counts) == [1, 0, 0, 0, 0])
    }

    @Test func theDocExampleReadsOneMissingAndOneStale() throws {
        let devices = try [Fixture.saved("dev.a"), Fixture.saved("dev.b")]
        let row = try Fixture.solo(devices, observed: [Fixture.device("dev.b", presence: .stale)])
        #expect(row.detailText == "2 devices, 1 missing, 1 stale")
        #expect(Fixture.tally(row.counts) == [0, 0, 0, 1, 1])
        // No device matches, so both required devices are unmatched: Manual or remote, never Partial.
        #expect(row.status == .manualRemote)
        let withThird = try Fixture.solo(devices + [Fixture.saved("dev.c")],
                                         observed: [Fixture.device("dev.b", presence: .stale),
                                                    Fixture.device("dev.c")])
        #expect(withThird.detailText == "3 devices, 1 missing, 1 stale")
        #expect(Fixture.tally(withThird.counts) == [1, 0, 0, 1, 1])
    }

    private struct StatusCase {
        let label: String
        let devices: [RigSavedDevice]
        let observed: [DeviceDescriptor]
        let expected: LibraryRigStatus
    }

    private struct CountCase {
        let label: String
        let observed: [DeviceDescriptor]
        let expected: [Int]
    }

    @Test func statusIsTheMatchersOperatingMode() throws {
        let two = try [Fixture.saved("dev.a"), Fixture.saved("dev.b")]
        let optional = try [Fixture.saved("dev.a"), Fixture.saved("dev.b", required: false)]
        let neither = try [Fixture.saved("dev.a", required: false), Fixture.saved("dev.b", required: false)]
        let first = try Fixture.device("dev.a")
        let moved = try Fixture.device("dev.z", uid: "uid-dev.a")
        let cases = try [
            StatusCase(label: "all required matched", devices: two,
                       observed: [first, Fixture.device("dev.b")], expected: .full),
            StatusCase(label: "some required unmatched", devices: two, observed: [first], expected: .partial),
            StatusCase(label: "no required matched", devices: two, observed: [], expected: .manualRemote),
            StatusCase(label: "only an optional unmatched", devices: optional, observed: [first], expected: .full),
            StatusCase(label: "no device required", devices: neither, observed: [], expected: .full),
            StatusCase(label: "renumbered required counts as matched", devices: optional,
                       observed: [moved], expected: .full),
            StatusCase(label: "renumbered with another unmatched", devices: two, observed: [moved],
                       expected: .partial)
        ]
        for item in cases {
            let row = try Fixture.solo(item.devices, observed: item.observed)
            #expect(row.status == item.expected, Comment(rawValue: item.label))
        }
    }

    @Test func countsClassifyEveryOutcomeExactlyOnce() throws {
        let saved = try [Fixture.saved("dev.a")]
        let cases = try [
            CountCase(label: "matched", observed: [Fixture.device("dev.a")], expected: [1, 0, 0, 0, 0]),
            CountCase(label: "renumbered", observed: [Fixture.device("dev.z", uid: "uid-dev.a")],
                      expected: [0, 1, 0, 0, 0]),
            CountCase(label: "ambiguous",
                      observed: [Fixture.device("dev.y", uid: "uid-dev.a"),
                                 Fixture.device("dev.z", uid: "uid-dev.a")], expected: [0, 0, 1, 0, 0]),
            CountCase(label: "missing presence", observed: [Fixture.device("dev.a", presence: .missing)],
                      expected: [0, 0, 0, 1, 0]),
            CountCase(label: "stale presence", observed: [Fixture.device("dev.a", presence: .stale)],
                      expected: [0, 0, 0, 0, 1]),
            CountCase(label: "never observed", observed: [], expected: [0, 0, 0, 1, 0]),
            CountCase(label: "another uid only", observed: [Fixture.device("dev.q")], expected: [0, 0, 0, 1, 0]),
            CountCase(label: "missing outranks stale",
                      observed: [Fixture.device("dev.y", uid: "uid-dev.a", presence: .stale),
                                 Fixture.device("dev.z", uid: "uid-dev.a", presence: .missing)],
                      expected: [0, 0, 0, 1, 0])
        ]
        for item in cases {
            let row = try Fixture.solo(saved, observed: item.observed)
            #expect(Fixture.tally(row.counts) == item.expected, Comment(rawValue: item.label))
            #expect(row.counts.total == saved.count, Comment(rawValue: item.label))
        }
    }

    @Test func detailListsNonZeroCountsInAFixedOrder() throws {
        let names = ["dev.m", "dev.s", "dev.g", "dev.r"]
        let all = try names.map { try Fixture.saved($0) }
        let observed = try [
            Fixture.device("dev.s", presence: .stale),
            Fixture.device("dev.g1", uid: "uid-dev.g"), Fixture.device("dev.g2", uid: "uid-dev.g"),
            Fixture.device("dev.r9", uid: "uid-dev.r")
        ]
        let row = try Fixture.solo(all, observed: observed)
        #expect(Fixture.tally(row.counts) == [0, 1, 1, 1, 1])
        #expect(row.detailText == "4 devices, 1 missing, 1 stale, 1 ambiguous, 1 renumbered")
        let some = try Fixture.solo([Fixture.saved("dev.a"), Fixture.saved("dev.b"), Fixture.saved("dev.c"),
                                     Fixture.saved("dev.d")], observed: [Fixture.device("dev.c"),
                                                                         Fixture.device("dev.z", uid: "uid-dev.d")])
        #expect(some.detailText == "4 devices, 2 missing, 1 renumbered")
        let single = try Fixture.solo([Fixture.saved("dev.a")], observed: [])
        #expect(single.detailText == "1 device, 1 missing")
        let pair = try Fixture.solo([Fixture.saved("dev.a"), Fixture.saved("dev.b")], observed: [])
        #expect(pair.detailText == "2 devices, 2 missing")
    }

    @Test func noObservedDevicesMakesEverySavedDeviceMissing() throws {
        let required = try Fixture.solo([Fixture.saved("dev.a"), Fixture.saved("dev.b")], observed: [])
        #expect(Fixture.tally(required.counts) == [0, 0, 0, 2, 0])
        #expect(required.status == .manualRemote)
        #expect(required.statusText == "Manual or remote")
        let optional = try Fixture.solo([Fixture.saved("dev.a", required: false),
                                         Fixture.saved("dev.b", required: false)], observed: [])
        #expect(Fixture.tally(optional.counts) == [0, 0, 0, 2, 0])
        #expect(optional.status == .full)
        #expect(optional.detailText == "2 devices, 2 missing")
    }

    @Test func onlyTheChosenRigIsSelected() throws {
        let none = try Fixture.trio()
        #expect(none.rows.map(\.isSelected) == [false, false, false])
        #expect(none.rows.map(\.selectedText) == [nil, nil, nil])
        let chosen = try Fixture.trio(selected: "rig.b")
        #expect(chosen.rows.map(\.title) == ["Alpha", "Bravo", "Charlie"])
        #expect(chosen.rows.map(\.isSelected) == [false, true, false])
        #expect(chosen.rows.map(\.selectedText) == [nil, "Selected", nil])
        let alpha = try Fixture.row(none, "Alpha")
        #expect(alpha.status == .full)
        #expect(alpha.isSelected == false)
        for list in try [none, chosen, Fixture.trio(selected: "rig.a"), Fixture.trio(selected: "rig.c")] {
            #expect(list.rows.map(\.title) == ["Alpha", "Bravo", "Charlie"])
            #expect(list.rows.map(\.status) == [.full, .manualRemote, .full])
            #expect(list.rows.map(\.counts) == none.rows.map(\.counts))
            #expect(list.rows.map(\.detailText) == ["1 device, all matched", "1 device, 1 missing", "No devices"])
        }
    }

    @Test func titlesAreKeptExactlyAsStored() throws {
        let long = String(repeating: "x", count: 128)
        let names = [" Alpha ", "Al  pha", "Éclair \u{1F3B9}", long]
        let entries = try names.enumerated().map { try Fixture.entry("rig.\($0.offset)", $0.element) }
        let list = try Fixture.list(entries)
        #expect(Set(list.rows.map(\.title)) == Set(names))
        #expect(long.utf8.count == 128)
        for (offset, name) in names.enumerated() {
            let row = try Fixture.row(list, name)
            #expect(row.id.rawValue == "rig.\(offset)")
            #expect(row.kindText == "Rig")
        }
    }

    @Test func rowsAreOrderedByLowercasedThenExactUTF8Bytes() throws {
        let names = ["Zed", "apple", "Banana", "cherry"]
        let list = try Fixture.list(names.enumerated().map { try Fixture.entry("rig.\($0.offset)", $0.element) })
        #expect(list.rows.map(\.title) == ["apple", "Banana", "cherry", "Zed"])
        let ties = ["alpha", "Bravo", "Alpha", "ALPHA"]
        let tied = try Fixture.list(ties.enumerated().map { try Fixture.entry("rig.\($0.offset)", $0.element) })
        #expect(tied.rows.map(\.title) == ["ALPHA", "Alpha", "alpha", "Bravo"])
        let wide = ["Éclair", "Zed", "eclair"]
        let bytes = try Fixture.list(wide.enumerated().map { try Fixture.entry("rig.\($0.offset)", $0.element) })
        #expect(bytes.rows.map(\.title) == ["eclair", "Zed", "Éclair"])
    }

    @Test func theOrderNeverDependsOnTheInputOrder() throws {
        let names = ["Delta", "alpha", "Alpha", "Charlie"]
        let expected = ["Alpha", "alpha", "Charlie", "Delta"]
        for arrangement in Fixture.permutations(names) {
            let entries = try arrangement.enumerated().map { try Fixture.entry("rig.\($0.offset)", $0.element) }
            #expect(try Fixture.list(entries).rows.map(\.title) == expected)
            #expect(try Fixture.list(Array(entries.reversed())).rows.map(\.title) == expected)
        }
        let entry = try Fixture.entry("rig.a", "Alpha", [Fixture.saved("dev.a"), Fixture.saved("dev.b"),
                                                          Fixture.saved("dev.c")])
        let observed = try [Fixture.device("dev.a"), Fixture.device("dev.b", presence: .stale),
                            Fixture.device("dev.z", uid: "uid-dev.c")]
        let reference = try Fixture.list([entry], observed: observed)
        for arrangement in Fixture.permutations(observed) {
            #expect(try Fixture.list([entry], observed: arrangement) == reference)
        }
    }

    @Test func theObservedListIsRefusedBeforeAnyRow() throws {
        let one = try Fixture.library([Fixture.entry("rig.a", "A")])
        let tooMany = try Fixture.observedRun(1_025)
        let expected = RigIdentityRefusal.tooManyObserved(count: 1_025, maximum: 1_024)
        #expect(Fixture.refusal { try LibraryRigList.make(library: .empty, observed: tooMany) } == expected)
        #expect(Fixture.refusal { try LibraryRigList.make(library: one, observed: tooMany) } == expected)
        let repeated = try [Fixture.device("dev.b"), Fixture.device("dev.a"), Fixture.device("dev.b"),
                            Fixture.device("dev.a")]
        let duplicate = RigIdentityRefusal.duplicateObservedDevice(try DeviceID("dev.a"))
        #expect(Fixture.refusal { try LibraryRigList.make(library: .empty, observed: repeated) } == duplicate)
        #expect(Fixture.refusal { try LibraryRigList.make(library: one, observed: repeated) } == duplicate)
        let accepted = try LibraryRigList.make(library: one, observed: Fixture.observedRun(1_024))
        #expect(accepted.rows.count == 1)
    }

    @Test func accessibilityLabelsNameTheRowAndItsStatus() throws {
        let entries = try [
            Fixture.entry("rig.f", "Full rig", [Fixture.saved("dev.f1")]),
            Fixture.entry("rig.p", "Partial rig", [Fixture.saved("dev.p1"), Fixture.saved("dev.p2")]),
            Fixture.entry("rig.m", "Manual rig", [Fixture.saved("dev.m1")])
        ]
        let observed = try [Fixture.device("dev.f1"), Fixture.device("dev.p1")]
        let plain = try Fixture.list(entries, observed: observed)
        #expect(plain.rows.map(\.status) == [.full, .manualRemote, .partial])
        #expect(plain.rows.map(\.accessibilityLabel) == [
            "Full rig, Rig, Full, 1 device, all matched",
            "Manual rig, Rig, Manual or remote, 1 device, 1 missing",
            "Partial rig, Rig, Partial, 2 devices, 1 missing"
        ])
        for (selected, expected) in [
            ("rig.f", "Full rig, Rig, Full, 1 device, all matched, Selected"),
            ("rig.m", "Manual rig, Rig, Manual or remote, 1 device, 1 missing, Selected"),
            ("rig.p", "Partial rig, Rig, Partial, 2 devices, 1 missing, Selected")
        ] {
            let list = try Fixture.list(entries, selected: selected, observed: observed)
            let row = try #require(list.rows.first { $0.isSelected })
            #expect(row.accessibilityLabel == expected)
            #expect(list.rows.filter { !$0.isSelected }.allSatisfy { !$0.accessibilityLabel.hasSuffix("Selected") })
        }
    }

    @Test func makeIsDeterministicAndKeepsItsInputs() throws {
        let entries = try [Fixture.entry("rig.b", "B", [Fixture.saved("dev.b")]), Fixture.entry("rig.a", "A")]
        let library = try Fixture.library(entries, selected: "rig.b")
        let observed = try [Fixture.device("dev.z"), Fixture.device("dev.b")]
        let libraryBefore = library
        let observedBefore = observed
        let first = try LibraryRigList.make(library: library, observed: observed)
        let second = try LibraryRigList.make(library: library, observed: observed)
        #expect(first == second)
        #expect(library == libraryBefore)
        #expect(observed == observedBefore)
        #expect(observed.map(\.id.rawValue) == ["dev.z", "dev.b"])
        #expect(library.entries.map(\.id.rawValue) == ["rig.a", "rig.b"])
    }

    @Test func fixedTextsArePinned() {
        #expect(LibraryRigText.kind == "Rig")
        #expect(LibraryRigStatus.allCases == [.full, .partial, .manualRemote])
        #expect(LibraryRigStatus.allCases.map(LibraryRigText.status) == ["Full", "Partial", "Manual or remote"])
        #expect(LibraryRigText.selected == "Selected")
        #expect(LibraryRigText.noDevices == "No devices")
        #expect(LibraryRigText.allMatched == "all matched")
        #expect(LibraryRigStatus(mode: .full) == .full)
        #expect(LibraryRigStatus(mode: .partial(missing: [])) == .partial)
        #expect(LibraryRigStatus(mode: .manualRemote) == .manualRemote)
    }

    @Test func deviceCountsAreSingularOrPlural() throws {
        let one = try Fixture.solo([Fixture.saved("dev.a")], observed: [Fixture.device("dev.a")])
        #expect(one.detailText == "1 device, all matched")
        let three = try Fixture.solo([Fixture.saved("dev.a"), Fixture.saved("dev.b"), Fixture.saved("dev.c")],
                                     observed: [Fixture.device("dev.a"), Fixture.device("dev.b"),
                                                Fixture.device("dev.c")])
        #expect(three.detailText == "3 devices, all matched")
        #expect(three.counts.total == 3)
    }
}
