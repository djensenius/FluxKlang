//
//  ControlContractTests+SMFExportV1Record.swift
//  FluxKlangTests
//
//  The media contract v1 SMF `exportRecord` builder (#548 SMF3): the header read byte by byte, the refusals and
//  their order, the loss counts, and the encoding. The synthetic files here hold only a header, so every byte under
//  test is written by the test.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = SMFExportV1RecordRefusal

private let exportID = ExportID(validated: "exp.smf")
private let streamA = StreamID(validated: "str.a.x")
private let streamB = StreamID(validated: "str.b.x")

/// An `MThd` chunk: the magic, `length`, then format, track count and division, each big endian.
private func header(format: UInt16 = 0, tracks: UInt16 = 1, division: UInt16 = 15_360, length: UInt32 = 6,
                    magic: [UInt8] = Array("MThd".utf8)) -> [UInt8] {
    let words = [format, tracks, division].flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    return magic + (0..<4).map { UInt8(truncatingIfNeeded: length >> UInt32(24 - 8 * $0)) } + words
}

private func file(_ bytes: [UInt8], _ losses: [SMFExportLoss: Int] = [:]) -> SMFWriteResult {
    SMFWriteResult(bytes: bytes, losses: SMFExportLossReport(losses: losses), reorderedItems: 0)
}

private func build(_ bytes: [UInt8] = header(), losses: [SMFExportLoss: Int] = [:], streams: [StreamID] = [streamA],
                   id: ExportID = exportID, seq: Int = 1, note: String? = nil) throws(Refusal) -> SMFExportV1Record {
    try SMFExportV1Record.make(file(bytes, losses), streams: streams, exportID: id, seq: seq, note: note)
}

private func refusal(_ bytes: [UInt8] = header(), losses: [SMFExportLoss: Int] = [:], streams: [StreamID] = [streamA],
                     id: ExportID = exportID, seq: Int = 1, note: String? = nil) -> Refusal? {
    do {
        _ = try build(bytes, losses: losses, streams: streams, id: id, seq: seq, note: note)
        return nil
    } catch {
        return error
    }
}

private func json(_ record: SMFExportV1Record) throws -> String {
    try #require(String(data: record.encodedJSON(), encoding: .utf8))
}

private func object(_ record: SMFExportV1Record) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any])
}

private func streams(_ count: Int) throws -> [StreamID] {
    try (0..<count).map { try StreamID("str.s\($0)") }
}

extension ControlContractTests {
    struct SMFExportV1 {
        @Test func buildsFromTheFormat0HeaderThisExportWrites() throws {
            let record = try build()
            #expect(record.seq == 1 && record.exportID == exportID && record.streams == [streamA])
            #expect(record.smfFormat == 0 && record.division == 15_360)
            #expect(record.lossless && record.losses.isEmpty && record.note == nil)
            #expect(SMFExportV1Record.kind == "export" && SMFExportV1Record.format == "smf")
            #expect(try json(record) == #"{"division":15360,"exportId":"exp.smf","format":"smf","kind":"export","#
                + #""losses":{},"lossless":true,"seq":1,"smfFormat":0,"streams":["str.a.x"]}"#)
        }

        @Test func acceptsTheContractExamplesFormat1AtOtherDivisions() throws {
            for division: UInt16 in [960, 480] {
                let record = try build(header(format: 1, tracks: 2, division: division))
                #expect(record.smfFormat == 1 && record.division == division)
                #expect(try json(record).contains(#""division":\#(division)"#))
                #expect(try json(record).contains(#""smfFormat":1"#))
            }
        }

        @Test func readsFormatAndDivisionFromTheirOwnBytes() throws {
            let record = try build(header(format: 1, tracks: 3, division: 0x0140))
            #expect(record.smfFormat == 1 && record.division == 320)
            // Read the other way round, 0x03C0 would be 0xC003, an SMPTE division.
            let swapped = try build(header(format: 0, tracks: 1, division: 0x03C0))
            #expect(swapped.division == 960 && swapped.smfFormat == 0)
        }

