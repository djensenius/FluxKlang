//
//  ControlContractTests+DiscontinuityV1Runtime.swift
//  FluxKlangTests
//
//  The bridge from a `RuntimeDiscontinuity` to the media contract v1 `discontinuityRecord` (#109, #110):
//  every kind end to end against the direct builder, the golden example records byte for byte, every refusal
//  with its payload and the check order, the ignored host and the unrelated bindings.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = DiscontinuityV1RuntimeRefusal
private typealias Event = DiscontinuityV1Record.Event

private let smp = ClockID(validated: "smp.main")
private let backing = StreamID(validated: "str.backing")
private let takeIn = StreamID(validated: "str.take-in")
private let otherPlayback = StreamID(validated: "str.other")
private let host = HostStamp(ticks: 2_490_000_000)

/// smp.main 0, str.backing (playback) 1, str.take-in (capture) 2; `extra` adds unrelated slots after them.
private func preparation(extra: Bool = false) throws -> RuntimePreparation {
    var bindings: [(RuntimeIdentity, UInt32)] = [
        (.sampleClock(smp), 0), (.stream(backing, direction: .playback), 1), (.stream(takeIn, direction: .capture), 2)
    ]
    if extra {
        bindings += [(.musicalClock(ClockID(validated: "mus.main")), 3),
                     (.stream(otherPlayback, direction: .playback), 4),
                     (.stream(StreamID(validated: "str.cap2"), direction: .capture), 5)]
    }
    return try RuntimePreparation(primaryClock: smp, musicalClock: extra ? ClockID(validated: "mus.main") : nil,
                                  bindings: bindings)
}

private func stamp(generation: Int = 1, frame: Int64 = 1_000) throws -> SampleStamp {
    SampleStamp(clock: smp, generation: try Generation(generation), frame: frame)
}

/// A runtime value built by the production constructor.
private func runtime(_ kind: RuntimeDiscontinuityKind, frames: UInt32? = nil, stream: StreamID? = nil,
                     host: HostStamp? = nil, generation: Int = 1, frame: Int64 = 1_000,
                     extra: Bool = false) throws -> RuntimeDiscontinuity {
    try preparation(extra: extra).discontinuity(kind, sample: stamp(generation: generation, frame: frame),
                                                frames: frames, stream: stream, host: host)
}

/// A hand-built value, for slots the constructor would not produce.
private func raw(_ kind: RuntimeDiscontinuityKind, clock: UInt32 = 0, generation: UInt64 = 1, frames: UInt32? = nil,
                 stream: UInt32? = nil, host: HostStamp? = nil) -> RuntimeDiscontinuity {
    RuntimeDiscontinuity(kind: kind, sample: RuntimeSampleStamp(clock: clock, generation: generation, frame: 1_000),
                         frames: frames, stream: stream, host: host)
}

private func bridge(_ value: RuntimeDiscontinuity, stream: StreamID? = nil, seq: Int = 1, note: String? = nil,
                    extra: Bool = false) throws -> DiscontinuityV1Record {
    try DiscontinuityV1Record.make(value, preparation: preparation(extra: extra), sampleClock: smp, stream: stream,
                                   seq: seq, note: note)
}

private func refusal(_ value: RuntimeDiscontinuity, clock: ClockID = smp, stream: StreamID? = nil, seq: Int = 1,
                     note: String? = nil) throws -> Refusal? {
    do {
        _ = try DiscontinuityV1Record.make(value, preparation: preparation(), sampleClock: clock, stream: stream,
                                           seq: seq, note: note)
        return nil
    } catch let error as Refusal {
        return error
    }
}

private struct Case {
    let kind: RuntimeDiscontinuityKind
    var frames: UInt32?
    var stream: StreamID?
    var host: HostStamp?
    let event: Event
}

private struct Golden {
    let label: String
    let kind: RuntimeDiscontinuityKind
    let generation: Int
    let frame: Int64
    let seq: Int
    var frames: UInt32?
    var stream: StreamID?
    var host: HostStamp?
    var note: String?
    let json: String
}

