//
//  ControlContractTests+AnchorV1.swift
//  FluxKlangTests
//
//  The media contract v1 `anchorRecord` builder (#84 AXR1): golden example records byte for byte, the
//  numeric boundaries, the refusals and their order, the record's shape, and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = AnchorV1RecordRefusal

private let mainClock = ClockID(validated: "smp.main")

/// The musical part of a test anchor; `musicalMap` is set by `makeAnchor`.
private struct Mus {
    let transport: Int
    let ticks: Int64
    let loop: UInt32

    init(_ transport: Int, _ ticks: Int64, _ loop: UInt32) {
        (self.transport, self.ticks, self.loop) = (transport, ticks, loop)
    }
}

private func makeAnchor(clock: ClockID = mainClock, generation: Int = 1, frame: Int64 = 0, host: UInt64 = 0,
                        musical: Mus? = nil, map: Int = 1) throws -> ClockAnchor {
    let stamp = try musical.map {
        MusicalStamp(transport: try Generation($0.transport), musicalMap: try Generation(map), ticks: $0.ticks,
                     loopIteration: $0.loop)
    }
    return ClockAnchor(sample: SampleStamp(clock: clock, generation: try Generation(generation), frame: frame),
                       host: HostStamp(ticks: host), musical: stamp)
}

private func anchorRefusal(_ anchor: ClockAnchor, seq: Int = 1, note: String? = nil) -> Refusal? {
    do {
        _ = try AnchorV1Record.make(anchor, seq: seq, note: note)
        return nil
    } catch {
        return error
    }
}

private func anchorJSON(_ anchor: ClockAnchor, seq: Int = 1, note: String? = nil) throws -> String {
    let data = try AnchorV1Record.make(anchor, seq: seq, note: note).encodedJSON()
    return try #require(String(data: data, encoding: .utf8))
}

/// A golden `anchorRecord` from a media contract example (`<example> seq <n>`), keys sorted, compact. Where an
/// example writes `"loopIteration": 0` the JSON omits it: the builder never writes a zero.
private struct GoldenAnchor {
    let label: String
    let seq: Int
    let generation: Int
    let frame: Int64
    let host: UInt64
    let musical: Mus?
    let json: String

    init(_ label: String, _ seq: Int, _ generation: Int, _ frame: Int64, _ host: UInt64, musical: Mus? = nil,
         _ json: String) {
        (self.label, self.seq, self.generation, self.frame) = (label, seq, generation, frame)
        (self.host, self.musical, self.json) = (host, musical, json)
    }
}

private let initialMusical =
    #"{"frame":0,"generation":1,"hostTicks":2400000000,"kind":"anchor","musicalTicks":0,"sampleClock":"smp.main","#
    + #""seq":1,"transport":1}"#