        @Test func refusesAnUnreadableHeader() {
            let good = header()
            #expect(refusal([]) == .unreadableHeader)
            #expect(refusal(Array(good.prefix(13))) == .unreadableHeader)
            #expect(refusal(header(magic: Array("RIFF".utf8))) == .unreadableHeader)
            #expect(refusal(header(length: 5)) == .unreadableHeader)
            #expect(refusal(header(length: 7)) == .unreadableHeader)
            #expect(refusal(header(length: 0xFFFF_FFFF)) == .unreadableHeader)
            #expect(refusal(header(length: 8) + [0, 0]) == nil)
        }

        @Test func refusesAFormatAbove1() {
            #expect(refusal(header(format: 2)) == .unsupportedFormat(2))
            #expect(refusal(header(format: 0xFFFF)) == .unsupportedFormat(0xFFFF))
        }

        @Test func refusesASMPTEDivision() {
            #expect(refusal(header(division: 0x8000)) == .smpteDivision(0x8000))
            #expect(refusal(header(division: 0xE728)) == .smpteDivision(0xE728))
        }

        @Test func acceptsOnlyDivisionsThatDivide15360() throws {
            #expect(refusal(header(division: 0)) == .unsupportedDivision(0))
            for division: UInt16 in [7, 15_361, 32_767] {
                #expect(refusal(header(division: division)) == .unsupportedDivision(division))
            }
            for division: UInt16 in [1, 960, 15_360] {
                #expect(try build(header(division: division)).division == division)
            }
        }

        @Test func refusesALossCountBelowOne() {
            #expect(refusal(losses: [.passesOverlaid: 0]) == .invalidLossCount(loss: .passesOverlaid, count: 0))
            #expect(refusal(losses: [.umpOnlyDropped: -3]) == .invalidLossCount(loss: .umpOnlyDropped, count: -3))
        }

        @Test func namesTheFirstBadLossInCategoryOrder() {
            let losses: [SMFExportLoss: Int] = [.groupsFlattened: 0, .velocityDownscaled: -1, .passesOverlaid: 0]
            #expect(refusal(losses: losses) == .invalidLossCount(loss: .velocityDownscaled, count: -1))
        }

        @Test func losslessIsExactlyWhetherThereAreLosses() throws {
            let clean = try build()
            let lossy = try build(losses: [.timingQuantized: 4])
            #expect(clean.lossless && !lossy.lossless)
            #expect(try json(clean).contains(#""lossless":true,"#))
            #expect(try json(lossy).contains(#""lossless":false,"#))
            #expect(try json(lossy).contains(#""losses":{"timingQuantized":4}"#))
        }

        @Test func refusesASeqBelowOne() throws {
            #expect(refusal(seq: 0) == .invalidSeq(0))
            #expect(refusal(seq: -1) == .invalidSeq(-1))
            #expect(try build(seq: 1).seq == 1)
        }