/// Restated from the media contract examples, `<example> seq <n>`; not derived from the bridge.
private let goldens: [Golden] = [
    Golden(label: "01 seq 7", kind: .clockRestart(previousFrame: 144_000), generation: 2, frame: 0, seq: 7,
           host: HostStamp(ticks: 2_490_000_000),
           json: #"{"frame":0,"generation":2,"hostTicks":2490000000,"kind":"discontinuity","previousFrame":144000,"#
               + #""sampleClock":"smp.main","seq":7,"type":"clockRestart"}"#),
    Golden(label: "05 seq 4", kind: .underrun, generation: 1, frame: 150_000, seq: 4, frames: 512, stream: backing,
           json: #"{"frame":150000,"frames":512,"generation":1,"kind":"discontinuity","sampleClock":"smp.main","#
               + #""seq":4,"stream":"str.backing","type":"underrun"}"#),
    Golden(label: "05 seq 7", kind: .sourceLost, generation: 1, frame: 180_000, seq: 7, stream: backing,
           note: "volume unmounted",
           json: #"{"frame":180000,"generation":1,"kind":"discontinuity","note":"volume unmounted","#
               + #""sampleClock":"smp.main","seq":7,"stream":"str.backing","type":"sourceLost"}"#),
    Golden(label: "12 seq 3", kind: .sampleJump, generation: 1, frame: 240_000, seq: 3,
           note: "The device's frame counter jumped forward: frame 240000 is the first frame after the jump.",
           json: #"{"frame":240000,"generation":1,"kind":"discontinuity","note":"The device's frame counter jumped "#
               + #"forward: frame 240000 is the first frame after the jump.","sampleClock":"smp.main","seq":3,"#
               + #""type":"sampleJump"}"#),
    Golden(label: "08 seq 2", kind: .overflow, generation: 1, frame: 480_000, seq: 2, frames: 1_024, stream: takeIn,
           json: #"{"frame":480000,"frames":1024,"generation":1,"kind":"discontinuity","sampleClock":"smp.main","#
               + #""seq":2,"stream":"str.take-in","type":"overflow"}"#),
    Golden(label: "08 seq 7", kind: .captureStopped(reason: .diskFull), generation: 2, frame: 480_000, seq: 7,
           stream: takeIn, note: "Writer finalised the partial file.",
           json: #"{"frame":480000,"generation":2,"kind":"discontinuity","note":"Writer finalised the partial file.","#
               + #""reason":"diskFull","sampleClock":"smp.main","seq":7,"stream":"str.take-in","#
               + #""type":"captureStopped"}"#),
    Golden(label: "08 seq 9", kind: .captureStopped(reason: .deviceLost), generation: 2, frame: 720_000, seq: 9,
           stream: takeIn,
           json: #"{"frame":720000,"generation":2,"kind":"discontinuity","reason":"deviceLost","#
               + #""sampleClock":"smp.main","seq":9,"stream":"str.take-in","type":"captureStopped"}"#)
]

extension ControlContractTests {
    struct DiscontinuityV1Runtime {
        @Test func everyKindBridgesToTheDirectRecordWithEqualBytes() throws {
            let cases = [
                Case(kind: .clockRestart(previousFrame: 500), host: host,
                     event: .clockRestart(hostTicks: host.ticks, previousFrame: 500)),
                Case(kind: .sampleJump, event: .sampleJump),
                Case(kind: .underrun, frames: 512, stream: backing, event: .underrun(backing, frames: 512)),
                Case(kind: .overflow, frames: 1_024, stream: takeIn, event: .overflow(takeIn, frames: 1_024)),
                Case(kind: .sourceLost, stream: backing, event: .sourceLost(backing)),
                Case(kind: .sourceRestored, stream: takeIn, event: .sourceRestored(takeIn)),
                Case(kind: .formatChange, stream: backing, event: .formatChange(backing)),
                Case(kind: .locate, event: .locate),
                Case(kind: .locate, stream: backing, host: host, event: .locate),
                Case(kind: .loopWrap, stream: takeIn, event: .loopWrap),
                Case(kind: .captureStopped(reason: .diskFull), stream: takeIn,
                     event: .captureStopped(takeIn, reason: .diskFull)),
                Case(kind: .captureStopped(reason: .deviceLost), stream: takeIn,
                     event: .captureStopped(takeIn, reason: .deviceLost))
            ]
            for item in cases {
                let (event, stream) = (item.event, item.stream)
                let value = try runtime(item.kind, frames: item.frames, stream: stream, host: item.host,
                                        generation: 3, frame: 77)
                let bridged = try bridge(value, stream: stream, seq: 5, note: "n")
                let direct = try DiscontinuityV1Record.make(event, sampleClock: smp, generation: Generation(3),
                                                            frame: 77, seq: 5, note: "n")
                #expect(bridged == direct, "\(event.type)")
                #expect(try bridged.encodedJSON() == direct.encodedJSON(), "\(event.type)")
            }
            #expect(cases.count == 12)
        }

        @Test func goldenExampleRecordsAreReproducedByteForByte() throws {
            #expect(goldens.count == 7)
            for golden in goldens {
                let value = try runtime(golden.kind, frames: golden.frames, stream: golden.stream, host: golden.host,
                                        generation: golden.generation, frame: golden.frame)
                let record = try bridge(value, stream: golden.stream, seq: golden.seq, note: golden.note)
                let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
                #expect(json == golden.json, "\(golden.label)")
            }
        }

        @Test func hostIsIgnoredOutsideClockRestartAndUnrelatedBindingsDoNotMatter() throws {
            let without = try bridge(runtime(.locate))
            let with = try bridge(runtime(.locate, host: host))
            #expect(with == without)
            #expect(try with.encodedJSON() == without.encodedJSON())
            for (kind, frames, stream) in [(RuntimeDiscontinuityKind.underrun, UInt32?(9), Optional(backing)),
                                           (.captureStopped(reason: .diskFull), nil, Optional(takeIn)),
                                           (.sampleJump, nil, nil)] {
                let plain = try bridge(runtime(kind, frames: frames, stream: stream), stream: stream)
                let padded = try bridge(runtime(kind, frames: frames, stream: stream, extra: true), stream: stream,
                                        extra: true)
                #expect(padded == plain)
                #expect(try padded.encodedJSON() == plain.encodedJSON())
            }
        }

        @Test func generationRangeIsExactlyOneThroughTwoToThe53Minus1() throws {
            let largest = UInt64(Generation.maximumValue)
            for bad in [0, largest + 1, UInt64.max] {
                #expect(try refusal(raw(.sampleJump, generation: bad)) == .generationOutOfRange(bad))
            }
            let edge = try bridge(raw(.sampleJump, generation: largest))
            #expect(edge.generation.value == Generation.maximumValue)
            #expect(try bridge(raw(.sampleJump, generation: 1)).generation == .initial)
        }

        @Test func clockRefusalsCarryBothValues() throws {
            let unmapped = ClockID(validated: "smp.other")
            #expect(try refusal(raw(.sampleJump), clock: unmapped) == .sampleClockNotMapped(unmapped))
            #expect(try refusal(raw(.sampleJump), clock: ClockID(validated: "mus.main")) ==
                .sampleClockNotMapped(ClockID(validated: "mus.main")))
            #expect(try refusal(raw(.sampleJump, clock: 1)) == .sampleClockSlotMismatch(runtime: 1, mapped: 0))
        }

        @Test func streamRefusalsCarryTheOffendingName() throws {
            #expect(try refusal(raw(.sourceLost, stream: 1)) == .streamNameMissing(slot: 1))
            #expect(try refusal(raw(.locate, stream: 1)) == .streamNameMissing(slot: 1))
            #expect(try refusal(raw(.sampleJump), stream: backing) == .streamSlotMissing(backing))
            #expect(try refusal(raw(.sourceLost), stream: backing) == .streamSlotMissing(backing))
            #expect(try refusal(raw(.sourceLost)) == .streamRequired(type: "sourceLost"))
            #expect(try refusal(raw(.underrun, frames: 1)) == .streamRequired(type: "underrun"))
            #expect(try refusal(raw(.captureStopped(reason: .deviceLost))) == .streamRequired(type: "captureStopped"))
            // Direction: a capture stream on an underrun; a playback stream on an overflow and a captureStopped.
            #expect(try refusal(raw(.underrun, frames: 1, stream: 2), stream: takeIn) == .streamNotDeclared(takeIn))
            #expect(try refusal(raw(.overflow, frames: 1, stream: 1), stream: backing) == .streamNotDeclared(backing))
            #expect(try refusal(raw(.captureStopped(reason: .diskFull), stream: 1), stream: backing) ==
                .streamNotDeclared(backing))
            #expect(try refusal(raw(.sourceLost, stream: 9), stream: StreamID(validated: "str.unknown")) ==
                .streamNotDeclared(StreamID(validated: "str.unknown")))
            // A declared name bound to another stream's slot.
            #expect(try refusal(raw(.sourceLost, stream: 2), stream: backing) ==
                .streamSlotMismatch(backing, runtime: 2, mapped: 1))
            #expect(try refusal(raw(.locate, stream: 2), stream: backing) ==
                .streamSlotMismatch(backing, runtime: 2, mapped: 1))
            #expect(try refusal(raw(.overflow, frames: 1, stream: 7), stream: takeIn) ==
                .streamSlotMismatch(takeIn, runtime: 7, mapped: 2))
        }

        @Test func framesAndHostRefusalsCarryTheirPayload() throws {
            #expect(try refusal(raw(.underrun, stream: 1), stream: backing) == .framesMissing(type: "underrun"))
            #expect(try refusal(raw(.overflow, stream: 2), stream: takeIn) == .framesMissing(type: "overflow"))
            #expect(try refusal(raw(.underrun, frames: 0, stream: 1), stream: backing) ==
                .record(.framesOutOfRange(0)))
            #expect(try refusal(raw(.overflow, frames: 0, stream: 2), stream: takeIn) == .record(.framesOutOfRange(0)))
            #expect(try refusal(raw(.sourceLost, frames: 4, stream: 1), stream: backing) ==
                .framesUnexpected(type: "sourceLost", frames: 4))
            #expect(try refusal(raw(.sampleJump, frames: 0)) == .framesUnexpected(type: "sampleJump", frames: 0))
            #expect(try refusal(raw(.clockRestart(previousFrame: 1))) == .hostMissing)
            let largest = try bridge(raw(.underrun, frames: .max, stream: 1), stream: backing)
            #expect(largest.event == .underrun(backing, frames: 4_294_967_295))
        }

        @Test func recordRefusalsAreWrappedWithTheirPayload() throws {
            #expect(try refusal(raw(.sampleJump), seq: 0) == .record(.invalidSeq(0)))
            #expect(try refusal(raw(.sampleJump), note: "") == .record(.invalidNote(bytes: 0)))
        }

        @Test func earlierChecksWinOverLaterOnes() throws {
            let unmapped = ClockID(validated: "smp.other")
            // 1 over 2, 2 over 3, 3 over 4, 4 over 5, 5 over 6.
            #expect(try refusal(raw(.sampleJump, generation: 0), clock: unmapped) == .sampleClockNotMapped(unmapped))
            #expect(try refusal(raw(.sampleJump, clock: 1, generation: 0)) ==
                .sampleClockSlotMismatch(runtime: 1, mapped: 0))
            #expect(try refusal(raw(.sourceLost, generation: 0, stream: 1)) == .generationOutOfRange(0))
            #expect(try refusal(raw(.underrun, stream: 1)) == .streamNameMissing(slot: 1))
            #expect(try refusal(raw(.sourceLost, frames: 3)) == .streamRequired(type: "sourceLost"))
            #expect(try refusal(raw(.clockRestart(previousFrame: 1), frames: 5)) ==
                .framesUnexpected(type: "clockRestart", frames: 5))
            #expect(try refusal(raw(.clockRestart(previousFrame: 1)), seq: 0) == .hostMissing)
            #expect(try refusal(raw(.underrun, frames: 0, stream: 1), stream: backing, seq: 0) ==
                .record(.invalidSeq(0)))
        }
    }
}
