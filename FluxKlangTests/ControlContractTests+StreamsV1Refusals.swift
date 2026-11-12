//
//  ControlContractTests+StreamsV1Refusals.swift
//  FluxKlangTests
//
//  The media contract v1 `streams` header builder (#107 STR1): each refusal, the first-offence order, and the
//  repeated-ordinal rule that is stricter than the checker.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = StreamsV1RecordRefusal

private func refusal(_ streams: [StreamsV1Stream]) -> Refusal? {
    do {
        _ = try StreamsV1Record.make(streams)
        return nil
    } catch {
        return error
    }
}

private func sid(_ raw: String) -> StreamID {
    streamsV1ID(raw)
}

extension ControlContractTests {
    struct StreamsV1Refusals {
        @Test func streamsV1RefusesAnEmptyList() {
            #expect(refusal([]) == .empty)
        }

        @Test func streamsV1RefusesInvalidStreamIDs() {
            let invalid = ["str.Bed", "str_bed.a", "str:bed.a", "strbed", "str.", "1str.a", "-str.a", "str.a_b",
                           "STR.A"]
            for raw in invalid {
                #expect(refusal([streamsV1(raw, 0)]) == .invalidStreamID(sid(raw)), "\(raw)")
            }
            #expect(refusal([streamsV1("str." + String(repeating: "a", count: 124), 0)]) == nil)
        }

        @Test func streamsV1RefusesNegativeOrdinals() {
            #expect(refusal([streamsV1("str.a", -1)]) == .negativeOrdinal(sid("str.a"), -1))
            #expect(refusal([streamsV1("str.a", Int.min)]) == .negativeOrdinal(sid("str.a"), Int.min))
            #expect(refusal([streamsV1("str.a", 0)]) == nil)
        }

        @Test func streamsV1RefusesRepeatedIDsAndOrdinals() {
            #expect(refusal([streamsV1("str.a", 0), streamsV1("str.b", 1), streamsV1("str.a", 2, .audio, .playback)])
                        == .duplicateStreamID(sid("str.a")))
            #expect(refusal([streamsV1("str.a", 3), streamsV1("str.b", 1), streamsV1("str.c", 3)])
                        == .duplicateOrdinal(sid("str.c"), ordinal: 3))
            // The same ID and ordinal with other media is still a repeat.
            #expect(refusal([streamsV1("str.a", 0), streamsV1("str.a", 0, .state, .playback)])
                        == .duplicateStreamID(sid("str.a")))
        }

        /// The checker accepts two streams with one ordinal; the exporter does not, as §6.5 dispatch order would be
        /// ambiguous.
        @Test func streamsV1RepeatedOrdinalIsStricterThanTheChecker() {
            #expect(refusal([streamsV1("str.keys-a", 0), streamsV1("str.keys-b", 0)])
                        == .duplicateOrdinal(sid("str.keys-b"), ordinal: 0))
        }

        @Test func streamsV1ReportsTheFirstOffenceInOrder() {
            let many = (0...StreamsV1Record.maximumStreams).map { streamsV1("str.s\($0)", $0) }
            // An oversized list is refused before any stream is read.
            #expect(refusal([streamsV1("Bad", -1)] + many) == .tooManyStreams(count: 4098))
            // One stream breaking several rules: ID, then negative ordinal.
            #expect(refusal([streamsV1("Bad", -1)]) == .invalidStreamID(sid("Bad")))
            // Across rules in a list: negative ordinal beats a repeated ID, a repeated ID beats a repeated ordinal.
            #expect(refusal([streamsV1("str.a", 0), streamsV1("str.a", -1)]) == .negativeOrdinal(sid("str.a"), -1))
            #expect(refusal([streamsV1("str.a", 0), streamsV1("str.a", 0)]) == .duplicateStreamID(sid("str.a")))
            // An earlier stream's offence wins over any later one, even a higher-ranked rule.
            #expect(refusal([streamsV1("str.a", 0), streamsV1("str.b", 0), streamsV1("Bad", -1)])
                        == .duplicateOrdinal(sid("str.b"), ordinal: 0))
            #expect(refusal([streamsV1("str.a", 0), streamsV1("str.a", 1), streamsV1("Bad", 2)])
                        == .duplicateStreamID(sid("str.a")))
            #expect(refusal([streamsV1("str.a", -1), streamsV1("Bad", 0)]) == .negativeOrdinal(sid("str.a"), -1))
        }
    }
}