private let goldenAnchors: [GoldenAnchor] = [
    .init("01 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("01 seq 8", 8, 2, 0, 2_490_000_000, musical: Mus(2, 92_160, 0),
          #"{"frame":0,"generation":2,"hostTicks":2490000000,"kind":"anchor","musicalTicks":92160,"#
            + #""sampleClock":"smp.main","seq":8,"transport":2}"#),
    .init("02 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    // The example writes "loopIteration": 0; the builder omits it.
    .init("03 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("03 seq 4", 4, 1, 192_000, 2_496_000_000, musical: Mus(1, 0, 1),
          #"{"frame":192000,"generation":1,"hostTicks":2496000000,"kind":"anchor","loopIteration":1,"#
            + #""musicalTicks":0,"sampleClock":"smp.main","seq":4,"transport":1}"#),
    // The example writes "loopIteration": 0; the builder omits it.
    .init("03 seq 17", 17, 1, 210_000, 2_505_000_000, musical: Mus(2, 61_440, 0),
          #"{"frame":210000,"generation":1,"hostTicks":2505000000,"kind":"anchor","musicalTicks":61440,"#
            + #""sampleClock":"smp.main","seq":17,"transport":2}"#),
    .init("04 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("04 seq 6", 6, 1, 192_000, 2_496_000_000, musical: Mus(1, 122_880, 0),
          #"{"frame":192000,"generation":1,"hostTicks":2496000000,"kind":"anchor","musicalTicks":122880,"#
            + #""sampleClock":"smp.main","seq":6,"transport":1}"#),
    .init("05 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("06 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("07 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("08 seq 1", 1, 1, 48_000, 2_424_000_000,
          #"{"frame":48000,"generation":1,"hostTicks":2424000000,"kind":"anchor","sampleClock":"smp.main","#
            + #""seq":1}"#),
    .init("08 seq 5", 5, 2, 96_000, 2_924_000_000,
          #"{"frame":96000,"generation":2,"hostTicks":2924000000,"kind":"anchor","sampleClock":"smp.main","#
            + #""seq":5}"#),
    .init("09 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("09 seq 10", 10, 2, 0, 2_490_000_000, musical: Mus(2, 16_000, 0),
          #"{"frame":0,"generation":2,"hostTicks":2490000000,"kind":"anchor","musicalTicks":16000,"#
            + #""sampleClock":"smp.main","seq":10,"transport":2}"#),
    .init("10 seq 1", 1, 1, 0, 2_400_000_000, musical: Mus(1, 0, 0), initialMusical),
    .init("11 seq 1", 1, 1, 48_000, 2_424_000_000,
          #"{"frame":48000,"generation":1,"hostTicks":2424000000,"kind":"anchor","sampleClock":"smp.main","#
            + #""seq":1}"#)
]

private let schemaKeys: Set<String> = [
    "seq", "kind", "sampleClock", "generation", "frame", "hostTicks", "transport", "musicalTicks",
    "loopIteration", "note"
]

private func keys(of anchor: ClockAnchor, note: String? = nil) throws -> Set<String> {
    let data = try AnchorV1Record.make(anchor, seq: 1, note: note).encodedJSON()
    let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try Set(#require(decoded).keys)
}

extension ControlContractTests {
    struct AnchorV1 {
        @Test func anchorV1RecordEncodesTheGoldenAnchorRecordsExactly() throws {
            #expect(goldenAnchors.count == 17) // every anchor of the 11 examples
            for golden in goldenAnchors {
                let anchor = try makeAnchor(generation: golden.generation, frame: golden.frame, host: golden.host,
                                            musical: golden.musical)
                let record = try AnchorV1Record.make(anchor, seq: golden.seq)
                let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
                #expect(json == golden.json, "\(golden.label)")
                #expect(record.seq == golden.seq && record.sampleClock == mainClock, "\(golden.label)")
                #expect(record.generation.value == golden.generation && record.frame == golden.frame,
                        "\(golden.label)")
                #expect(record.hostTicks == golden.host && record.note == nil, "\(golden.label)")
                #expect(record.transport?.value == golden.musical?.transport, "\(golden.label)")
                #expect(record.musicalTicks == golden.musical?.ticks, "\(golden.label)")
            }
        }

        @Test func anchorV1RecordWritesNumericBoundariesExactly() throws {
            let top = Generation.maximumValue
            let wide = try makeAnchor(generation: top, frame: Int64.min, host: UInt64.max,
                                      musical: Mus(top, Int64.max, UInt32.max))
            #expect(try anchorJSON(wide, seq: Int.max)
                        == #"{"frame":-9223372036854775808,"generation":9007199254740991,"#
                        + #""hostTicks":18446744073709551615,"kind":"anchor","loopIteration":4294967295,"#
                        + #""musicalTicks":9223372036854775807,"sampleClock":"smp.main","#
                        + #""seq":9223372036854775807,"transport":9007199254740991}"#)
            let low = try makeAnchor(generation: 1, frame: Int64.max, host: UInt64(Int64.max),
                                     musical: Mus(1, 0, 1))
            #expect(try anchorJSON(low)
                        == #"{"frame":9223372036854775807,"generation":1,"hostTicks":9223372036854775807,"#
                        + #""kind":"anchor","loopIteration":1,"musicalTicks":0,"sampleClock":"smp.main","#
                        + #""seq":1,"transport":1}"#)
            #expect(try anchorJSON(makeAnchor(host: 0)).contains(#""hostTicks":0,"#))
            let above = try anchorJSON(makeAnchor(host: UInt64(Int64.max) + 1))
            #expect(above.contains(#""hostTicks":9223372036854775808,"#))
        }

        @Test func anchorV1RecordRefusesInOrderWithoutClampingOrRemapping() throws {
            let upper = ClockID(validated: "Smp.main")
            let bad = try makeAnchor(clock: upper, musical: Mus(1, -1, 0))
            #expect(anchorRefusal(bad, seq: 0, note: "") == .invalidSeq(0))
            #expect(anchorRefusal(bad, note: "") == .invalidSampleClock(upper))
            let negative = try makeAnchor(musical: Mus(1, -1, 0))
            #expect(anchorRefusal(negative, note: "") == .negativeMusicalTicks(-1))
            let plain = try makeAnchor()
            #expect(anchorRefusal(plain, note: "") == .invalidNote(bytes: 0))
            #expect(anchorRefusal(plain) == nil)
            #expect(anchorRefusal(plain, seq: -1) == .invalidSeq(-1))
            #expect(anchorRefusal(plain, seq: Int.min) == .invalidSeq(Int.min))
            #expect(anchorRefusal(plain, seq: 1) == nil)
            #expect(anchorRefusal(plain, seq: Int.max) == nil)
        }

        @Test func anchorV1SampleClockFollowsTheMediaContractIDPattern() throws {
            let refused: [StaticString] = ["Smp.main", "smp.Main", "smp_main", "smp:main", "smp", "smp.", "1smp.a",
                                           "smp_x.main", "smp.ma_in"]
            for raw in refused {
                let clock = ClockID(validated: raw)
                #expect(anchorRefusal(try makeAnchor(clock: clock)) == .invalidSampleClock(clock), "\(raw)")
            }
            for raw: StaticString in ["smp.main", "a.b", "smp-1.main.2", "smp.0"] {
                let clock = ClockID(validated: raw)
                #expect(anchorRefusal(try makeAnchor(clock: clock)) == nil, "\(raw)")
                #expect(try anchorJSON(makeAnchor(clock: clock)).contains(#""sampleClock":"\#(raw)""#), "\(raw)")
            }
        }

        @Test func anchorV1MusicalTicksMustNotBeNegative() throws {
            for ticks in [Int64(-1), Int64.min] {
                let anchor = try makeAnchor(musical: Mus(1, ticks, 0))
                #expect(anchorRefusal(anchor) == .negativeMusicalTicks(ticks), "\(ticks)")
            }
            for ticks in [Int64(0), 1, Int64.max] {
                #expect(anchorRefusal(try makeAnchor(musical: Mus(1, ticks, 0))) == nil, "\(ticks)")
            }
        }

        @Test func anchorV1NoteFollowsTheTakeNoteRules() throws {
            let limit = AnchorV1Record.maximumNoteBytes
            #expect(limit == RecordingTakeV1Record.maximumNoteBytes && limit == 256)
            let ascii = String(repeating: "a", count: limit)
            let accented = String(repeating: "é", count: limit / 2)
            let cases: [(String, Int?)] = [
                ("", 0), (" \n\t", 3), ("\u{00A0}", 2), (ascii + "a", limit + 1),
                (String(repeating: "é", count: limit / 2 + 1), limit + 2),
                (ascii, nil), (accented, nil), (" x ", nil), ("a/b", nil)
            ]
            let anchor = try makeAnchor()
            for (text, bytes) in cases {
                let refusal = anchorRefusal(anchor, note: text)
                if let bytes {
                    #expect(refusal == .invalidNote(bytes: bytes), "\(bytes)")
                } else {
                    #expect(refusal == nil, "\(text.utf8.count)")
                }
            }
            // Accepted text is written verbatim: not trimmed, truncated or remapped; `/` stays unescaped.
            let record = try AnchorV1Record.make(anchor, seq: 3, note: " a/b é ")
            #expect(record.note == " a/b é ")
            #expect(try anchorJSON(anchor, seq: 3, note: " a/b é ").contains(#""note":" a/b é ","sampleClock""#))
            #expect(try keys(of: anchor, note: accented) == ["seq", "kind", "sampleClock", "generation", "frame",
                                                             "hostTicks", "note"])
        }

        @Test func anchorV1TransportAndMusicalTicksAppearTogetherOrNotAtAll() throws {
            let musical = try makeAnchor(musical: Mus(2, 5, 0))
            let record = try AnchorV1Record.make(musical, seq: 2)
            #expect(record.transport?.value == 2 && record.musicalTicks == 5 && record.loopIteration == nil)
            #expect(try keys(of: musical) == schemaKeys.subtracting(["loopIteration", "note"]))
            let looped = try makeAnchor(musical: Mus(2, 5, 3))
            #expect(try AnchorV1Record.make(looped, seq: 2).loopIteration == 3)
            #expect(try keys(of: looped, note: "n") == schemaKeys)
            let plain = try makeAnchor()
            let bare = try AnchorV1Record.make(plain, seq: 2)
            #expect(bare.transport == nil && bare.musicalTicks == nil && bare.loopIteration == nil)
            #expect(try keys(of: plain) == ["seq", "kind", "sampleClock", "generation", "frame", "hostTicks"])
        }

        @Test func anchorV1LoopIterationZeroIsNeverWritten() throws {
            for loop: UInt32 in [0, 1, 2, UInt32.max] {
                let json = try anchorJSON(makeAnchor(musical: Mus(1, 0, loop)))
                #expect(json.contains("loopIteration") == (loop != 0), "\(loop)")
            }
        }

        @Test func anchorV1MusicalMapIsNotWritten() throws {
            let first = try makeAnchor(musical: Mus(1, 7, 1), map: 1)
            let second = try makeAnchor(musical: Mus(1, 7, 1), map: Generation.maximumValue)
            #expect(first != second)
            let one = try AnchorV1Record.make(first, seq: 4)
            let two = try AnchorV1Record.make(second, seq: 4)
            #expect(one == two)
            #expect(try one.encodedJSON() == two.encodedJSON())
            #expect(try !anchorJSON(second, seq: 4).contains("musicalMap"))
        }

        @Test func anchorV1RecordIsDeterministic() throws {
            let anchor = try makeAnchor(generation: 3, frame: -5, host: UInt64.max, musical: Mus(2, 9, 1))
            let record = try AnchorV1Record.make(anchor, seq: 6, note: "same")
            let again = try AnchorV1Record.make(anchor, seq: 6, note: "same")
            #expect(record == again)
            #expect(try record.encodedJSON() == record.encodedJSON())
            #expect(try record.encodedJSON() == again.encodedJSON())
            #expect(try AnchorV1Record.make(anchor, seq: 7, note: "same") != record)
        }
    }
}
