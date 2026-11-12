//
//  ControlContractTests+TimelineV1Fixtures.swift
//  FluxKlangTests
//
//  The records the media contract v1 `timeline` array tests (#84 TRC1) put in a list, each built with its real
//  builder from values of the media contract examples. Shared by `TimelineV1` and `TimelineV1Refusals`.
//

import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests {
    enum TimelineV1Fixtures {
        static let clock = ClockID(validated: "smp.main")
        static let musicalClock = ClockID(validated: "mus.main")

        /// Example 01 seq 1.
        static func anchor(_ seq: Int) throws -> TimelineV1Entry {
            let musical = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 0)
            let anchor = ClockAnchor(sample: SampleStamp(clock: clock, generation: .initial, frame: 0),
                                     host: HostStamp(ticks: 2_400_000_000), musical: musical)
            return .anchor(try AnchorV1Record.make(anchor, seq: seq))
        }

        /// Example 01 seq 4.
        static func generation(_ seq: Int) throws -> TimelineV1Entry {
            .generation(try GenerationV1Record.make(counter: GenerationKey(.sampleClock, clock), from: .initial,
                                                    to: Generation(2), reason: .rateChange(nominalRate: 96_000),
                                                    seq: seq))
        }

        /// Example 04 seq 2, with the trigger ID `id`.
        static func trigger(_ seq: Int, id: StaticString = "trg.1",
                            action: StaticString = "act.backing") throws -> TimelineV1Entry {
            let requires = [GenerationRequirement(key: GenerationKey(.context, ClockID(validated: "ctx.main")),
                                                  generation: .initial),
                            GenerationRequirement(key: GenerationKey(.sampleClock, clock), generation: .initial),
                            GenerationRequirement(key: GenerationKey(.transport, musicalClock),
                                                  generation: .initial)]
            let stamp = TriggerStamp(id: TriggerID(validated: id), action: ActionID(validated: action),
                                     originHost: HostStamp(ticks: 2_400_500_000), horizonFrame: 1_256,
                                     requires: requires, target: .grid(ticks: 61_440), latePolicy: .drop)
            return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: 61_440)))
        }

        /// Example 04 seq 3, for the trigger `id`.
        static func outcome(_ seq: Int, trigger id: StaticString = "trg.1") throws -> TimelineV1Entry {
            let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: .fired, assignedFrame: 96_000,
                                         frame: 96_000, musicalMap: .initial)
            return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
        }

        /// Example 04 seq 8.
        static func readiness(_ seq: Int, action: StaticString = "act.stretch") throws -> TimelineV1Entry {
            .readiness(try ReadinessV1Record.make(ActionID(validated: action), from: .unprepared, to: .preparing,
                                                  seq: seq))
        }

        /// Example 01 seq 7.
        static func discontinuity(_ seq: Int) throws -> TimelineV1Entry {
            .discontinuity(try DiscontinuityV1Record.make(
                .clockRestart(hostTicks: 2_490_000_000, previousFrame: 144_000), sampleClock: clock,
                generation: Generation(2), frame: 0, seq: seq))
        }

        /// Example 01 seq 3.
        static func dispatch(_ seq: Int) throws -> TimelineV1Entry {
            .dispatch(try DispatchV1Record.make(seq: seq, frame: 120_000, lane: .content,
                                                stream: StreamID(validated: "str.bed"), streamSeq: 41,
                                                event: "bed loop block"))
        }

        /// Example 09 seq 2.
        static func midiCapture(_ seq: Int) throws -> TimelineV1Entry {
            let capture = try #require(MIDICaptureFixture.example09Captures().records.first)
            return .midiCapture(try MIDICaptureV1Record.make(capture, seq: seq))
        }

        /// Example 08 seq 8 (`tk.1`), or a short user-stopped take for any other ID.
        static func take(_ seq: Int, id: TakeID = TakeLedgerTestFixture.take1) throws -> TimelineV1Entry {
            let take: RecordingTake
            var note: String?
            if id == TakeLedgerTestFixture.take1 {
                var ledger = try TakeLedgerTestFixture.example08Take1()
                take = try ledger.finish(id, reason: .diskFull)
                note = "Reported latency is not measured latency; no loopback measurement was made."
            } else {
                var ledger = try TakeLedgerTestFixture.ledger(opening: id)
                try ledger.advance(id, to: TakeLedgerTestFixture.stamp(1, 100))
                take = try ledger.finish(id, reason: .user)
            }
            let clearance = try RecordingTakeV1Gate.clear(take)
            return .take(try RecordingTakeV1Record.make(clearance, seq: seq, note: note))
        }

        /// Example 10 seq 11, with the export ID `id`.
        static func export(_ seq: Int, id: ExportID = MIDICaptureFixture.umpExport) throws -> TimelineV1Entry {
            let export = try NativeUMPExport.make(from: MIDICaptureFixture.example10(), id: id,
                                                  streams: [MIDICaptureFixture.synth],
                                                  origin: MIDICaptureFixture.origin(1, frame: 24_000))
            return .export(try NativeUMPExportV1Record.make(export, seq: seq))
        }

        /// One record of each kind at seq `first` through `first + 9`, in the order of the schema's `oneOf`.
        static func tenKinds(from first: Int = 1) throws -> [TimelineV1Entry] {
            [try anchor(first), try generation(first + 1), try trigger(first + 2), try outcome(first + 3),
             try readiness(first + 4), try discontinuity(first + 5), try dispatch(first + 6),
             try midiCapture(first + 7), try take(first + 8), try export(first + 9)]
        }

        /// The wrapped record's own `encodedJSON()`: the contract between the array and the ten builders.
        static func payloadJSON(_ entry: TimelineV1Entry) throws -> Data {
            switch entry {
            case .anchor(let record): try record.encodedJSON()
            case .generation(let record): try record.encodedJSON()
            case .trigger(let record): try record.encodedJSON()
            case .outcome(let record): try record.encodedJSON()
            case .readiness(let record): try record.encodedJSON()
            case .discontinuity(let record): try record.encodedJSON()
            case .dispatch(let record): try record.encodedJSON()
            case .midiCapture(let record): try record.encodedJSON()
            case .take(let record): try record.encodedJSON()
            case .export(let record): try record.encodedJSON()
            }
        }

        /// `[` + each entry's own JSON joined with `,` + `]`.
        static func joined(_ entries: [TimelineV1Entry]) throws -> Data {
            var data = Data("[".utf8)
            for (index, entry) in entries.enumerated() {
                if index > 0 { data.append(Data(",".utf8)) }
                data.append(try payloadJSON(entry))
            }
            data.append(Data("]".utf8))
            return data
        }

        /// `count` dispatch records at seq 1 through `count`: the cheapest kind for long lists.
        static func dispatches(_ count: Int) throws -> [TimelineV1Entry] {
            try (1...count).map { try dispatch($0) }
        }

        static func json(_ record: TimelineV1Record) throws -> String {
            try #require(String(data: record.encodedJSON(), encoding: .utf8))
        }

        /// The refusal `TimelineV1Record.make` gives for `entries`, or nil when it accepts them.
        static func refusal(_ entries: [TimelineV1Entry]) -> TimelineV1RecordRefusal? {
            do {
                _ = try TimelineV1Record.make(entries)
                return nil
            } catch {
                return error
            }
        }
    }
}
