//
//  ControlContractTests+ActionV1Refusals.swift
//  FluxKlangTests
//
//  The media contract v1 `actions` entry builder (#107 ACT1): every refusal, the grid agreement between the
//  policy and `quantize`, and the order in which a declaration that breaks several rules reports them.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixtures = ControlContractTests.ActionV1Fixtures
private typealias Refusal = ActionV1RecordRefusal

private func refusal(_ policy: ActionPolicy, id: String = "act.a", quantize: TriggerTarget = .grid(ticks: 480),
                     prefetch: PrefetchPlan? = nil) throws -> Refusal? {
    do {
        _ = try ActionV1Record.make(id: Fixtures.id(id), policy: policy, quantize: quantize, readiness: .ready,
                                    prefetch: prefetch)
        return nil
    } catch let error as Refusal {
        return error
    }
}

/// A policy with an unknown member inside `latePolicy`, which only decoding can produce.
private func policyWithLateUnknown() throws -> ActionPolicy {
    let json = JSONValue.object([
        "media": .string("state"), "latePolicy": .object(["drop": .object([:]), "future": .bool(true)]),
        "retroactiveMs": .int(0), "stoppedPolicy": .string("wait")
    ])
    return try ContractCoding.decode(ActionPolicy.self, from: ContractCoding.makeEncoder().encode(json))
}

extension ControlContractTests {
    struct ActionV1Refusals {
        @Test func actionV1RefusesAnIDOutsideTheMediaContractPattern() throws {
            let policy = try Fixtures.policy()
            for raw in ["Act.a", "act_a", "act:a", "act", "act.", "1act.a"] {
                let id = try #require(ActionID(rawValue: raw), "\(raw)")
                #expect(try refusal(policy, id: raw) == .invalidActionID(id), "\(raw)")
            }
            #expect(try refusal(policy, id: "a-b.c.d") == nil)
        }

        @Test func actionV1RefusesExtensionFieldsTheV1ActionCannotWrite() throws {
            var unknown = try Fixtures.policy()
            unknown.unknownFields = ["future": .bool(true)]
            #expect(try refusal(unknown) == .extensionFields)
            var extended = try Fixtures.policy()
            extended.extensions = ["vendor": .null]
            #expect(try refusal(extended) == .extensionFields)
            let late = try policyWithLateUnknown()
            #expect(late.hasUnknownFields)
            #expect(try refusal(late) == .extensionFields)
            // An empty extensions bag holds nothing to lose.
            var empty = try Fixtures.policy()
            empty.extensions = [:]
            #expect(try refusal(empty) == nil)
        }

        @Test func actionV1RefusesAGridBelowOneAndMusicalTicksBelowZero() throws {
            let policy = try Fixtures.policy()
            for ticks in [Int64(0), -1, Int64.min] {
                #expect(try refusal(policy, quantize: .grid(ticks: ticks)) == .invalidGrid(ticks), "\(ticks)")
            }
            for ticks in [Int64(-1), Int64.min] {
                #expect(try refusal(policy, quantize: .musical(atTicks: ticks)) == .negativeMusicalTicks(ticks))
            }
            #expect(try refusal(policy, quantize: .grid(ticks: 1)) == nil)
            #expect(try refusal(policy, quantize: .grid(ticks: Int64.max)) == nil)
            #expect(try refusal(policy, quantize: .musical(atTicks: 0)) == nil)
            #expect(try refusal(policy, quantize: .sample(atFrame: -1)) == nil)
            #expect(try refusal(policy, quantize: .asap) == nil)
        }

        @Test func actionV1RefusesAnAudioActionWithoutPrefetchOnly() throws {
            let audio = try Fixtures.policy(media: .audio, time: .fixedRate)
            #expect(try refusal(audio) == .audioWithoutPrefetch)
            #expect(try refusal(audio, prefetch: Fixtures.plan()) == nil)
            for media in [ActionMedia.midi, .state, .transport] {
                let time: MediaTimePolicy? = media == .midi ? .fixedRate : nil
                #expect(try refusal(Fixtures.policy(media: media, time: time)) == nil, "\(media)")
            }
        }

