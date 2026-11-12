//
//  ControlContractTests+TriggerV1.swift
//  FluxKlangTests
//
//  The media contract v1 `triggerRecord` builder (#107 TXR1): the 25 example records byte for byte plus four
//  hand-derived rows, the omission rule for `target`, the field boundaries, the shape, the division of labour
//  with `TriggerStamp.validate`, and determinism. The refusals are in `+TriggerV1Refusals`.
//

import Foundation
import Testing
@testable import FluxKlang

/// A golden `triggerRecord`, `<example> seq <n>`, keys sorted, compact. `target` is the stamp's target and
/// defaults to `quantize`, the action's declared value, in which case the record omits it.
private struct TriggerV1Golden {
    let label: String
    let seq: Int
    let trigger: String
    let action: String
    let ticks: UInt64
    let horizon: Int64
    let requires: String
    let quantize: TriggerTarget?
    let target: TriggerTarget?
    let note: String?
    let json: String

    init(_ label: String, seq: Int, trigger: String, action: String, ticks: UInt64, horizon: Int64,
         requires: String, quantize: TriggerTarget?, target: TriggerTarget? = nil, note: String? = nil,
         json: String) {
        (self.label, self.seq, self.trigger, self.action) = (label, seq, trigger, action)
        (self.ticks, self.horizon, self.requires) = (ticks, horizon, requires)
        (self.quantize, self.target, self.note, self.json) = (quantize, target, note, json)
    }

    func stamp() throws -> TriggerStamp {
        let wanted = try #require(target ?? quantize)
        return ControlContractTests.TriggerV1Fixtures.stamp(
            trigger: trigger, action: action, ticks: ticks, horizon: horizon,
            requires: try ControlContractTests.TriggerV1Fixtures.requirements(requires), target: wanted)
    }
}

private typealias Fixtures = ControlContractTests.TriggerV1Fixtures

extension ControlContractTests {
    /// Shared by `TriggerV1` and `TriggerV1Refusals`.
    enum TriggerV1Fixtures {
        static let main = "smp=1 mus=1 ctx=1"
        private static let aliases = ["smp": "sampleClock/smp.main", "mus": "transport/mus.main",
                                      "ctx": "context/ctx.main"]

        /// `"smp=1 mus=2 source/src.a=3"`: `kind/subject=generation` tokens in stamp order, with three aliases.
        static func requirements(_ text: String) throws -> [GenerationRequirement] {
            try text.split(separator: " ").map { token in
                let parts = token.split(separator: "=")
                try #require(parts.count == 2, "bad fixture \(token)")
                let name = aliases[String(parts[0])] ?? String(parts[0])
                let names = name.split(separator: "/")
                try #require(names.count == 2, "bad fixture \(token)")
                guard let kind = GenerationKind(rawValue: String(names[0])),
                      let subject = GenerationSubject(rawValue: String(names[1])) else {
                    preconditionFailure("bad fixture \(token)")
                }
                return GenerationRequirement(key: GenerationKey(kind: kind, subject: subject),
                                             generation: try Generation(Int(parts[1]) ?? 0))
            }
        }

        static func stamp(trigger: String = "trg.1", action: String = "act.fx", ticks: UInt64 = 1,
                          horizon: Int64 = 1, requires: [GenerationRequirement], target: TriggerTarget = .asap,
                          latePolicy: LatePolicy = .drop) -> TriggerStamp {
            guard let id = TriggerID(rawValue: trigger), let action = ActionID(rawValue: action) else {
                preconditionFailure("bad fixture IDs")
            }
            return TriggerStamp(id: id, action: action, originHost: HostStamp(ticks: ticks), horizonFrame: horizon,
                                requires: requires, target: target, latePolicy: latePolicy)
        }

        static func stamp(requires text: String = main, target: TriggerTarget = .asap) throws -> TriggerStamp {
            stamp(requires: try requirements(text), target: target)
        }

        static func json(_ record: TriggerV1Record) throws -> String {
            try #require(String(data: record.encodedJSON(), encoding: .utf8))
        }

        /// 25 example records (expected JSON from `json.dumps(record, sort_keys=True, separators=(",", ":"),
        /// ensure_ascii=False)` on the example files, never from the Swift encoder) and four hand-derived rows
        /// (each validated with the checker's `validate` against `$defs.triggerRecord`).
        fileprivate static let goldens: [TriggerV1Golden] = examples + extras

