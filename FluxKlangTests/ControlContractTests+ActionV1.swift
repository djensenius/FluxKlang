//
//  ControlContractTests+ActionV1.swift
//  FluxKlangTests
//
//  The media contract v1 `actions` entry builder (#107 ACT1): the 14 example actions byte for byte plus eleven
//  hand-derived rows, what is dropped and omitted on purpose, the shape, the target encoding shared with
//  `triggerRecord`, the division of labour with the checker, and determinism. The refusals are in
//  `+ActionV1Refusals`, the header in `+ActionsV1`.
//

import Foundation
import Testing
@testable import FluxKlang

/// A golden action, `ex <nn> <actionId>` or `hand <what>`, keys sorted, compact. `grid` is the policy's `gridTicks`.
struct ActionV1Golden {
    let label: String
    let id: String
    let media: ActionMedia
    let time: MediaTimePolicy?
    let late: LatePolicy
    let grid: Int64?
    let retro: Int
    let quantize: TriggerTarget
    let readiness: ReadinessState
    // swiftlint:disable:next large_tuple
    let prefetch: (frames: Int, count: Int, head: Int)?
    let json: String

    init(_ label: String, id: String, media: ActionMedia, time: MediaTimePolicy?, late: LatePolicy,
         grid: Int64? = nil, retro: Int = 0, quantize: TriggerTarget, readiness: ReadinessState,
         // swiftlint:disable:next large_tuple
         prefetch: (Int, Int, Int)? = nil, json: String) {
        (self.label, self.id, self.media, self.time, self.late) = (label, id, media, time, late)
        (self.grid, self.retro, self.quantize, self.readiness) = (grid, retro, quantize, readiness)
        self.prefetch = prefetch.map { (frames: $0.0, count: $0.1, head: $0.2) }
        self.json = json
    }

    func record() throws -> ActionV1Record {
        let policy = try ControlContractTests.ActionV1Fixtures.policy(
            media: media, time: time, late: late, grid: grid, retro: retro)
        let plan = try prefetch.map {
            try ControlContractTests.ActionV1Fixtures.plan($0.frames, $0.count, $0.head)
        }
        return try ActionV1Record.make(id: ControlContractTests.ActionV1Fixtures.id(id), policy: policy,
                                       quantize: quantize, readiness: readiness, prefetch: plan)
    }
}

private typealias Fixtures = ControlContractTests.ActionV1Fixtures

extension ControlContractTests {
    /// Shared by `ActionV1`, `ActionV1Refusals` and `ActionsV1`.
    enum ActionV1Fixtures {
        static func id(_ raw: String) throws -> ActionID {
            try #require(ActionID(rawValue: raw), "\(raw)")
        }

        static func policy(media: ActionMedia = .state, time: MediaTimePolicy? = nil, late: LatePolicy = .drop,
                           grid: Int64? = nil, retro: Int = 0,
                           stopped: StoppedPolicy = .wait) throws -> ActionPolicy {
            try ActionPolicy(media: media, timePolicy: time, latePolicy: late, gridTicks: grid,
                             retroactiveMs: retro, stoppedPolicy: stopped)
        }

        static func plan(_ frames: Int = 4096, _ count: Int = 16, _ head: Int = 48_000) throws -> PrefetchPlan {
            try PrefetchPlan.make(blockFrames: frames, blockCount: count, headFrames: head)
        }

        static func json(_ record: ActionV1Record) throws -> String {
            try #require(String(data: record.encodedJSON(), encoding: .utf8))
        }

        /// A state action that needs nothing else; `asap` unless `quantize` says otherwise.
        static func simple(_ raw: String = "act.a", quantize: TriggerTarget = .asap) throws -> ActionV1Record {
            try ActionV1Record.make(id: id(raw), policy: policy(), quantize: quantize, readiness: .ready)
        }

        /// 14 example actions (expected JSON from `json.dumps(action, sort_keys=True, separators=(",", ":"),
        /// ensure_ascii=False)` on the example files, never from the Swift encoder) and eleven hand-derived rows
        /// (each validated with the checker's `validate` against `$defs.action`).
        static let goldens: [ActionV1Golden] = examples + extras

