//
//  ProgramRecallTests+Resolve.swift
//  FluxKlangTests
//
//  `ProgramRecallTable.resolve`: a hand-written grid of received Program Changes with the answer written out by hand,
//  precedence of the more specific entry whatever the entry order, the key parts that must all be equal, the
//  wildcard, and the argument checks. The expected answers are literals; no test here reimplements the matcher.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProgramRecallTests {
    /// One received Program Change and the answer written down for it.
    struct Row {
        let probe: Probe
        let expected: Answer
    }

    /// Nine entries: program 5 on channel 1 as a wildcard (A), with MSB 1 (B) and with MSB 1 and LSB 2 (C); program 6
    /// with LSB 9 (D); program 7 with bank (0, 0) (E); program 5 on input 8 (D); program 5 on channel 2 (B); program
    /// 127 on channel 16 with bank (127, 127) (C); program 0 as a wildcard (E).
    static func gridEntries() -> [ProgramRecallEntry] {
        [
            entry(5, to: targetA),
            entry(5, msb: 1, to: targetB),
            entry(5, msb: 1, lsb: 2, to: targetC),
            entry(6, lsb: 9, to: targetD),
            entry(7, msb: 0, lsb: 0, to: targetE),
            ProgramRecallEntry(
                input: MIDIInputID(8), channel: 1, bankMSB: nil, bankLSB: nil, program: 5, target: targetD
            ),
            entry(5, channel: 2, to: targetB),
            entry(127, msb: 127, lsb: 127, channel: 16, to: targetC),
            entry(0, to: targetE)
        ]
    }

    /// The answers written by hand for `gridEntries()`.
    static func gridRows() -> [Row] {
        [
            Row(probe: Probe(program: 5), expected: mapped(targetA)),
            Row(probe: Probe(msb: 1, program: 5), expected: mapped(targetB)),
            Row(probe: Probe(msb: 1, lsb: 2, program: 5), expected: mapped(targetC)),
            Row(probe: Probe(msb: 2, lsb: 2, program: 5), expected: mapped(targetA)),
            Row(probe: Probe(msb: 0, lsb: 2, program: 5), expected: mapped(targetA)),
            Row(probe: Probe(msb: 1, lsb: 3, program: 5), expected: mapped(targetB)),
            Row(probe: Probe(msb: 0, lsb: 9, program: 6), expected: mapped(targetD)),
            Row(probe: Probe(msb: 127, lsb: 9, program: 6), expected: mapped(targetD)),
            Row(probe: Probe(msb: 0, lsb: 8, program: 6), expected: unmapped),
            Row(probe: Probe(program: 7), expected: mapped(targetE)),
            Row(probe: Probe(lsb: 1, program: 7), expected: unmapped),
            Row(probe: Probe(msb: 1, program: 7), expected: unmapped),
            Row(probe: Probe(channel: 2, program: 5), expected: mapped(targetB)),
            Row(probe: Probe(channel: 2, msb: 1, lsb: 2, program: 5), expected: mapped(targetB)),
            Row(probe: Probe(channel: 3, program: 5), expected: unmapped),
            Row(probe: Probe(program: 4), expected: unmapped),
            Row(probe: Probe(input: 8, program: 5), expected: mapped(targetD)),
            Row(probe: Probe(input: 8, msb: 1, lsb: 2, program: 5), expected: mapped(targetD)),
            Row(probe: Probe(input: 8, channel: 2, program: 5), expected: unmapped),
            Row(probe: Probe(input: 9, program: 5), expected: unmapped),
            Row(probe: Probe(input: 0, program: 5), expected: unmapped),
            Row(probe: Probe(channel: 16, msb: 127, lsb: 127, program: 127), expected: mapped(targetC)),
            Row(probe: Probe(channel: 16, msb: 127, lsb: 126, program: 127), expected: unmapped),
            Row(probe: Probe(channel: 16, msb: 126, lsb: 127, program: 127), expected: unmapped),
            Row(probe: Probe(program: 0), expected: mapped(targetE)),
            Row(probe: Probe(msb: 127, lsb: 127, program: 0), expected: mapped(targetE)),
            Row(probe: Probe(channel: 16, program: 0), expected: unmapped)
        ]
    }

    /// The indices of the rows whose answer from `table` is not the expected one.
    static func mismatches(_ table: ProgramRecallTable, in rows: [Row]) -> [Int] {
        var wrong: [Int] = []
        for (index, row) in rows.enumerated() where ask(table, row.probe) != row.expected {
            wrong.append(index)
        }
        return wrong
    }

    @Test
    func everyRowOfTheHandWrittenGridGetsTheAnswerWrittenForIt() throws {
        let table = try ProgramRecallTable.make(Self.gridEntries())
        let rows = Self.gridRows()
        let rowCount: Int = rows.count
        let wrong = Self.mismatches(table, in: rows)
        let none: [Int] = []
        #expect(rowCount == 27)
        #expect(wrong == none)
    }

    @Test
    func theGridGetsTheSameAnswersWhenTheEntriesAreGivenInReverseOrder() throws {
        let table = try ProgramRecallTable.make(Self.gridEntries().reversed())
        let wrong = Self.mismatches(table, in: Self.gridRows())
        let none: [Int] = []
        #expect(wrong == none)
    }

    // MARK: - Precedence

    private static let permutations: [[Int]] = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

    private static func ordered(_ entries: [ProgramRecallEntry], by order: [Int]) -> [ProgramRecallEntry] {
        order.map { entries[$0] }
    }

    @Test
    func anExactEntryBeatsAnMSBOnlyEntryAndAWildcardInEveryOrderOfTheThree() throws {
        let entries = [
            Self.entry(5, to: Self.targetA), Self.entry(5, msb: 1, to: Self.targetB),
            Self.entry(5, msb: 1, lsb: 2, to: Self.targetC)
        ]
        let rows = [
            Row(probe: Probe(msb: 1, lsb: 2, program: 5), expected: Self.mapped(Self.targetC)),
            Row(probe: Probe(msb: 1, lsb: 0, program: 5), expected: Self.mapped(Self.targetB)),
            Row(probe: Probe(msb: 2, lsb: 2, program: 5), expected: Self.mapped(Self.targetA))
        ]
        var wrong = 0
        for order in Self.permutations {
            let table = try ProgramRecallTable.make(Self.ordered(entries, by: order))
            wrong += Self.mismatches(table, in: rows).count
        }
        #expect(wrong == 0)
    }

    @Test
    func anExactEntryBeatsAnLSBOnlyEntryAndAWildcardInEveryOrderOfTheThree() throws {
        let entries = [
            Self.entry(5, to: Self.targetA), Self.entry(5, lsb: 2, to: Self.targetB),
            Self.entry(5, msb: 1, lsb: 2, to: Self.targetC)
        ]
        let rows = [
            Row(probe: Probe(msb: 1, lsb: 2, program: 5), expected: Self.mapped(Self.targetC)),
            Row(probe: Probe(msb: 0, lsb: 2, program: 5), expected: Self.mapped(Self.targetB)),
            Row(probe: Probe(msb: 1, lsb: 3, program: 5), expected: Self.mapped(Self.targetA))
        ]
        var wrong = 0
        for order in Self.permutations {
            let table = try ProgramRecallTable.make(Self.ordered(entries, by: order))
            wrong += Self.mismatches(table, in: rows).count
        }
        #expect(wrong == 0)
    }

    @Test
    func aWildcardAnswersAtEachOfTheFourCornerPairsOfTheBankRange() throws {
        let table = try ProgramRecallTable.make([Self.entry(5, to: Self.targetA)])
        let zeros = Self.ask(table, Probe(msb: 0, lsb: 0, program: 5))
        let maxima = Self.ask(table, Probe(msb: 127, lsb: 127, program: 5))
        let mixedOne = Self.ask(table, Probe(msb: 0, lsb: 127, program: 5))
        let mixedTwo = Self.ask(table, Probe(msb: 127, lsb: 0, program: 5))
        #expect(zeros == Self.mapped(Self.targetA))
        #expect(maxima == Self.mapped(Self.targetA))
        #expect(mixedOne == Self.mapped(Self.targetA))
        #expect(mixedTwo == Self.mapped(Self.targetA))
    }

    /// A latch that was never written reads (0, 0) (see `ProgramRecallTable`); this probes the selection (0, 0) only.
    @Test
    func anExactZeroZeroEntryAndAWildcardBothMatchABankSelectOfZeroZero() throws {
        let both = try ProgramRecallTable.make([
            Self.entry(5, to: Self.targetA), Self.entry(5, msb: 0, lsb: 0, to: Self.targetB)
        ])
        let onlyWildcard = try ProgramRecallTable.make([Self.entry(5, to: Self.targetA)])
        let onlyExact = try ProgramRecallTable.make([Self.entry(5, msb: 0, lsb: 0, to: Self.targetB)])
        let zeroZero = Probe(msb: 0, lsb: 0, program: 5)
        let oneZero = Probe(msb: 1, lsb: 0, program: 5)
        let bothAtZeroZero = Self.ask(both, zeroZero)
        let bothAtOneZero = Self.ask(both, oneZero)
        let wildcardAtZeroZero = Self.ask(onlyWildcard, zeroZero)
        let exactAtZeroZero = Self.ask(onlyExact, zeroZero)
        #expect(bothAtZeroZero == Self.mapped(Self.targetB))
        #expect(bothAtOneZero == Self.mapped(Self.targetA))
        #expect(wildcardAtZeroZero == Self.mapped(Self.targetA))
        #expect(exactAtZeroZero == Self.mapped(Self.targetB))
    }

    // MARK: - Key parts

    @Test
    func aProgramChangeThatDiffersFromTheEntryInOneKeyPartAloneIsUnmapped() throws {
        let entry = ProgramRecallEntry(
            input: MIDIInputID(7), channel: 3, bankMSB: 4, bankLSB: 5, program: 6, target: Self.targetA
        )
        let table = try ProgramRecallTable.make([entry])
        let same = Self.ask(table, Probe(channel: 3, msb: 4, lsb: 5, program: 6))
        let otherInput = Self.ask(table, Probe(input: 6, channel: 3, msb: 4, lsb: 5, program: 6))
        let otherChannel = Self.ask(table, Probe(channel: 2, msb: 4, lsb: 5, program: 6))
        let otherMSB = Self.ask(table, Probe(channel: 3, msb: 5, lsb: 5, program: 6))
        let otherLSB = Self.ask(table, Probe(channel: 3, msb: 4, lsb: 6, program: 6))
        let otherProgram = Self.ask(table, Probe(channel: 3, msb: 4, lsb: 5, program: 7))
        #expect(same == Self.mapped(Self.targetA))
        #expect(otherInput == Self.unmapped)
        #expect(otherChannel == Self.unmapped)
        #expect(otherMSB == Self.unmapped)
        #expect(otherLSB == Self.unmapped)
        #expect(otherProgram == Self.unmapped)
    }

    @Test
    func aTableWithEntriesAnswersUnmappedWhenNoEntryMatches() throws {
        let table = try ProgramRecallTable.make([Self.entry(1), Self.entry(2, to: Self.targetB)])
        let answer = Self.ask(table, Probe(program: 3))
        #expect(answer == Self.unmapped)
    }

    // MARK: - Arguments

    @Test
    func aReceivedChannelIsAcceptedAtOneAndSixteenAndRefusedAtZeroSeventeenAndTwoHundredFiftyFive() throws {
        let table = try ProgramRecallTable.make([
            Self.entry(5, to: Self.targetA), Self.entry(5, channel: 16, to: Self.targetB)
        ])
        let atOne = Self.ask(table, Probe(channel: 1, program: 5))
        let atSixteen = Self.ask(table, Probe(channel: 16, program: 5))
        let atZero = Self.ask(table, Probe(channel: 0, program: 5))
        let atSeventeen = Self.ask(table, Probe(channel: 17, program: 5))
        let atMaximum = Self.ask(table, Probe(channel: 255, program: 5))
        #expect(atOne == Self.mapped(Self.targetA))
        #expect(atSixteen == Self.mapped(Self.targetB))
        #expect(atZero == Answer.refused(.invalidReceivedChannel(0)))
        #expect(atSeventeen == Answer.refused(.invalidReceivedChannel(17)))
        #expect(atMaximum == Answer.refused(.invalidReceivedChannel(255)))
    }

    @Test
    func aReceivedBankMSBIsAcceptedAt127AndRefusedAt128And255AndTheRefusalCarriesTheSelection() throws {
        let table = try ProgramRecallTable.make([Self.entry(5, to: Self.targetA)])
        let atTop = Self.ask(table, Probe(msb: 127, lsb: 3, program: 5))
        let past = Self.ask(table, Probe(msb: 128, lsb: 3, program: 5))
        let atMaximum = Self.ask(table, Probe(msb: 255, lsb: 3, program: 5))
        let pastSelection = MIDI1ProgramSelection(bankMSB: 128, bankLSB: 3, program: 5)
        let maximumSelection = MIDI1ProgramSelection(bankMSB: 255, bankLSB: 3, program: 5)
        #expect(atTop == Self.mapped(Self.targetA))
        #expect(past == Answer.refused(.invalidReceivedSelection(pastSelection)))
        #expect(atMaximum == Answer.refused(.invalidReceivedSelection(maximumSelection)))
    }

    @Test
    func aReceivedBankLSBIsAcceptedAt127AndRefusedAt128And255AndTheRefusalCarriesTheSelection() throws {
        let table = try ProgramRecallTable.make([Self.entry(5, to: Self.targetA)])
        let atTop = Self.ask(table, Probe(msb: 3, lsb: 127, program: 5))
        let past = Self.ask(table, Probe(msb: 3, lsb: 128, program: 5))
        let atMaximum = Self.ask(table, Probe(msb: 3, lsb: 255, program: 5))
        let pastSelection = MIDI1ProgramSelection(bankMSB: 3, bankLSB: 128, program: 5)
        let maximumSelection = MIDI1ProgramSelection(bankMSB: 3, bankLSB: 255, program: 5)
        #expect(atTop == Self.mapped(Self.targetA))
        #expect(past == Answer.refused(.invalidReceivedSelection(pastSelection)))
        #expect(atMaximum == Answer.refused(.invalidReceivedSelection(maximumSelection)))
    }

    @Test
    func aReceivedProgramIsAcceptedAt127AndRefusedAt128And255AndTheRefusalCarriesTheSelection() throws {
        let table = try ProgramRecallTable.make([Self.entry(127, to: Self.targetA)])
        let atTop = Self.ask(table, Probe(msb: 3, lsb: 4, program: 127))
        let past = Self.ask(table, Probe(msb: 3, lsb: 4, program: 128))
        let atMaximum = Self.ask(table, Probe(msb: 3, lsb: 4, program: 255))
        let pastSelection = MIDI1ProgramSelection(bankMSB: 3, bankLSB: 4, program: 128)
        let maximumSelection = MIDI1ProgramSelection(bankMSB: 3, bankLSB: 4, program: 255)
        #expect(atTop == Self.mapped(Self.targetA))
        #expect(past == Answer.refused(.invalidReceivedSelection(pastSelection)))
        #expect(atMaximum == Answer.refused(.invalidReceivedSelection(maximumSelection)))
    }

    @Test
    func aWildcardEntryDoesNotMapAReceivedSelectionThatIsOutOfRange() throws {
        let table = try ProgramRecallTable.make([Self.entry(5, to: Self.targetA)])
        let badMSB = Self.ask(table, Probe(msb: 200, program: 5))
        let badLSB = Self.ask(table, Probe(lsb: 200, program: 5))
        let badMSBSelection = MIDI1ProgramSelection(bankMSB: 200, bankLSB: 0, program: 5)
        let badLSBSelection = MIDI1ProgramSelection(bankMSB: 0, bankLSB: 200, program: 5)
        #expect(badMSB == Answer.refused(.invalidReceivedSelection(badMSBSelection)))
        #expect(badLSB == Answer.refused(.invalidReceivedSelection(badLSBSelection)))
    }
}