        private static let examples: [TriggerV1Golden] = [
            .init("01 seq 2", seq: 2, trigger: "trg.1", action: "act.loop-b",
                  ticks: 2_460_000_000, horizon: 120256, requires: main,
                  quantize: .grid(ticks: 61440),
                  note: "Resolves to bar 3 (frame 192000); pending.",
                  json: #"{"actionId":"act.loop-b","horizonFrame":120256,"kind":"trigger","#
                      + #""note":"Resolves to bar 3 (frame 192000); pending.","originHostTicks":2460000000,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":2,"triggerId":"trg.1"}"#),
            .init("01 seq 10", seq: 10, trigger: "trg.2", action: "act.loop-b",
                  ticks: 2_470_000_000, horizon: 12512, requires: main,
                  quantize: .grid(ticks: 61440),
                  note: "Pressed before the restart, delivered after it.",
                  json: #"{"actionId":"act.loop-b","horizonFrame":12512,"kind":"trigger","#
                      + #""note":"Pressed before the restart, delivered after it.","originHostTicks":2470000000,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":10,"triggerId":"trg.2"}"#),
            .init("01 seq 12", seq: 12, trigger: "trg.3", action: "act.loop-b",
                  ticks: 2_496_000_000, horizon: 24512, requires: "smp=2 mus=2 ctx=1",
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.loop-b","horizonFrame":24512,"kind":"trigger","#
                      + #""originHostTicks":2496000000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":2,"transport/mus.main":2},"seq":12,"triggerId":"trg.3"}"#),
            .init("02 seq 2", seq: 2, trigger: "trg.1", action: "act.loop-a",
                  ticks: 2_448_240_000, horizon: 96736, requires: main,
                  quantize: .grid(ticks: 61440),
                  note: "Pressed 10 ms after bar 2: inside the 40 ms retroactive window.",
                  json: #"{"actionId":"act.loop-a","horizonFrame":96736,"kind":"trigger","#
                      + #""note":"Pressed 10 ms after bar 2: inside the 40 ms retroactive window.","#
                      + #""originHostTicks":2448240000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":2,"triggerId":"trg.1"}"#),
            .init("02 seq 4", seq: 4, trigger: "trg.2", action: "act.loop-a",
                  ticks: 2_498_400_000, horizon: 197056, requires: main,
                  quantize: .grid(ticks: 61440),
                  note: "Pressed 100 ms after bar 3: outside the window, so the next bar.",
                  json: #"{"actionId":"act.loop-a","horizonFrame":197056,"kind":"trigger","#
                      + #""note":"Pressed 100 ms after bar 3: outside the window, so the next bar.","#
                      + #""originHostTicks":2498400000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":4,"triggerId":"trg.2"}"#),
            .init("02 seq 6", seq: 6, trigger: "trg.3", action: "act.stab",
                  ticks: 2_555_952_000, horizon: 312160, requires: main,
                  quantize: .grid(ticks: 15360),
                  note: "Beat boundary is 160 frames (3.3 ms) behind the horizon.",
                  json: #"{"actionId":"act.stab","horizonFrame":312160,"kind":"trigger","#
                      + #""note":"Beat boundary is 160 frames (3.3 ms) behind the horizon.","#
                      + #""originHostTicks":2555952000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":6,"triggerId":"trg.3"}"#),
            .init("02 seq 8", seq: 8, trigger: "trg.4", action: "act.fx",
                  ticks: 2_567_976_000, horizon: 336208, requires: main,
                  quantize: .grid(ticks: 15360),
                  json: #"{"actionId":"act.fx","horizonFrame":336208,"kind":"trigger","#
                      + #""originHostTicks":2567976000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":8,"triggerId":"trg.4"}"#),
            .init("02 seq 10", seq: 10, trigger: "trg.5", action: "act.scene",
                  ticks: 2_567_976_000, horizon: 336208, requires: main,
                  quantize: .grid(ticks: 15360), target: .grid(ticks: 30720),
                  json: #"{"actionId":"act.scene","horizonFrame":336208,"kind":"trigger","#
                      + #""originHostTicks":2567976000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":10,"target":{"gridTicks":30720,"#
                      + #""timeBase":"musical"},"triggerId":"trg.5"}"#),
            .init("03 seq 2", seq: 2, trigger: "trg.1", action: "act.verse",
                  ticks: 2_495_500_000, horizon: 192256, requires: main,
                  quantize: .grid(ticks: 61440),
                  note: "Resolves to the loop end of iteration 0 (the wrap frame 192000), already behind the horizon.",
                  json: #"{"actionId":"act.verse","horizonFrame":192256,"kind":"trigger","#
                      + #""note":"Resolves to the loop end of iteration 0 (the wrap frame 192000),"#
                      + #" already behind the horizon.","originHostTicks":2495500000,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":2,"triggerId":"trg.1"}"#),
            .init("03 seq 11", seq: 11, trigger: "trg.2", action: "act.verse",
                  ticks: 2_500_000_000, horizon: 200256, requires: main,
                  quantize: .grid(ticks: 61440),
                  note: "Resolves to bar 2 of iteration 1 (frame 288000); pending.",
                  json: #"{"actionId":"act.verse","horizonFrame":200256,"kind":"trigger","#
                      + #""note":"Resolves to bar 2 of iteration 1 (frame 288000); pending.","#
                      + #""originHostTicks":2500000000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":11,"triggerId":"trg.2"}"#),
            .init("03 seq 20", seq: 20, trigger: "trg.3", action: "act.backing",
                  ticks: 2_506_000_000, horizon: 212256, requires: "smp=1 mus=2 ctx=1",
                  quantize: .grid(ticks: 61440),
                  note: "Next bar is the loop end, so it resolves to the wrap frame.",
                  json: #"{"actionId":"act.backing","horizonFrame":212256,"kind":"trigger","#
                      + #""note":"Next bar is the loop end, so it resolves to the wrap frame.","#
                      + #""originHostTicks":2506000000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":2},"seq":20,"triggerId":"trg.3"}"#),
            .init("04 seq 2", seq: 2, trigger: "trg.1", action: "act.backing",
                  ticks: 2_400_500_000, horizon: 1256, requires: main,
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.backing","horizonFrame":1256,"kind":"trigger","#
                      + #""originHostTicks":2400500000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":2,"triggerId":"trg.1"}"#),
            .init("04 seq 4", seq: 4, trigger: "trg.2", action: "act.drums",
                  ticks: 2_450_000_000, horizon: 100256, requires: main,
                  quantize: .grid(ticks: 15360), target: .musical(atTicks: 184320),
                  note: "Bar 4 beat 1 was frame 288000 at the old tempo.",
                  json: #"{"actionId":"act.drums","horizonFrame":100256,"kind":"trigger","#
                      + #""note":"Bar 4 beat 1 was frame 288000 at the old tempo.","originHostTicks":2450000000,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":4,"target":{"atTicks":184320,"timeBase":"musical"},"triggerId":"trg.2"}"#),
            .init("04 seq 10", seq: 10, trigger: "trg.3", action: "act.stretch",
                  ticks: 2_500_000_000, horizon: 200256, requires: main,
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.stretch","horizonFrame":200256,"kind":"trigger","#
                      + #""originHostTicks":2500000000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":10,"triggerId":"trg.3"}"#),
            .init("05 seq 2", seq: 2, trigger: "trg.1", action: "act.backing",
                  ticks: 2_400_500_000, horizon: 1256, requires: "smp=1 mus=1 ctx=1 source/src.backing=1",
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.backing","horizonFrame":1256,"kind":"trigger","#
                      + #""originHostTicks":2400500000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"source/src.backing":1,"transport/mus.main":1},"seq":2,"#
                      + #""triggerId":"trg.1"}"#),
            .init("05 seq 5", seq: 5, trigger: "trg.2", action: "act.backing",
                  ticks: 2_485_000_000, horizon: 170256, requires: "smp=1 mus=1 ctx=1 source/src.backing=1",
                  quantize: .grid(ticks: 61440),
                  note: "Resolves to frame 192000; pending.",
                  json: #"{"actionId":"act.backing","horizonFrame":170256,"kind":"trigger","#
                      + #""note":"Resolves to frame 192000; pending.","originHostTicks":2485000000,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"source/src.backing":1,"#
                      + #""transport/mus.main":1},"seq":5,"triggerId":"trg.2"}"#),
            .init("05 seq 14", seq: 14, trigger: "trg.3", action: "act.backing",
                  ticks: 2_487_500_000, horizon: 235256, requires: "smp=1 mus=1 ctx=1 source/src.backing=1",
                  quantize: .grid(ticks: 61440),
                  note: "Queued before the loss and delivered after recovery.",
                  json: #"{"actionId":"act.backing","horizonFrame":235256,"kind":"trigger","#
                      + #""note":"Queued before the loss and delivered after recovery.","#
                      + #""originHostTicks":2487500000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"source/src.backing":1,"transport/mus.main":1},"seq":14,"#
                      + #""triggerId":"trg.3"}"#),
            .init("05 seq 16", seq: 16, trigger: "trg.4", action: "act.backing",
                  ticks: 2_520_000_000, horizon: 240256, requires: "smp=1 mus=1 ctx=1 source/src.backing=3",
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.backing","horizonFrame":240256,"kind":"trigger","#
                      + #""originHostTicks":2520000000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"source/src.backing":3,"transport/mus.main":1},"seq":16,"#
                      + #""triggerId":"trg.4"}"#),
            .init("06 seq 2", seq: 2, trigger: "trg.1", action: "act.clip",
                  ticks: 2_405_000_000, horizon: 10256, requires: "smp=1 mus=1 ctx=1 cancelScope/set.verse=1",
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.clip","horizonFrame":10256,"kind":"trigger","#
                      + #""originHostTicks":2405000000,"requires":{"cancelScope/set.verse":1,"#
                      + #""context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"seq":2,"#
                      + #""triggerId":"trg.1"}"#),
            .init("06 seq 3", seq: 3, trigger: "trg.2", action: "act.scene",
                  ticks: 2_406_000_000, horizon: 12256, requires: "smp=1 mus=1 ctx=1 cancelScope/set.verse=1",
                  quantize: .grid(ticks: 15360),
                  json: #"{"actionId":"act.scene","horizonFrame":12256,"kind":"trigger","#
                      + #""originHostTicks":2406000000,"requires":{"cancelScope/set.verse":1,"#
                      + #""context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"seq":3,"#
                      + #""triggerId":"trg.2"}"#),
            .init("06 seq 8", seq: 8, trigger: "trg.3", action: "act.clip",
                  ticks: 2_405_000_000, horizon: 20256, requires: "smp=1 mus=1 ctx=1 cancelScope/set.verse=1",
                  quantize: .grid(ticks: 61440),
                  note: "A retry of trg.1 with its original stamps.",
                  json: #"{"actionId":"act.clip","horizonFrame":20256,"kind":"trigger","#
                      + #""note":"A retry of trg.1 with its original stamps.","originHostTicks":2405000000,"#
                      + #""requires":{"cancelScope/set.verse":1,"context/ctx.main":1,"sampleClock/smp.main":1,"#
                      + #""transport/mus.main":1},"seq":8,"triggerId":"trg.3"}"#),
            .init("06 seq 10", seq: 10, trigger: "trg.4", action: "act.clip",
                  ticks: 2_410_000_000, horizon: 20256, requires: "smp=1 mus=1 ctx=2 cancelScope/set.verse=2",
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.clip","horizonFrame":20256,"kind":"trigger","#
                      + #""originHostTicks":2410000000,"requires":{"cancelScope/set.verse":2,"#
                      + #""context/ctx.main":2,"sampleClock/smp.main":1,"transport/mus.main":1},"seq":10,"#
                      + #""triggerId":"trg.4"}"#),
            .init("07 seq 2", seq: 2, trigger: "trg.1", action: "act.intro",
                  ticks: 2_400_500_000, horizon: 1256, requires: main,
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.intro","horizonFrame":1256,"kind":"trigger","#
                      + #""originHostTicks":2400500000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":2,"triggerId":"trg.1"}"#),
            .init("07 seq 6", seq: 6, trigger: "trg.2", action: "act.intro",
                  ticks: 2_415_000_000, horizon: 30256, requires: main,
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.intro","horizonFrame":30256,"kind":"trigger","#
                      + #""originHostTicks":2415000000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":6,"triggerId":"trg.2"}"#),
            .init("07 seq 9", seq: 9, trigger: "trg.3", action: "act.intro",
                  ticks: 2_465_000_000, horizon: 130256, requires: main,
                  quantize: .grid(ticks: 61440),
                  json: #"{"actionId":"act.intro","horizonFrame":130256,"kind":"trigger","#
                      + #""originHostTicks":2465000000,"requires":{"context/ctx.main":1,"#
                      + #""sampleClock/smp.main":1,"transport/mus.main":1},"seq":9,"triggerId":"trg.3"}"#)
        ]

        /// Not examples: the four target shapes written without a `quantize`.
        private static let extras: [TriggerV1Golden] = [
            .init("extra sample", seq: 3, trigger: "trg.9", action: "act.fx", ticks: 5, horizon: 1000,
                  requires: main, quantize: nil, target: .sample(atFrame: 96000),
                  json: #"{"actionId":"act.fx","horizonFrame":1000,"kind":"trigger","originHostTicks":5,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":3,"target":{"atFrame":96000,"timeBase":"sample"},"triggerId":"trg.9"}"#),
            .init("extra asap", seq: 3, trigger: "trg.9", action: "act.fx", ticks: 5, horizon: 1000,
                  requires: main, quantize: nil, target: .asap,
                  json: #"{"actionId":"act.fx","horizonFrame":1000,"kind":"trigger","originHostTicks":5,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":3,"target":{"timeBase":"asap"},"triggerId":"trg.9"}"#),
            .init("extra grid", seq: 3, trigger: "trg.9", action: "act.fx", ticks: 5, horizon: 1000,
                  requires: main, quantize: nil, target: .grid(ticks: 61440),
                  json: #"{"actionId":"act.fx","horizonFrame":1000,"kind":"trigger","originHostTicks":5,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":3,"target":{"gridTicks":61440,"timeBase":"musical"},"triggerId":"trg.9"}"#),
            .init("extra atTicks", seq: 3, trigger: "trg.9", action: "act.fx", ticks: 5, horizon: 1000,
                  requires: main, quantize: nil, target: .musical(atTicks: 0),
                  json: #"{"actionId":"act.fx","horizonFrame":1000,"kind":"trigger","originHostTicks":5,"#
                      + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"#
                      + #""seq":3,"target":{"atTicks":0,"timeBase":"musical"},"triggerId":"trg.9"}"#)
        ]
    }

    struct TriggerV1 {
        @Test func triggerV1RecordEncodesTheGoldenTriggerRecordsExactly() throws {
            #expect(Fixtures.goldens.count == 29) // 25 example records + 4 extra rows
            var omitted = 0
            for golden in Fixtures.goldens {
                let stamp = try golden.stamp()
                let record = try TriggerV1Record.make(stamp, seq: golden.seq, quantize: golden.quantize,
                                                      note: golden.note)
                #expect(try Fixtures.json(record) == golden.json, "\(golden.label)")
                #expect(record.seq == golden.seq && record.note == golden.note, "\(golden.label)")
                #expect(record.triggerID == stamp.id && record.actionID == stamp.action, "\(golden.label)")
                #expect(record.originHostTicks == golden.ticks && record.horizonFrame == golden.horizon,
                        "\(golden.label)")
                #expect(record.requires.count == stamp.requires.count, "\(golden.label)")
                // `target` is omitted exactly when the example's own record omits it.
                #expect((record.target == nil) == !golden.json.contains(#""target":"#), "\(golden.label)")
                omitted += record.target == nil ? 1 : 0
                let again = try TriggerV1Record.make(stamp, seq: golden.seq, quantize: golden.quantize,
                                                     note: golden.note)
                #expect(again == record, "\(golden.label)")
                #expect(try again.encodedJSON() == record.encodedJSON(), "\(golden.label)")
            }
            #expect(omitted == 23) // 25 example records, all but 02 seq 10 and 04 seq 4
        }

        @Test func triggerV1TargetIsOmittedOnlyWhenQuantizeEqualsIt() throws {
            let targets: [TriggerTarget] = [.grid(ticks: 1), .grid(ticks: 2), .musical(atTicks: 1),
                                            .musical(atTicks: 2), .sample(atFrame: 1), .sample(atFrame: 2), .asap]
            for target in targets {
                let stamp = try Fixtures.stamp(target: target)
                for quantize in targets.map({ Optional($0) }) + [nil] {
                    let record = try TriggerV1Record.make(stamp, seq: 1, quantize: quantize)
                    let label = "\(target) vs \(String(describing: quantize))"
                    #expect((record.target == nil) == (quantize == target), "\(label)")
                    #expect(record.target == (quantize == target ? nil : target))
                    let object = try #require(JSONSerialization.jsonObject(
                        with: record.encodedJSON()) as? [String: Any])
                    #expect(object.keys.contains("target") == (quantize != target))
                }
            }
        }

        @Test func triggerV1TargetWritesOnlyItsOwnFields() throws {
            let shapes: [(TriggerTarget, [String: String])] = [
                (.grid(ticks: 7), ["timeBase": "musical", "gridTicks": "7"]),
                (.musical(atTicks: 7), ["timeBase": "musical", "atTicks": "7"]),
                (.sample(atFrame: -7), ["timeBase": "sample", "atFrame": "-7"]),
                (.asap, ["timeBase": "asap"])
            ]
            for (target, expected) in shapes {
                let record = try TriggerV1Record.make(Fixtures.stamp(target: target), seq: 1)
                let object = try #require(JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any])
                let written = try #require(object["target"] as? [String: Any])
                #expect(written.mapValues { "\($0)" } == expected, "\(target)")
            }
        }

        @Test func triggerV1RecordWritesExactlyTheSchemaFields() throws {
            let stamp = try Fixtures.stamp(requires: "smp=1 mus=1 ctx=1 source/src.a=4", target: .asap)
            let bare = try TriggerV1Record.make(stamp, seq: 5, quantize: .asap)
            let full = try TriggerV1Record.make(stamp, seq: 5, quantize: .grid(ticks: 1), note: "n")
            let required: Set = ["seq", "kind", "triggerId", "actionId", "originHostTicks", "horizonFrame", "requires"]
            for (record, keys) in [(bare, required), (full, required.union(["target", "note"]))] {
                let object = try #require(JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any])
                #expect(Set(object.keys) == keys)
                #expect(object["kind"] as? String == "trigger" && TriggerV1Record.kind == "trigger")
                let requires = try #require(object["requires"] as? [String: Int])
                #expect(requires == ["sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1,
                                     "source/src.a": 4])
            }
        }

        @Test func triggerV1RequirementOrderDoesNotChangeTheBytes() throws {
            let forward = try Fixtures.requirements("smp=1 mus=2 ctx=3 source/src.a=4")
            try #require(forward.count == 4)
            let bytes = try TriggerV1Record.make(Fixtures.stamp(requires: forward), seq: 1).encodedJSON()
            for ordered in [Array(forward.reversed()), [forward[2], forward[0], forward[3], forward[1]]] {
                let record = try TriggerV1Record.make(Fixtures.stamp(requires: ordered), seq: 1)
                #expect(try record.encodedJSON() == bytes)
            }
        }

        @Test func triggerV1StampFieldsTheRecordHasNoRoomForNeverChangeTheBytes() throws {
            var stamp = try Fixtures.stamp(target: .grid(ticks: 4))
            let plain = try TriggerV1Record.make(stamp, seq: 2)
            stamp = TriggerStamp(id: stamp.id, action: stamp.action, originHost: stamp.originHost,
                                 horizonFrame: stamp.horizonFrame, requires: stamp.requires, target: stamp.target,
                                 latePolicy: .nextBoundary(gridTicks: 9), retroactiveMs: 77,
                                 stoppedPolicy: .startTransport, loopIteration: 12)
            let other = try TriggerV1Record.make(stamp, seq: 2)
            #expect(other == plain)
            #expect(try other.encodedJSON() == plain.encodedJSON())
        }

        @Test func triggerV1BuilderLeavesClockRulesToValidateAndTheChecker() throws {
            // Only a `source` counter: no sample clock, no context. `validate` refuses it; the builder does not,
            // because the clocks and the primary clock are trace state (the checker and the assembler own them).
            let sourceOnly = try Fixtures.stamp(requires: "source/src.a=1", target: .asap)
            #expect(throws: TriggerValidationError.self) {
                try sourceOnly.validate(primaryClock: GenerationKey(.sampleClock, ClockID(validated: "smp.main")),
                                        musicalClock: ClockID(validated: "mus.main"))
            }
            let written = try Fixtures.json(TriggerV1Record.make(sourceOnly, seq: 1))
            #expect(written.contains(#""requires":{"source/src.a":1}"#))
            // A musical target with no transport requirement, and an undeclared clock subject.
            let noTransport = try Fixtures.stamp(requires: "smp=1 ctx=1", target: .musical(atTicks: 0))
            #expect(throws: TriggerValidationError.missingTransport) {
                try noTransport.validate(primaryClock: GenerationKey(.sampleClock, ClockID(validated: "smp.main")),
                                         musicalClock: ClockID(validated: "mus.main"))
            }
            _ = try TriggerV1Record.make(noTransport, seq: 1)
            _ = try TriggerV1Record.make(Fixtures.stamp(requires: "sampleClock/other.clock=1", target: .asap), seq: 1)
        }
    }
}