        @Test func refusesAnExportIDOutsideThePattern() {
            for raw in ["Exp.smf", "expsmf", "1exp.smf"] {
                let bad = ExportID(rawValue: raw)
                #expect(bad != nil)
                if let bad { #expect(refusal(id: bad) == .invalidExportID(bad)) }
            }
        }

        @Test func refusesNoRepeatedOrTooManyStreams() throws {
            #expect(refusal(streams: []) == .noStreams)
            #expect(refusal(streams: [streamA, streamB, streamA]) == .duplicateStream(streamA))
            #expect(refusal(streams: try streams(65)) == .tooManyStreams(count: 65))
            let sixtyFour = try streams(64)
            #expect(try build(streams: sixtyFour).streams == sixtyFour)
        }

        @Test func refusesTheFirstStreamOutsideThePattern() throws {
            let bad = try StreamID("str_a")
            let worse = try StreamID("Str.b")
            #expect(refusal(streams: [streamA, bad, worse]) == .invalidStream(bad))
        }

        @Test func keepsTheCallersStreamOrder() throws {
            let record = try build(streams: [streamB, streamA])
            #expect(record.streams == [streamB, streamA])
            #expect(try json(record).contains(#""streams":["str.b.x","str.a.x"]"#))
        }

        @Test func countsNoteBytesNotCharacters() throws {
            #expect(refusal(note: "") == .invalidNote(bytes: 0))
            #expect(refusal(note: "   ") == .invalidNote(bytes: 3))
            #expect(refusal(note: String(repeating: "x", count: 257)) == .invalidNote(bytes: 257))
            #expect(try build(note: String(repeating: "x", count: 256)).note?.utf8.count == 256)
            #expect(try build(note: String(repeating: "é", count: 128)).note?.utf8.count == 256)
            #expect(refusal(note: String(repeating: "é", count: 129)) == .invalidNote(bytes: 258))
        }

        @Test func omitsAnAbsentNoteAndWritesAGivenOne() throws {
            #expect(try !json(build()).contains("note"))
            #expect(try json(build(note: "a note")).contains(#""note":"a note""#))
        }

        @Test func theFirstOffenceWins() throws {
            let bad = try StreamID("str_a")
            let badID = try #require(ExportID(rawValue: "Bad"))
            let broken = header(format: 2)
            let losses: [SMFExportLoss: Int] = [.passesOverlaid: 0]
            #expect(refusal(broken, losses: losses, streams: [], id: badID, seq: 0, note: "") == .invalidSeq(0))
            #expect(refusal(broken, losses: losses, streams: [], id: badID, note: "") == .invalidExportID(badID))
            #expect(refusal(broken, losses: losses, streams: [], note: "") == .noStreams)
            #expect(refusal(broken, losses: losses, streams: try streams(65), note: "") == .tooManyStreams(count: 65))
            #expect(refusal(broken, losses: losses, streams: [bad, bad], note: "") == .duplicateStream(bad))
            #expect(refusal(broken, losses: losses, streams: [bad], note: "") == .invalidStream(bad))
            #expect(refusal(broken, losses: losses, note: "") == .unsupportedFormat(2))
            #expect(refusal(losses: losses, note: "") == .invalidLossCount(loss: .passesOverlaid, count: 0))
            #expect(refusal(note: "") == .invalidNote(bytes: 0))
        }

        @Test func writesExactlyTheSchemasKeysAndNeverNativeUMPOnes() throws {
            let plain = Set(try object(build()).keys)
            let expected: Set = ["seq", "kind", "exportId", "streams", "format", "smfFormat", "division", "lossless",
                                 "losses"]
            #expect(plain == expected)
            #expect(Set(try object(build(note: "n")).keys) == expected.union(["note"]))
            #expect(!plain.contains("origin") && !plain.contains("offsetsNs"))
        }

        @Test func allElevenCategoriesEncodeAsAnObjectUnderTheirContractNames() throws {
            let names = ["timingQuantized", "syntheticTempoMap", "velocityDownscaled", "noteOnVelocityRemapped",
                         "valueDownscaled", "attributeDropped", "perNoteDropped", "umpOnlyDropped",
                         "fidelityUnverified", "passesOverlaid", "groupsFlattened"]
            #expect(SMFExportLoss.allCases.map(\.rawValue) == names)
            var losses: [SMFExportLoss: Int] = [:]
            for (index, loss) in SMFExportLoss.allCases.enumerated() { losses[loss] = index + 1 }
            let record = try build(losses: losses)
            #expect(try json(record) == #"{"division":15360,"exportId":"exp.smf","format":"smf","kind":"export","#
                + #""losses":{"attributeDropped":6,"fidelityUnverified":9,"groupsFlattened":11,"#
                + #""noteOnVelocityRemapped":4,"passesOverlaid":10,"perNoteDropped":7,"syntheticTempoMap":2,"#
                + #""timingQuantized":1,"umpOnlyDropped":8,"valueDownscaled":5,"velocityDownscaled":3},"#
                + #""lossless":false,"seq":1,"smfFormat":0,"streams":["str.a.x"]}"#)
            let written = try #require(try object(record)["losses"] as? [String: Int])
            #expect(written.count == 11)
        }

        @Test func identicalInputsEncodeIdenticallyAndCompareEqual() throws {
            let first = try build(losses: [.passesOverlaid: 2], note: "same")
            let second = try build(losses: [.passesOverlaid: 2], note: "same")
            #expect(first == second && first.hashValue == second.hashValue)
            #expect(Set([first, second]).count == 1)
            #expect(try first.encodedJSON() == second.encodedJSON())
            #expect(try first != build(losses: [.passesOverlaid: 3], note: "same"))
        }
    }
}
