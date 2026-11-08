//
//  ProgramRecallTests+Order.swift
//  FluxKlangTests
//
//  The order in which `ProgramRecallTable.make` and `resolve` report a refusal when an input holds two defects, the
//  overlap rule of `make` (which pairs are refused, which are allowed, which pair is reported) and the scan of the
//  three production files for forbidden text.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProgramRecallTests {
    // MARK: - Refusal order

    @Test
    func tooManyEntriesIsReportedBeforeAnInvalidChannelInTheFirstEntry() {
        let entries = [Self.entry(0, channel: 0)] + Self.distinctEntries(count: 256)
        let refusal = Self.refusal(of: entries)
        let expected: ProgramRecallRefusal? = .tooManyEntries(257)
        #expect(refusal == expected)
    }

    @Test
    func anInvalidChannelIsReportedBeforeAnInvalidBankInTheSameEntry() {
        let refusal = Self.refusal(of: [Self.entry(5, msb: 128, channel: 0)])
        let expected: ProgramRecallRefusal? = .invalidChannel(entry: 0)
        #expect(refusal == expected)
    }

    @Test
    func anInvalidBankIsReportedBeforeAnInvalidProgramInTheSameEntryForEitherBankPart() {
        let withMSB = Self.refusal(of: [Self.entry(128, msb: 128)])
        let withLSB = Self.refusal(of: [Self.entry(128, lsb: 128)])
        let expected: ProgramRecallRefusal? = .invalidBank(entry: 0)
        #expect(withMSB == expected)
        #expect(withLSB == expected)
    }

    @Test
    func anInvalidEntryIsReportedBeforeAnOverlapBetweenTwoEarlierValidEntries() {
        let entries = [Self.entry(5), Self.entry(5, to: Self.targetB), Self.entry(128)]
        let refusal = Self.refusal(of: entries)
        let expected: ProgramRecallRefusal? = .invalidProgram(entry: 2)
        #expect(refusal == expected)
    }

    @Test
    func aDefectInAnEarlierEntryIsReportedBeforeADefectOfAnotherKindInALaterEntry() {
        let programThenChannel = Self.refusal(of: [Self.entry(128), Self.entry(5, channel: 0)])
        let bankThenChannel = Self.refusal(of: [Self.entry(5, msb: 128), Self.entry(6, channel: 0)])
        let channelThenProgram = Self.refusal(of: [Self.entry(5, channel: 0), Self.entry(128)])
        let expectedProgram: ProgramRecallRefusal? = .invalidProgram(entry: 0)
        let expectedBank: ProgramRecallRefusal? = .invalidBank(entry: 0)
        let expectedChannel: ProgramRecallRefusal? = .invalidChannel(entry: 0)
        #expect(programThenChannel == expectedProgram)
        #expect(bankThenChannel == expectedBank)
        #expect(channelThenProgram == expectedChannel)
    }

    @Test
    func aReceivedChannelIsRefusedBeforeAReceivedSelectionWhenBothAreInvalid() throws {
        let table = try ProgramRecallTable.make([Self.entry(5)])
        let both = Self.ask(table, Probe(channel: 0, program: 128))
        let expected = Answer.refused(.invalidReceivedChannel(0))
        #expect(both == expected)
    }

    // MARK: - Overlap refused

    @Test
    func twoEntriesWithTheSameKeyAreRefusedAsOverlappingWithTheSameBankScopeWhateverTheTarget() {
        let exactSame = Self.refusal(of: [
            Self.entry(5, msb: 1, lsb: 2), Self.entry(5, msb: 1, lsb: 2)
        ])
        let exactOtherTarget = Self.refusal(of: [
            Self.entry(5, msb: 1, lsb: 2), Self.entry(5, msb: 1, lsb: 2, to: Self.targetB)
        ])
        let wildcards = Self.refusal(of: [Self.entry(5), Self.entry(5, to: Self.targetB)])
        let msbOnly = Self.refusal(of: [Self.entry(5, msb: 3), Self.entry(5, msb: 3, to: Self.targetB)])
        let lsbOnly = Self.refusal(of: [Self.entry(5, lsb: 3), Self.entry(5, lsb: 3, to: Self.targetB)])
        let expected: ProgramRecallRefusal? = .overlappingEntries(first: 0, second: 1)
        #expect(exactSame == expected)
        #expect(exactOtherTarget == expected)
        #expect(wildcards == expected)
        #expect(msbOnly == expected)
        #expect(lsbOnly == expected)
    }

    @Test
    func anMSBOnlyEntryAndAnLSBOnlyEntryOfOneProgramAreRefusedEvenWhenAnExactEntryShadowsBoth() {
        let pair = Self.refusal(of: [Self.entry(5, msb: 5), Self.entry(5, lsb: 7)])
        let shadowed = Self.refusal(of: [
            Self.entry(5, msb: 5), Self.entry(5, lsb: 7), Self.entry(5, msb: 5, lsb: 7)
        ])
        let expected: ProgramRecallRefusal? = .overlappingEntries(first: 0, second: 1)
        #expect(pair == expected)
        #expect(shadowed == expected)
    }

    @Test
    func theReportedOverlapIsTheFirstPairInScanOrderWithTheFirstIndexAscendingBeforeTheSecond() {
        let laterPairFirst = Self.refusal(of: [
            Self.entry(1), Self.entry(2), Self.entry(1, to: Self.targetB),
            Self.entry(7), Self.entry(7, to: Self.targetC)
        ])
        let lowerFirstWins = Self.refusal(of: [
            Self.entry(1), Self.entry(2), Self.entry(2, to: Self.targetB), Self.entry(1, to: Self.targetC)
        ])
        let threeWay = Self.refusal(of: [
            Self.entry(1), Self.entry(1, to: Self.targetB), Self.entry(1, to: Self.targetC)
        ])
        let expectedLater: ProgramRecallRefusal? = .overlappingEntries(first: 0, second: 2)
        let expectedLower: ProgramRecallRefusal? = .overlappingEntries(first: 0, second: 3)
        let expectedThree: ProgramRecallRefusal? = .overlappingEntries(first: 0, second: 1)
        #expect(laterPairFirst == expectedLater)
        #expect(lowerFirstWins == expectedLower)
        #expect(threeWay == expectedThree)
    }

    @Test
    func anOverlapBetweenTwoLaterEntriesIsReportedWithTheirOwnIndices() {
        let entries = [Self.entry(1), Self.entry(2), Self.entry(3), Self.entry(3, to: Self.targetB)]
        let refusal = Self.refusal(of: entries)
        let expected: ProgramRecallRefusal? = .overlappingEntries(first: 2, second: 3)
        #expect(refusal == expected)
    }

    // MARK: - Overlap allowed

    @Test
    func entriesOfUnequalSpecificityMayOverlapInEitherOrder() {
        let none: ProgramRecallRefusal? = nil
        let wildcard = Self.entry(5)
        let onePart = Self.entry(5, msb: 1, to: Self.targetB)
        let exact = Self.entry(5, msb: 1, lsb: 2, to: Self.targetC)
        let lsbPart = Self.entry(5, lsb: 2, to: Self.targetD)
        let wildcardExact = Self.refusal(of: [wildcard, exact])
        let exactWildcard = Self.refusal(of: [exact, wildcard])
        let onePartExact = Self.refusal(of: [onePart, exact])
        let exactLSBPart = Self.refusal(of: [exact, lsbPart])
        let wildcardOnePart = Self.refusal(of: [wildcard, onePart])
        let allThree = Self.refusal(of: [wildcard, onePart, exact])
        #expect(wildcardExact == none)
        #expect(exactWildcard == none)
        #expect(onePartExact == none)
        #expect(exactLSBPart == none)
        #expect(wildcardOnePart == none)
        #expect(allThree == none)
    }

    @Test
    func entriesWithDifferentBankValuesOfTheSameSpecificityDoNotOverlap() {
        let none: ProgramRecallRefusal? = nil
        let msbs = Self.refusal(of: [Self.entry(5, msb: 1), Self.entry(5, msb: 2, to: Self.targetB)])
        let lsbs = Self.refusal(of: [Self.entry(5, lsb: 1), Self.entry(5, lsb: 2, to: Self.targetB)])
        let exactLSBs = Self.refusal(of: [
            Self.entry(5, msb: 1, lsb: 2), Self.entry(5, msb: 1, lsb: 3, to: Self.targetB)
        ])
        let exactMSBs = Self.refusal(of: [
            Self.entry(5, msb: 1, lsb: 2), Self.entry(5, msb: 4, lsb: 2, to: Self.targetB)
        ])
        let swapped = Self.refusal(of: [
            Self.entry(5, msb: 1, lsb: 2), Self.entry(5, msb: 2, lsb: 1, to: Self.targetB)
        ])
        #expect(msbs == none)
        #expect(lsbs == none)
        #expect(exactLSBs == none)
        #expect(exactMSBs == none)
        #expect(swapped == none)
    }

    @Test
    func entriesThatDifferInProgramChannelOrInputDoNotOverlap() {
        let none: ProgramRecallRefusal? = nil
        let programs = Self.refusal(of: [Self.entry(5), Self.entry(6, to: Self.targetB)])
        let channels = Self.refusal(of: [Self.entry(5, channel: 1), Self.entry(5, channel: 2, to: Self.targetB)])
        let other = ProgramRecallEntry(
            input: MIDIInputID(8), channel: 1, bankMSB: nil, bankLSB: nil, program: 5, target: Self.targetB
        )
        let inputs = Self.refusal(of: [Self.entry(5), other])
        #expect(programs == none)
        #expect(channels == none)
        #expect(inputs == none)
    }

    @Test
    func aMSBOnlyEntryAndAnLSBOnlyEntryOfDifferentProgramsDoNotOverlap() {
        let none: ProgramRecallRefusal? = nil
        let refusal = Self.refusal(of: [Self.entry(5, msb: 5), Self.entry(6, lsb: 7, to: Self.targetB)])
        #expect(refusal == none)
    }

    // MARK: - Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Control/ProgramRecall",
            "../../Sources/FluxKlang/Shared/Control/ProgramRecall"
        ]
        let marker = "ProgramRecallTable.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["Ta", "sk"].joined(), ["Cl", "ock"].joined(), ["Da", "te"].joined(), ["Dispatch", "Queue"].joined(),
            ["Swift", "UI"].joined(), ["Dou", "ble"].joined(), ["Flo", "at"].joined(), ["defa", "ult:"].joined(),
            ["imp", "ort "].joined(), ["mutat", "ing"].joined(), ["static", " var"].joined(),
            ["nonisolated", "(unsafe)"].joined()
        ]
    }

    private static func containsBytes(_ needle: String, in haystack: String) -> Bool {
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard !wanted.isEmpty, wanted.count <= bytes.count else { return false }
        let last = bytes.count - wanted.count
        for start in 0...last {
            var matched = true
            for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    /// Whether `text` declares a function whose name is an operator: the text `func` and a space followed by one of
    /// `+ - * / < > = ! & | % ^ ~`.
    private static func declaresOperator(in text: String) -> Bool {
        let bytes = Array(text.utf8)
        let marker = Array("func ".utf8)
        let operators = Set(Array("+-*/<>=!&|%^~".utf8))
        guard bytes.count > marker.count else { return false }
        for start in 0..<(bytes.count - marker.count) {
            var matched = true
            for offset in 0..<marker.count where bytes[start + offset] != marker[offset] {
                matched = false
                break
            }
            if matched, operators.contains(bytes[start + marker.count]) { return true }
        }
        return false
    }

    /// Looks for each text of `forbiddenSourceWords()` and for an operator declaration in the three production files.
    /// The search is over the raw bytes, so a text in a comment is found too, and an API that the list does not name
    /// is not. It is skipped when the sources are not next to the tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the program recall sources are not next to the tests"))
    func theThreeProductionFilesContainNoForbiddenTextAndNoOperatorDeclaration() throws {
        let directory = try #require(Self.sourceDirectory(), "the program recall sources are not next to the tests")
        let names = ["ProgramRecallTable.swift", "ProgramRecallRefusal.swift", "ProgramRecallNumbering.swift"]
        var hits: [String] = []
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            for word in Self.forbiddenSourceWords() where Self.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
            if Self.declaresOperator(in: text) { hits.append("\(name): operator declaration") }
        }
        #expect(hits.isEmpty)
    }
}