        @Test func actionV1RefusesNextBoundaryWithoutAGridQuantize() throws {
            let policy = try Fixtures.policy(late: .nextBoundary(gridTicks: 480))
            for target in [TriggerTarget.musical(atTicks: 480), .sample(atFrame: 480), .asap] {
                #expect(try refusal(policy, quantize: target) == .nextBoundaryWithoutGrid, "\(target)")
            }
            let outer = try Fixtures.policy(late: .nextBoundary(gridTicks: nil), grid: 480)
            #expect(try refusal(outer, quantize: .asap) == .nextBoundaryWithoutGrid)
            #expect(try refusal(policy, quantize: .grid(ticks: 480)) == nil)
            #expect(try refusal(outer, quantize: .grid(ticks: 480)) == nil)
        }

        @Test func actionV1RefusesAPolicyGridThatQuantizeDoesNotState() throws {
            let policy = try Fixtures.policy(grid: 480)
            for target in [TriggerTarget.asap, .grid(ticks: 960), .musical(atTicks: 480), .sample(atFrame: 480)] {
                #expect(try refusal(policy, quantize: target) == .policyGridMismatch(policy: 480, quantize: target),
                        "\(target)")
            }
            #expect(try refusal(policy, quantize: .grid(ticks: 480)) == nil)
            let inner = try Fixtures.policy(late: .nextBoundary(gridTicks: 480))
            #expect(try refusal(inner, quantize: .grid(ticks: 960))
                    == .policyGridMismatch(policy: 480, quantize: .grid(ticks: 960)))
        }

        @Test func actionV1ReportsThePolicyGridFirstWhenBothGridsDisagree() throws {
            let both = try Fixtures.policy(late: .nextBoundary(gridTicks: 960), grid: 480)
            #expect(try refusal(both, quantize: .grid(ticks: 960))
                    == .policyGridMismatch(policy: 480, quantize: .grid(ticks: 960)))
            #expect(try refusal(both, quantize: .grid(ticks: 480))
                    == .policyGridMismatch(policy: 960, quantize: .grid(ticks: 480)))
            #expect(try refusal(both, quantize: .grid(ticks: 240))
                    == .policyGridMismatch(policy: 480, quantize: .grid(ticks: 240)))
            let equal = try Fixtures.policy(late: .nextBoundary(gridTicks: 480), grid: 480)
            #expect(try refusal(equal, quantize: .grid(ticks: 480)) == nil)
        }

        @Test func actionV1RefusesInTheDocumentedOrder() throws {
            var policy = try Fixtures.policy(media: .audio, time: .fixedRate, late: .nextBoundary(gridTicks: 480),
                                             grid: 960)
            policy.unknownFields = ["future": .null]
            let bad = "Act.a"
            let id = try #require(ActionID(rawValue: bad))
            #expect(try refusal(policy, id: bad, quantize: .grid(ticks: 0)) == .invalidActionID(id))
            #expect(try refusal(policy, quantize: .grid(ticks: 0)) == .extensionFields)
            policy.unknownFields = [:]
            #expect(try refusal(policy, quantize: .grid(ticks: 0)) == .invalidGrid(0))
            #expect(try refusal(policy, quantize: .musical(atTicks: -1)) == .negativeMusicalTicks(-1))
            #expect(try refusal(policy, quantize: .asap) == .audioWithoutPrefetch)
            let plan = try Fixtures.plan()
            #expect(try refusal(policy, quantize: .asap, prefetch: plan) == .nextBoundaryWithoutGrid)
            let drop = try Fixtures.policy(media: .audio, time: .fixedRate, grid: 960)
            #expect(try refusal(drop, quantize: .asap, prefetch: plan)
                    == .policyGridMismatch(policy: 960, quantize: .asap))
            #expect(try refusal(drop, quantize: .grid(ticks: 960), prefetch: plan) == nil)
        }
    }
}
