//
//  ProgramRecallTests.swift
//  FluxKlangTests
//
//  The program recall table (#87 PRG1): the builders that the +Order and +Resolve files share, and the limits of
//  `ProgramRecallTable.make` (entry count, channel, bank parts, program, input), each at its limits (input has no
//  invalid value). The table is a pure value: nothing here reads a clock, a device or a port.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ProgramRecallTests {
    static let targetA = ControlTriggerTargetID(validated: "trg.recall.a")
    static let targetB = ControlTriggerTargetID(validated: "trg.recall.b")
    static let targetC = ControlTriggerTargetID(validated: "trg.recall.c")
    static let targetD = ControlTriggerTargetID(validated: "trg.recall.d")
    static let targetE = ControlTriggerTargetID(validated: "trg.recall.e")

    /// What one `resolve` produced: an outcome or a refusal.
    enum Answer: Equatable {
        case outcome(ProgramRecallOutcome)
        case refused(ProgramRecallRefusal)
    }

    /// One received Program Change; the defaults are input 7, channel 1 and bank (0, 0).
    struct Probe {
        var input: UInt32 = 7
        var channel: UInt8 = 1
        var msb: UInt8 = 0
        var lsb: UInt8 = 0
        var program: UInt8
    }

    /// An entry on input 7; a nil bank part is a wildcard.
    static func entry(
        _ program: UInt8,
        msb: UInt8? = nil,
        lsb: UInt8? = nil,
        channel: UInt8 = 1,
        to target: ControlTriggerTargetID = ProgramRecallTests.targetA
    ) -> ProgramRecallEntry {
        ProgramRecallEntry(
            input: MIDIInputID(7), channel: channel, bankMSB: msb, bankLSB: lsb, program: program, target: target
        )
    }

    /// The refusal `make` gives for `entries`, or nil when it builds a table.
    static func refusal(of entries: [ProgramRecallEntry]) -> ProgramRecallRefusal? {
        do throws(ProgramRecallRefusal) {
            _ = try ProgramRecallTable.make(entries)
            return nil
        } catch {
            return error
        }
    }

    static func ask(_ table: ProgramRecallTable, _ probe: Probe) -> Answer {
        let selection = MIDI1ProgramSelection(bankMSB: probe.msb, bankLSB: probe.lsb, program: probe.program)
        do throws(ProgramRecallRefusal) {
            let outcome = try table.resolve(
                input: MIDIInputID(probe.input), channel: probe.channel, selection: selection
            )
            return .outcome(outcome)
        } catch {
            return .refused(error)
        }
    }

    static func mapped(_ target: ControlTriggerTargetID) -> Answer {
        .outcome(.mapped(target))
    }

    static let unmapped = Answer.outcome(.unmapped)

    /// `count` distinct wildcard entries (programs 0...127 on channel 1, then on channel 2 and so on); all are valid
    /// for `count` up to 2048.
    static func distinctEntries(count: Int) -> [ProgramRecallEntry] {
        var result: [ProgramRecallEntry] = []
        for index in 0..<count {
            result.append(entry(UInt8(index % 128), channel: UInt8(1 + index / 128)))
        }
        return result
    }

    /// Two valid entries followed by `bad`, so the refusal index is 2.
    static func withBadThird(_ bad: ProgramRecallEntry) -> [ProgramRecallEntry] {
        [entry(10), entry(11), bad]
    }

    // MARK: - Entry count

    @Test
    func theEntryCountIsAcceptedAtZeroOneAndTwoHundredFiftySixAndRefusedAtTwoHundredFiftySeven() throws {
        let none: ProgramRecallRefusal? = nil
        let atZero = Self.refusal(of: [])
        let atOne = Self.refusal(of: Self.distinctEntries(count: 1))
        let atCap = Self.refusal(of: Self.distinctEntries(count: 256))
        let pastCap = Self.refusal(of: Self.distinctEntries(count: 257))
        let expectedPast: ProgramRecallRefusal? = .tooManyEntries(257)
        #expect(atZero == none)
        #expect(atOne == none)
        #expect(atCap == none)
        #expect(pastCap == expectedPast)
        let built = try ProgramRecallTable.make(Self.distinctEntries(count: 256))
        let builtCount: Int = built.entries.count
        #expect(builtCount == 256)
    }

    @Test
    func anEmptyListBuildsAnEmptyTableThatAnswersUnmappedForAnyProgramChange() throws {
        let table = try ProgramRecallTable.make([])
        let isEmpty: Bool = table.entries.isEmpty
        let answer = Self.ask(table, Probe(program: 5))
        #expect(isEmpty)
        #expect(answer == Self.unmapped)
    }

    // MARK: - Channel, bank and program limits

    @Test
    func aChannelIsAcceptedAtOneAndSixteenAndRefusedAtZeroSeventeenAndTwoHundredFiftyFive() {
        let none: ProgramRecallRefusal? = nil
        let atOne = Self.refusal(of: Self.withBadThird(Self.entry(12, channel: 1)))
        let atSixteen = Self.refusal(of: Self.withBadThird(Self.entry(12, channel: 16)))
        let atZero = Self.refusal(of: Self.withBadThird(Self.entry(12, channel: 0)))
        let atSeventeen = Self.refusal(of: Self.withBadThird(Self.entry(12, channel: 17)))
        let atMaximum = Self.refusal(of: Self.withBadThird(Self.entry(12, channel: 255)))
        let expected: ProgramRecallRefusal? = .invalidChannel(entry: 2)
        #expect(atOne == none)
        #expect(atSixteen == none)
        #expect(atZero == expected)
        #expect(atSeventeen == expected)
        #expect(atMaximum == expected)
    }

    @Test
    func aBankMSBIsAcceptedAtZeroAnd127AndRefusedAt128And255() {
        let none: ProgramRecallRefusal? = nil
        let atZero = Self.refusal(of: Self.withBadThird(Self.entry(12, msb: 0)))
        let atTop = Self.refusal(of: Self.withBadThird(Self.entry(12, msb: 127)))
        let past = Self.refusal(of: Self.withBadThird(Self.entry(12, msb: 128)))
        let atMaximum = Self.refusal(of: Self.withBadThird(Self.entry(12, msb: 255)))
        let expected: ProgramRecallRefusal? = .invalidBank(entry: 2)
        #expect(atZero == none)
        #expect(atTop == none)
        #expect(past == expected)
        #expect(atMaximum == expected)
    }

    @Test
    func aBankLSBIsAcceptedAtZeroAnd127AndRefusedAt128And255() {
        let none: ProgramRecallRefusal? = nil
        let atZero = Self.refusal(of: Self.withBadThird(Self.entry(12, lsb: 0)))
        let atTop = Self.refusal(of: Self.withBadThird(Self.entry(12, lsb: 127)))
        let past = Self.refusal(of: Self.withBadThird(Self.entry(12, lsb: 128)))
        let atMaximum = Self.refusal(of: Self.withBadThird(Self.entry(12, lsb: 255)))
        let expected: ProgramRecallRefusal? = .invalidBank(entry: 2)
        #expect(atZero == none)
        #expect(atTop == none)
        #expect(past == expected)
        #expect(atMaximum == expected)
    }

    @Test
    func aNilBankPartIsAcceptedForEachPartAndForBothParts() {
        let none: ProgramRecallRefusal? = nil
        let neither = Self.refusal(of: [Self.entry(12, msb: nil, lsb: nil)])
        let onlyMSB = Self.refusal(of: [Self.entry(12, msb: 3, lsb: nil)])
        let onlyLSB = Self.refusal(of: [Self.entry(12, msb: nil, lsb: 3)])
        #expect(neither == none)
        #expect(onlyMSB == none)
        #expect(onlyLSB == none)
    }

    @Test
    func aProgramIsAcceptedAtZeroAnd127AndRefusedAt128And255() {
        let none: ProgramRecallRefusal? = nil
        let atZero = Self.refusal(of: Self.withBadThird(Self.entry(0)))
        let atTop = Self.refusal(of: Self.withBadThird(Self.entry(127)))
        let past = Self.refusal(of: Self.withBadThird(Self.entry(128)))
        let atMaximum = Self.refusal(of: Self.withBadThird(Self.entry(255)))
        let expected: ProgramRecallRefusal? = .invalidProgram(entry: 2)
        #expect(atZero == none)
        #expect(atTop == none)
        #expect(past == expected)
        #expect(atMaximum == expected)
    }

    @Test
    func anInputIsAcceptedAtZeroOneAndTheLargestValueAndTheThreeStayApart() throws {
        let ids: [UInt32] = [0, 1, UInt32.max]
        let targets = [Self.targetA, Self.targetB, Self.targetC]
        var entries: [ProgramRecallEntry] = []
        for (id, target) in zip(ids, targets) {
            entries.append(ProgramRecallEntry(
                input: MIDIInputID(id), channel: 1, bankMSB: nil, bankLSB: nil, program: 5, target: target
            ))
        }
        let table = try ProgramRecallTable.make(entries)
        let atZero = Self.ask(table, Probe(input: 0, program: 5))
        let atOne = Self.ask(table, Probe(input: 1, program: 5))
        let atMaximum = Self.ask(table, Probe(input: UInt32.max, program: 5))
        let elsewhere = Self.ask(table, Probe(input: 2, program: 5))
        #expect(atZero == Self.mapped(Self.targetA))
        #expect(atOne == Self.mapped(Self.targetB))
        #expect(atMaximum == Self.mapped(Self.targetC))
        #expect(elsewhere == Self.unmapped)
    }

    // MARK: - Shape of a built table

    @Test
    func severalEntriesMayShareOneTarget() throws {
        let entries = [
            Self.entry(1, to: Self.targetB), Self.entry(2, to: Self.targetB), Self.entry(3, to: Self.targetB)
        ]
        let table = try ProgramRecallTable.make(entries)
        let one = Self.ask(table, Probe(program: 1))
        let three = Self.ask(table, Probe(program: 3))
        #expect(one == Self.mapped(Self.targetB))
        #expect(three == Self.mapped(Self.targetB))
    }

    @Test
    func theBuiltTableKeepsTheEntriesInTheOrderTheCallerGave() throws {
        let given = [Self.entry(9), Self.entry(3), Self.entry(7), Self.entry(1)]
        let table = try ProgramRecallTable.make(given)
        let kept: Bool = table.entries == given
        #expect(kept)
        let firstProgram: UInt8 = try #require(table.entries.first).program
        #expect(firstProgram == 9)
    }
}
