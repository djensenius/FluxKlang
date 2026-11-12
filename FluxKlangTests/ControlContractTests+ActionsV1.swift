//
//  ControlContractTests+ActionsV1.swift
//  FluxKlangTests
//
//  The media contract v1 `actions` header builder (#107 ACT1): the `actions` array of examples 01 to 07 byte for
//  byte, the bounds, the refusals and their order, and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixtures = ControlContractTests.ActionV1Fixtures

/// A golden header: the example's `actions` array, built from the golden action rows named in `rows`.
private struct ActionsV1Golden {
    let label: String
    let rows: [String]
    let json: String

    init(_ label: String, rows: [String], json: String) {
        (self.label, self.rows, self.json) = (label, rows, json)
    }
}

private let goldens: [ActionsV1Golden] = [
    .init("ex 01", rows: ["ex 01 act.loop-b"],
          json: #"[{"actionId":"act.loop-b","late":{"policy":"nextBoundary"},"media":"audio","#
              + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
              + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
              + #""readiness":"ready","timePolicy":"fixedRate"}]"#),
    .init("ex 02", rows: ["ex 02 act.loop-a", "ex 02 act.stab", "ex 02 act.fx", "ex 02 act.scene"],
          json: #"[{"actionId":"act.loop-a","late":{"maxLatenessMs":50,"policy":"joinInProgress","#
              + #""retroactiveMs":40},"media":"audio","notReady":"dropAndReport","#
              + #""prefetch":{"blockCount":16,"blockFrames":4096,"headFrames":48000},"#
              + #""quantize":{"gridTicks":61440,"timeBase":"musical"},"readiness":"ready","#
              + #""timePolicy":"fixedRate"},{"actionId":"act.stab","late":{"maxLatenessMs":10,"#
              + #""policy":"fireLate"},"media":"midi","notReady":"dropAndReport","#
              + #""quantize":{"gridTicks":15360,"timeBase":"musical"},"readiness":"ready","#
              + #""timePolicy":"tempoFollowing"},{"actionId":"act.fx","late":{"policy":"drop"},"#
              + #""media":"state","notReady":"dropAndReport","quantize":{"gridTicks":15360,"#
              + #""timeBase":"musical"},"readiness":"ready"},{"actionId":"act.scene","#
              + #""late":{"policy":"nextBoundary"},"media":"state","notReady":"dropAndReport","#
              + #""quantize":{"gridTicks":15360,"timeBase":"musical"},"readiness":"ready"}]"#),
    .init("ex 03", rows: ["ex 03 act.verse", "ex 03 act.backing"],
          json: #"[{"actionId":"act.verse","late":{"policy":"nextBoundary"},"media":"midi","#
              + #""notReady":"dropAndReport","quantize":{"gridTicks":61440,"timeBase":"musical"},"#
              + #""readiness":"ready","timePolicy":"tempoFollowing"},{"actionId":"act.backing","#
              + #""late":{"maxLatenessMs":50,"policy":"joinInProgress"},"media":"audio","#
              + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
              + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
              + #""readiness":"ready","timePolicy":"fixedRate"}]"#),
    .init("ex 04", rows: ["ex 04 act.drums", "ex 04 act.backing", "ex 04 act.stretch"],
          json: #"[{"actionId":"act.drums","late":{"policy":"nextBoundary"},"media":"midi","#
              + #""notReady":"dropAndReport","quantize":{"gridTicks":15360,"timeBase":"musical"},"#
              + #""readiness":"ready","timePolicy":"tempoFollowing"},{"actionId":"act.backing","#
              + #""late":{"maxLatenessMs":50,"policy":"joinInProgress"},"media":"audio","#
              + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
              + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
              + #""readiness":"ready","timePolicy":"fixedRate"},{"actionId":"act.stretch","#
              + #""late":{"policy":"drop"},"media":"audio","notReady":"dropAndReport","#
              + #""prefetch":{"blockCount":16,"blockFrames":4096,"headFrames":48000},"#
              + #""quantize":{"gridTicks":61440,"timeBase":"musical"},"readiness":"unprepared","#
              + #""timePolicy":"timeStretch"}]"#),
    .init("ex 05", rows: ["ex 05 act.backing"],
          json: #"[{"actionId":"act.backing","late":{"maxLatenessMs":50,"policy":"joinInProgress"},"#
              + #""media":"audio","notReady":"dropAndReport","prefetch":{"blockCount":16,"#
              + #""blockFrames":4096,"headFrames":48000},"quantize":{"gridTicks":61440,"#
              + #""timeBase":"musical"},"readiness":"ready","timePolicy":"fixedRate"}]"#),
    .init("ex 06", rows: ["ex 06 act.clip", "ex 06 act.scene"],
          json: #"[{"actionId":"act.clip","late":{"policy":"nextBoundary"},"media":"midi","#
              + #""notReady":"dropAndReport","quantize":{"gridTicks":61440,"timeBase":"musical"},"#
              + #""readiness":"ready","timePolicy":"tempoFollowing"},{"actionId":"act.scene","#
              + #""late":{"policy":"nextBoundary"},"media":"state","notReady":"dropAndReport","#
              + #""quantize":{"gridTicks":15360,"timeBase":"musical"},"readiness":"ready"}]"#),
    .init("ex 07", rows: ["ex 07 act.intro"],
          json: #"[{"actionId":"act.intro","late":{"policy":"drop"},"media":"audio","#
              + #""notReady":"dropAndReport","prefetch":{"blockCount":16,"blockFrames":4096,"#
              + #""headFrames":48000},"quantize":{"gridTicks":61440,"timeBase":"musical"},"#
              + #""readiness":"unprepared","timePolicy":"fixedRate"}]"#)
]

private func refusal(_ actions: [ActionV1Record]) -> ActionsV1RecordRefusal? {
    do {
        _ = try ActionsV1Record.make(actions)
        return nil
    } catch {
        return error
    }
}

private func numbered(_ count: Int) throws -> [ActionV1Record] {
    try (0..<count).map { try Fixtures.simple("act.n\($0)") }
}

extension ControlContractTests {
    struct ActionsV1 {
        @Test func actionsV1HeaderEncodesTheExampleActionArraysExactly() throws {
            #expect(goldens.count == 7)
            for golden in goldens {
                let actions = try golden.rows.map { label in
                    try #require(Fixtures.examples.first { $0.label == label }, "\(label)").record()
                }
                let header = try ActionsV1Record.make(actions)
                #expect(header.actions == actions, "\(golden.label)")
                let text = try #require(String(data: header.encodedJSON(), encoding: .utf8))
                #expect(text == golden.json, "\(golden.label)")
                #expect(try ActionsV1Record.make(actions) == header, "\(golden.label)")
            }
        }

        @Test func actionsV1HeaderKeepsTheCallersOrder() throws {
            let ids = ["act.c", "act.a", "act.b"]
            let header = try ActionsV1Record.make(ids.map { try Fixtures.simple($0) })
            #expect(header.actions.map(\.id.rawValue) == ids)
            let array = try #require(JSONSerialization.jsonObject(with: header.encodedJSON()) as? [[String: Any]])
            #expect(array.map { $0["actionId"] as? String } == ids)
        }

        @Test func actionsV1HeaderRefusesAnEmptyList() {
            #expect(refusal([]) == .empty)
        }

        @Test func actionsV1HeaderAdmitsExactlyTheCapacity() throws {
            #expect(ActionsV1Record.maximumActions == 4096)
            let full = try numbered(4096)
            #expect(try ActionsV1Record.make(full).actions.count == 4096)
            let over = try numbered(4097)
            #expect(refusal(over) == .tooManyActions(count: 4097))
            #expect(refusal(Array(repeating: full[0], count: 4097)) == .tooManyActions(count: 4097))
        }

        @Test func actionsV1HeaderNamesTheLaterRepeatedID() throws {
            let first = try Fixtures.simple("act.a")
            let second = try Fixtures.simple("act.b")
            #expect(refusal([first, second, first]) == .duplicateActionID(first.id))
            #expect(refusal([first, second, second, first]) == .duplicateActionID(second.id))
            #expect(refusal([first, first]) == .duplicateActionID(first.id))
            // The same ID with other content still repeats the `actionId`.
            let other = try Fixtures.simple("act.a", quantize: .grid(ticks: 480))
            #expect(refusal([first, other]) == .duplicateActionID(first.id))
            #expect(refusal([first, second]) == nil)
        }
    }
}