        static let examples: [ActionV1Golden] = [
            .init("ex 01 act.loop-b",
                  id: "act.loop-b", media: .audio, time: .fixedRate, late: .nextBoundary(gridTicks: nil),
                  grid: 61440, quantize: .grid(ticks: 61440), readiness: .ready, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.loop-b","late":{"policy":"nextBoundary"},"media":"audio","#
                      + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
                      + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
                      + #""readiness":"ready","timePolicy":"fixedRate"}"#),
            .init("ex 02 act.loop-a",
                  id: "act.loop-a", media: .audio, time: .fixedRate, late: .joinInProgress(maxLatenessMs: 50),
                  retro: 40, quantize: .grid(ticks: 61440), readiness: .ready, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.loop-a","late":{"maxLatenessMs":50,"policy":"joinInProgress","#
                      + #""retroactiveMs":40},"media":"audio","notReady":"dropAndReport","#
                      + #""prefetch":{"blockCount":16,"blockFrames":4096,"headFrames":48000},"#
                      + #""quantize":{"gridTicks":61440,"timeBase":"musical"},"readiness":"ready","#
                      + #""timePolicy":"fixedRate"}"#),
            .init("ex 02 act.stab",
                  id: "act.stab", media: .midi, time: .tempoFollowing, late: .fireLate(maxLatenessMs: 10),
                  quantize: .grid(ticks: 15360), readiness: .ready,
                  json: #"{"actionId":"act.stab","late":{"maxLatenessMs":10,"policy":"fireLate"},"#
                      + #""media":"midi","notReady":"dropAndReport","quantize":{"gridTicks":15360,"#
                      + #""timeBase":"musical"},"readiness":"ready","timePolicy":"tempoFollowing"}"#),
            .init("ex 02 act.fx",
                  id: "act.fx", media: .state, time: nil, late: .drop, quantize: .grid(ticks: 15360),
                  readiness: .ready,
                  json: #"{"actionId":"act.fx","late":{"policy":"drop"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":15360,"timeBase":"musical"},"#
                      + #""readiness":"ready"}"#),
            .init("ex 02 act.scene",
                  id: "act.scene", media: .state, time: nil, late: .nextBoundary(gridTicks: nil), grid: 15360,
                  quantize: .grid(ticks: 15360), readiness: .ready,
                  json: #"{"actionId":"act.scene","late":{"policy":"nextBoundary"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":15360,"timeBase":"musical"},"#
                      + #""readiness":"ready"}"#),
            .init("ex 03 act.verse",
                  id: "act.verse", media: .midi, time: .tempoFollowing, late: .nextBoundary(gridTicks: nil),
                  grid: 61440, quantize: .grid(ticks: 61440), readiness: .ready,
                  json: #"{"actionId":"act.verse","late":{"policy":"nextBoundary"},"media":"midi","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":61440,"timeBase":"musical"},"#
                      + #""readiness":"ready","timePolicy":"tempoFollowing"}"#),
            .init("ex 03 act.backing",
                  id: "act.backing", media: .audio, time: .fixedRate, late: .joinInProgress(maxLatenessMs: 50),
                  quantize: .grid(ticks: 61440), readiness: .ready, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.backing","late":{"maxLatenessMs":50,"policy":"joinInProgress"},"#
                      + #""media":"audio","notReady":"dropAndReport","prefetch":{"blockCount":16,"#
                      + #""blockFrames":4096,"headFrames":48000},"quantize":{"gridTicks":61440,"#
                      + #""timeBase":"musical"},"readiness":"ready","timePolicy":"fixedRate"}"#),
            .init("ex 04 act.drums",
                  id: "act.drums", media: .midi, time: .tempoFollowing, late: .nextBoundary(gridTicks: nil),
                  grid: 15360, quantize: .grid(ticks: 15360), readiness: .ready,
                  json: #"{"actionId":"act.drums","late":{"policy":"nextBoundary"},"media":"midi","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":15360,"timeBase":"musical"},"#
                      + #""readiness":"ready","timePolicy":"tempoFollowing"}"#),
            .init("ex 04 act.backing",
                  id: "act.backing", media: .audio, time: .fixedRate, late: .joinInProgress(maxLatenessMs: 50),
                  quantize: .grid(ticks: 61440), readiness: .ready, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.backing","late":{"maxLatenessMs":50,"policy":"joinInProgress"},"#
                      + #""media":"audio","notReady":"dropAndReport","prefetch":{"blockCount":16,"#
                      + #""blockFrames":4096,"headFrames":48000},"quantize":{"gridTicks":61440,"#
                      + #""timeBase":"musical"},"readiness":"ready","timePolicy":"fixedRate"}"#),
            .init("ex 04 act.stretch",
                  id: "act.stretch", media: .audio, time: .timeStretch, late: .drop,
                  quantize: .grid(ticks: 61440), readiness: .unprepared, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.stretch","late":{"policy":"drop"},"media":"audio","#
                      + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
                      + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
                      + #""readiness":"unprepared","timePolicy":"timeStretch"}"#),
            .init("ex 05 act.backing",
                  id: "act.backing", media: .audio, time: .fixedRate, late: .joinInProgress(maxLatenessMs: 50),
                  quantize: .grid(ticks: 61440), readiness: .ready, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.backing","late":{"maxLatenessMs":50,"policy":"joinInProgress"},"#
                      + #""media":"audio","notReady":"dropAndReport","prefetch":{"blockCount":16,"#
                      + #""blockFrames":4096,"headFrames":48000},"quantize":{"gridTicks":61440,"#
                      + #""timeBase":"musical"},"readiness":"ready","timePolicy":"fixedRate"}"#),
            .init("ex 06 act.clip",
                  id: "act.clip", media: .midi, time: .tempoFollowing, late: .nextBoundary(gridTicks: nil),
                  grid: 61440, quantize: .grid(ticks: 61440), readiness: .ready,
                  json: #"{"actionId":"act.clip","late":{"policy":"nextBoundary"},"media":"midi","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":61440,"timeBase":"musical"},"#
                      + #""readiness":"ready","timePolicy":"tempoFollowing"}"#),
            .init("ex 06 act.scene",
                  id: "act.scene", media: .state, time: nil, late: .nextBoundary(gridTicks: nil), grid: 15360,
                  quantize: .grid(ticks: 15360), readiness: .ready,
                  json: #"{"actionId":"act.scene","late":{"policy":"nextBoundary"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":15360,"timeBase":"musical"},"#
                      + #""readiness":"ready"}"#),
            .init("ex 07 act.intro",
                  id: "act.intro", media: .audio, time: .fixedRate, late: .drop, quantize: .grid(ticks: 61440),
                  readiness: .unprepared, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.intro","late":{"policy":"drop"},"media":"audio","#
                      + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
                      + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
                      + #""readiness":"unprepared","timePolicy":"fixedRate"}"#)
        ]

        private static let extras: [ActionV1Golden] = [
            .init("hand transport",
                  id: "act.transport", media: .transport, time: nil, late: .drop, quantize: .grid(ticks: 480),
                  readiness: .ready,
                  json: #"{"actionId":"act.transport","late":{"policy":"drop"},"media":"transport","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":480,"timeBase":"musical"},"#
                      + #""readiness":"ready"}"#),
            .init("hand state nextBoundary",
                  id: "act.scene-b", media: .state, time: nil, late: .nextBoundary(gridTicks: 960),
                  quantize: .grid(ticks: 960), readiness: .preparing,
                  json: #"{"actionId":"act.scene-b","late":{"policy":"nextBoundary"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"gridTicks":960,"timeBase":"musical"},"#
                      + #""readiness":"preparing"}"#),
            .init("hand fireLate retroactive equals lateness",
                  id: "act.late-max", media: .midi, time: .fixedRate, late: .fireLate(maxLatenessMs: 120),
                  retro: 120, quantize: .grid(ticks: 15360), readiness: .invalidated,
                  json: #"{"actionId":"act.late-max","late":{"maxLatenessMs":120,"policy":"fireLate","#
                      + #""retroactiveMs":120},"media":"midi","notReady":"dropAndReport","#
                      + #""quantize":{"gridTicks":15360,"timeBase":"musical"},"readiness":"invalidated","#
                      + #""timePolicy":"fixedRate"}"#),
            .init("hand quantize musical",
                  id: "act.at-ticks", media: .state, time: nil, late: .drop, quantize: .musical(atTicks: 7680),
                  readiness: .failed,
                  json: #"{"actionId":"act.at-ticks","late":{"policy":"drop"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"atTicks":7680,"timeBase":"musical"},"#
                      + #""readiness":"failed"}"#),
            .init("hand quantize musical zero",
                  id: "act.at-zero", media: .state, time: nil, late: .drop, quantize: .musical(atTicks: 0),
                  readiness: .ready,
                  json: #"{"actionId":"act.at-zero","late":{"policy":"drop"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"atTicks":0,"timeBase":"musical"},"#
                      + #""readiness":"ready"}"#),
            .init("hand quantize sample",
                  id: "act.at-frame", media: .state, time: nil, late: .drop, quantize: .sample(atFrame: 48000),
                  readiness: .ready,
                  json: #"{"actionId":"act.at-frame","late":{"policy":"drop"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"atFrame":48000,"timeBase":"sample"},"#
                      + #""readiness":"ready"}"#),
            .init("hand quantize asap",
                  id: "act.now", media: .state, time: nil, late: .drop, quantize: .asap, readiness: .unprepared,
                  json: #"{"actionId":"act.now","late":{"policy":"drop"},"media":"state","#
                      + #""notReady":"dropAndReport","quantize":{"timeBase":"asap"},"readiness":"unprepared"}"#),
            .init("hand prefetch on midi",
                  id: "act.midi-pf", media: .midi, time: .fixedRate, late: .drop, quantize: .grid(ticks: 480),
                  readiness: .ready, prefetch: (64, 2, 128),
                  json: #"{"actionId":"act.midi-pf","late":{"policy":"drop"},"media":"midi","#
                      + #""notReady":"dropAndReport","prefetch":{"blockCount":2,"blockFrames":64,"#
                      + #""headFrames":128},"quantize":{"gridTicks":480,"timeBase":"musical"},"#
                      + #""readiness":"ready","timePolicy":"fixedRate"}"#),
            .init("hand largest prefetch and lateness",
                  id: "act.big", media: .audio, time: .fixedRate, late: .joinInProgress(maxLatenessMs: 1000),
                  retro: 120, quantize: .grid(ticks: 61440), readiness: .ready,
                  prefetch: (65536, 1024, 67_108_864),
                  json: #"{"actionId":"act.big","late":{"maxLatenessMs":1000,"policy":"joinInProgress","#
                      + #""retroactiveMs":120},"media":"audio","notReady":"dropAndReport","#
                      + #""prefetch":{"blockCount":1024,"blockFrames":65536,"headFrames":67108864},"#
                      + #""quantize":{"gridTicks":61440,"timeBase":"musical"},"readiness":"ready","#
                      + #""timePolicy":"fixedRate"}"#),
            .init("hand zero lateness",
                  id: "act.zero", media: .audio, time: .timeStretch, late: .fireLate(maxLatenessMs: 0),
                  quantize: .grid(ticks: 61440), readiness: .preparing, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.zero","late":{"maxLatenessMs":0,"policy":"fireLate"},"#
                      + #""media":"audio","notReady":"dropAndReport","prefetch":{"blockCount":16,"#
                      + #""blockFrames":4096,"headFrames":48000},"quantize":{"gridTicks":61440,"#
                      + #""timeBase":"musical"},"readiness":"preparing","timePolicy":"timeStretch"}"#),
            .init("hand ready timeStretch",
                  id: "act.stretch-ready", media: .audio, time: .timeStretch, late: .drop,
                  quantize: .grid(ticks: 61440), readiness: .ready, prefetch: (4096, 16, 48000),
                  json: #"{"actionId":"act.stretch-ready","late":{"policy":"drop"},"media":"audio","#
                      + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
                      + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
                      + #""readiness":"ready","timePolicy":"timeStretch"}"#)
        ]
    }

    struct ActionV1 {
        @Test func actionV1RecordEncodesTheGoldenActionsExactly() throws {
            #expect(Fixtures.examples.count == 14 && Fixtures.goldens.count == 25)
            for golden in Fixtures.goldens {
                let record = try golden.record()
                #expect(try Fixtures.json(record) == golden.json, "\(golden.label)")
                #expect(record.id.rawValue == golden.id && record.quantize == golden.quantize, "\(golden.label)")
                #expect(record.readiness == golden.readiness, "\(golden.label)")
                #expect(record.prefetch?.headFrames == golden.prefetch?.head, "\(golden.label)")
                #expect(try golden.record() == record, "\(golden.label)")
                #expect(try golden.record().encodedJSON() == record.encodedJSON(), "\(golden.label)")
            }
        }

        @Test func actionV1EveryReadinessStateIsWritten() throws {
            for state in ReadinessState.allCases {
                let record = try ActionV1Record.make(id: Fixtures.id("act.a"), policy: Fixtures.policy(),
                                                     quantize: .asap, readiness: state)
                #expect(try Fixtures.json(record).contains(#""readiness":"\#(state.rawValue)""#), "\(state)")
            }
            #expect(ReadinessState.allCases.count == 5)
        }

        @Test func actionV1StoppedPolicyIsDroppedOnPurpose() throws {
            let policies: [StoppedPolicy] = [.wait, .immediate, .startTransport]
            let outputs = try policies.map { stopped in
                try ActionV1Record.make(id: Fixtures.id("act.a"), policy: Fixtures.policy(stopped: stopped),
                                        quantize: .asap, readiness: .ready).encodedJSON()
            }
            #expect(Set(outputs).count == 1)
            #expect(try String(data: #require(outputs.first), encoding: .utf8)?.contains("stopped") == false)
        }

        @Test func actionV1ZeroRetroactiveIsOmittedAndLatenessIsWrittenOnlyWhereItExists() throws {
            func late(_ policy: ActionPolicy, quantize: TriggerTarget = .grid(ticks: 480)) throws -> [String: Any] {
                let record = try ActionV1Record.make(id: Fixtures.id("act.a"), policy: policy, quantize: quantize,
                                                     readiness: .ready)
                let object = try #require(JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any])
                return try #require(object["late"] as? [String: Any])
            }
            #expect(try Set(late(Fixtures.policy(late: .fireLate(maxLatenessMs: 10))).keys)
                    == ["policy", "maxLatenessMs"])
            #expect(try Set(late(Fixtures.policy(late: .joinInProgress(maxLatenessMs: 0))).keys)
                    == ["policy", "maxLatenessMs"])
            #expect(try Set(late(Fixtures.policy(late: .fireLate(maxLatenessMs: 10), retro: 1)).keys)
                    == ["policy", "maxLatenessMs", "retroactiveMs"])
            #expect(try Set(late(Fixtures.policy(late: .drop)).keys) == ["policy"])
            #expect(try Set(late(Fixtures.policy(late: .nextBoundary(gridTicks: 480))).keys) == ["policy"])
            #expect(try Set(late(Fixtures.policy(late: .nextBoundary(gridTicks: nil), grid: 480)).keys)
                    == ["policy"])
        }

        @Test func actionV1WritesExactlyTheSchemaFields() throws {
            let bare = try Fixtures.simple()
            let full = try ActionV1Record.make(
                id: Fixtures.id("act.a"),
                policy: Fixtures.policy(media: .audio, time: .fixedRate, late: .fireLate(maxLatenessMs: 5), retro: 2),
                quantize: .grid(ticks: 4), readiness: .ready, prefetch: Fixtures.plan())
            let required: Set = ["actionId", "media", "quantize", "late", "notReady", "readiness"]
            for (record, keys) in [(bare, required), (full, required.union(["timePolicy", "prefetch"]))] {
                let object = try #require(JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any])
                #expect(Set(object.keys) == keys)
                #expect(object["notReady"] as? String == "dropAndReport")
            }
            let object = try #require(JSONSerialization.jsonObject(with: full.encodedJSON()) as? [String: Any])
            let prefetch = try #require(object["prefetch"] as? [String: Int])
            #expect(prefetch == ["blockFrames": 4096, "blockCount": 16, "headFrames": 48_000])
        }

        @Test func actionV1QuantizeIsWrittenLikeATriggerRecordTarget() throws {
            let targets: [TriggerTarget] = [.grid(ticks: 480), .musical(atTicks: 0), .musical(atTicks: 7680),
                                            .sample(atFrame: 48_000), .asap]
            for target in targets {
                let action = try Fixtures.simple(quantize: target)
                let stamp = try ControlContractTests.TriggerV1Fixtures.stamp(target: target)
                let trigger = try TriggerV1Record.make(stamp, seq: 1)
                let actionObject = try #require(
                    JSONSerialization.jsonObject(with: action.encodedJSON()) as? [String: Any])
                let triggerObject = try #require(
                    JSONSerialization.jsonObject(with: trigger.encodedJSON()) as? [String: Any])
                let quantize = try #require(actionObject["quantize"])
                let written = try #require(triggerObject["target"])
                let sorted = JSONSerialization.WritingOptions.sortedKeys
                #expect(try JSONSerialization.data(withJSONObject: quantize, options: sorted)
                        == JSONSerialization.data(withJSONObject: written, options: sorted), "\(target)")
            }
        }

        @Test func actionV1LeavesTheTimeStretchCapabilityAndUseToTheChecker() throws {
            // `ready` `timeStretch` needs `adapterCapabilities.timeStretch` (a cross-header rule), and no trigger
            // or readiness record has to name the action: the builder accepts both.
            let record = try ActionV1Record.make(
                id: Fixtures.id("act.alone"), policy: Fixtures.policy(media: .audio, time: .timeStretch),
                quantize: .asap, readiness: .ready, prefetch: Fixtures.plan())
            #expect(try Fixtures.json(record).contains(#""readiness":"ready","timePolicy":"timeStretch""#))
        }

        @Test func actionV1AcceptsTheLongestIDAndOnlyTheLongestID() throws {
            let longest = "act." + String(repeating: "a", count: 124)
            #expect(longest.utf8.count == 128)
            let record = try Fixtures.simple(longest)
            #expect(try Fixtures.json(record).hasPrefix(#"{"actionId":"\#(longest)","#))
            #expect(ActionID(rawValue: longest + "a") == nil)
        }
    }
}
