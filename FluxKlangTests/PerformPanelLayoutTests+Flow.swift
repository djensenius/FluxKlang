//
//  PerformPanelLayoutTests+Flow.swift
//  FluxKlangTests
//
//  The refusals of the perform panel layout and their order (#102 PNL1). Every order claim has a fixture that holds
//  both defects.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformPanelLayoutTests {
    /// A button on a decibel parameter: refused as a kind and unit mismatch.
    static func mismatched(_ number: Int, group: String? = nil, label: String? = nil) throws -> PerformPanelEntry {
        try entry(number, kind: .button, group: group, unit: .decibels, label: label)
    }

    @Test func eachRefusalAloneIsReportedWithItsIndexAndItsPayload() throws {
        let emptyGroup = [try Self.entry(0), try Self.entry(1), try Self.entry(2, group: "")]
        let emptyLabel = [try Self.entry(0), try Self.entry(1, label: "")]
        let sameTarget = [try Self.entry(0), try Self.entry(1), try Self.entry(0, label: "Other")]
        let sameLabel = [try Self.entry(0), try Self.entry(1), try Self.entry(2, label: "Cell 0")]
        let mismatch = [try Self.entry(0), try Self.entry(1), try Self.entry(2), try Self.mismatched(3)]
        var seventeen: [PerformPanelEntry] = []
        for number in 0..<17 { seventeen.append(try Self.entry(number, group: "G\(number)")) }
        let cases: [([PerformPanelEntry], PerformPanelRefusal)] = [
            (emptyGroup, .invalidGroupLabel(index: 2, bytes: 0)),
            (mismatch, .kindUnitMismatch(index: 3, kind: .button, unit: .decibels)),
            (emptyLabel, .cell(index: 1, refusal: .emptyLabel)),
            (sameTarget, .duplicateTarget(Self.id(0))),
            (sameLabel, .duplicateLabel(index: 2)),
            (seventeen, .tooManyGroups(count: 17))
        ]
        for (panel, expected) in cases {
            let wanted: PerformPanelRefusal? = expected
            #expect(Self.refusal(panel) == wanted)
        }
    }

    @Test func aCellRefusalCarriesTheIndexAndTheModelsOwnRefusalForAnOutOfRangeValue() throws {
        var bad = try Self.entry(3)
        bad.input.value = ParameterValue(value: 99, unit: .decibels)
        let panel = [try Self.entry(0), try Self.entry(1), try Self.entry(2), bad]
        let inner = PerformCellRefusal.valueRefused(.outOfRange(99, lower: -120, upper: 6))
        let expected: PerformPanelRefusal? = .cell(index: 3, refusal: inner)
        #expect(Self.refusal(panel) == expected)
    }

    @Test func tooManyEntriesIsReportedBeforeAnyEntryIsChecked() throws {
        var panel = try Self.entries(129)
        try #require(panel.count > 2)
        panel[0].group = ""
        panel[1] = try Self.mismatched(1)
        panel[2].input.labels.cell = ""
        let expected: PerformPanelRefusal? = .tooManyEntries(count: 129)
        #expect(Self.refusal(panel) == expected)
        var allowed = panel
        allowed.removeLast()
        let first: PerformPanelRefusal? = .invalidGroupLabel(index: 0, bytes: 0)
        #expect(Self.refusal(allowed) == first)
    }

    @Test func anInvalidGroupLabelIsReportedBeforeAKindAndUnitMismatchOfTheSameEntry() throws {
        let both = try Self.mismatched(1, group: "")
        let panel = [try Self.entry(0), both]
        let expected: PerformPanelRefusal? = .invalidGroupLabel(index: 1, bytes: 0)
        #expect(Self.refusal(panel) == expected)
    }

    @Test func aKindAndUnitMismatchIsReportedBeforeACellRefusalOfTheSameEntry() throws {
        let both = try Self.mismatched(1, label: "")
        let panel = [try Self.entry(0), both]
        let expected: PerformPanelRefusal? = .kindUnitMismatch(index: 1, kind: .button, unit: .decibels)
        #expect(Self.refusal(panel) == expected)
    }

    @Test func theEarliestFailingEntryDecidesWhateverDefectsLaterEntriesHold() throws {
        let cellDefect = try Self.entry(1, label: "")
        let groupDefect = try Self.entry(2, group: "")
        let forward = [try Self.entry(0), cellDefect, groupDefect]
        let backward = [try Self.entry(0), groupDefect, cellDefect]
        let first: PerformPanelRefusal? = .cell(index: 1, refusal: .emptyLabel)
        let second: PerformPanelRefusal? = .invalidGroupLabel(index: 1, bytes: 0)
        #expect(Self.refusal(forward) == first)
        #expect(Self.refusal(backward) == second)
    }

    @Test func everyEntryDefectOfALaterEntryOutranksADuplicateTargetOfEarlierEntries() throws {
        let duplicate = try Self.entry(0, label: "Other")
        let later: [(PerformPanelEntry, PerformPanelRefusal)] = [
            (try Self.entry(3, group: ""), .invalidGroupLabel(index: 3, bytes: 0)),
            (try Self.mismatched(3), .kindUnitMismatch(index: 3, kind: .button, unit: .decibels)),
            (try Self.entry(3, label: ""), .cell(index: 3, refusal: .emptyLabel))
        ]
        for (defect, expected) in later {
            let panel = [try Self.entry(0), try Self.entry(1), duplicate, defect]
            let wanted: PerformPanelRefusal? = expected
            #expect(Self.refusal(panel) == wanted)
        }
    }

    @Test func aDuplicateTargetIsReportedBeforeADuplicateLabelWhicheverComesFirst() throws {
        let first = try Self.entry(0)
        let sharedA = try Self.entry(1, label: "Shared")
        let sharedB = try Self.entry(2, label: "Shared")
        let sameTarget = try Self.entry(0, label: "Other")
        let labelFirst = [first, sharedA, sharedB, sameTarget]
        let targetFirst = [first, sameTarget, sharedA, sharedB]
        let expected: PerformPanelRefusal? = .duplicateTarget(Self.id(0))
        #expect(Self.refusal(labelFirst) == expected)
        #expect(Self.refusal(targetFirst) == expected)
        let both = [first, try Self.entry(0)]
        #expect(Self.refusal(both) == expected)
    }

    @Test func aDuplicateLabelOrTargetIsReportedBeforeTooManyGroups() throws {
        var labelled: [PerformPanelEntry] = []
        var targeted: [PerformPanelEntry] = []
        for number in 0..<16 {
            labelled.append(try Self.entry(number, group: "G\(number)"))
            targeted.append(try Self.entry(number, group: "G\(number)"))
        }
        labelled.append(try Self.entry(16, group: "G16", label: "Cell 0"))
        targeted.append(try Self.entry(0, group: "G16", label: "Other"))
        let sameLabel: PerformPanelRefusal? = .duplicateLabel(index: 16)
        let sameTarget: PerformPanelRefusal? = .duplicateTarget(Self.id(0))
        #expect(Self.refusal(labelled) == sameLabel)
        #expect(Self.refusal(targeted) == sameTarget)
    }

    @Test func aDuplicateTargetIsTheSecondOccurrenceFirstMetInIndexOrder() throws {
        let panel = [
            try Self.entry(0), try Self.entry(1), try Self.entry(0, label: "X0"), try Self.entry(1, label: "X1"),
            try Self.entry(0, label: "Y0")
        ]
        let expected: PerformPanelRefusal? = .duplicateTarget(Self.id(0))
        #expect(Self.refusal(panel) == expected)
        try #require(panel.count == 5)
        let swapped = [panel[1], panel[0], panel[3], panel[2]]
        let other: PerformPanelRefusal? = .duplicateTarget(Self.id(1))
        #expect(Self.refusal(swapped) == other)
    }

    @Test func labelsAreEqualOnlyWhenTheirUnicodeScalarsAreEqual() throws {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        #expect(precomposed == decomposed)
        let accepted = [try Self.entry(0, label: precomposed), try Self.entry(1, label: decomposed)]
        #expect(Self.cells(try Self.build(accepted)).count == 2)
        let same = [try Self.entry(0, label: decomposed), try Self.entry(1, label: decomposed)]
        let expected: PerformPanelRefusal? = .duplicateLabel(index: 1)
        #expect(Self.refusal(same) == expected)
        let cased = [try Self.entry(0, label: "mains"), try Self.entry(1, label: "Mains")]
        #expect(Self.cells(try Self.build(cased)).count == 2)
    }

    @Test func aRefusalWithAPreviousLayoutIsReportedAndThePreviousStillDecidesWhatIsAnnounced() throws {
        let good = [try Self.entry(0), Self.waiting(try Self.entry(1, group: "Mains"))]
        let before = try Self.build(good)
        let bad = [try Self.entry(0), try Self.entry(0, label: "Other")]
        let grid = try PerformPanelGrid.make(regularColumns: 4, compactColumns: 2)
        #expect(throws: PerformPanelRefusal.duplicateTarget(Self.id(0))) {
            try PerformPanelLayout.make(entries: bad, grid: grid, width: .regular, previous: before)
        }
        let withPrevious = try Self.build(good, previous: before)
        let withoutPrevious = try Self.build(good)
        let announced: [ParameterID] = Self.ids([1])
        #expect(withPrevious.pickupAnnouncements.isEmpty)
        #expect(withoutPrevious.pickupAnnouncements == announced)
        #expect(before.pickupAnnouncements == announced)
    }
}
