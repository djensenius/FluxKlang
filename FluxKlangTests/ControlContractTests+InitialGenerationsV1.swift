//
//  ControlContractTests+InitialGenerationsV1.swift
//  FluxKlangTests
//
//  The media contract v1 `initialGenerations` builder (#84 IGX1): every example map rebuilt from a ledger byte for
//  byte, UTF-8 key order, several counters of each kind, the refusal order, and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = InitialGenerationsV1RecordRefusal

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")

private func key(_ kind: GenerationKind, _ subject: StaticString) -> GenerationKey {
    GenerationKey(kind: kind, subject: GenerationSubject(validated: subject))
}

private func generation(_ value: Int) throws -> Generation {
    try Generation(value)
}

private func initialRefusal(_ generations: [GenerationKey: Generation],
                            musicalClock: ClockID? = musMain) -> Refusal? {
    do {
        _ = try InitialGenerationsV1Record.make(generations: generations, musicalClock: musicalClock)
        return nil
    } catch {
        return error
    }
}

private func json(_ record: InitialGenerationsV1Record) throws -> String {
    try #require(String(data: record.encodedJSON(), encoding: .utf8))
}

/// The ledger behind a media contract example: `smp.main`, an optional `mus.main` and the declared counters.
private func exampleLedger(musical: Bool = true, declaring counters: [GenerationKey]) throws -> GenerationLedger {
    try GenerationLedger(primaryClock: smpMain, musicalClock: musical ? musMain : nil, nominalRate: 48_000,
                         declaring: counters)
}

/// A golden `initialGenerations` map from the media contract examples, keys sorted, compact; each ledger
/// declares `mus.main`, as every example does. Example 08 has no transport counters, so it is pinned separately.
private struct GoldenInitialGenerations {
    let label: String
    let counters: [GenerationKey]
    let json: String
}

private let context = key(.context, "ctx.main")
private let fourCounters = #"{"context/ctx.main":1,"musicalMap/mus.main":1,"sampleClock/smp.main":1,"#
    + #""transport/mus.main":1}"#

private let goldenInitialGenerations: [GoldenInitialGenerations] = [
    .init(label: "01 02 03 04 07 09 10", counters: [context], json: fourCounters),
    .init(label: "05", counters: [context, key(.source, "src.backing")],
          json: #"{"context/ctx.main":1,"musicalMap/mus.main":1,"sampleClock/smp.main":1,"#
            + #""source/src.backing":1,"transport/mus.main":1}"#),
    .init(label: "06", counters: [context, key(.cancelScope, "set.verse")],
          json: #"{"cancelScope/set.verse":1,"context/ctx.main":1,"musicalMap/mus.main":1,"#
            + #""sampleClock/smp.main":1,"transport/mus.main":1}"#)
]

extension ControlContractTests {
    struct InitialGenerationsV1 {
        @Test func initialGenerationsV1EncodesEveryExampleMapFromALedgerExactly() throws {
            for golden in goldenInitialGenerations {
                let ledger = try exampleLedger(declaring: golden.counters)
                let record = try InitialGenerationsV1Record.make(from: ledger)
                #expect(try json(record) == golden.json, "\(golden.label)")
                #expect(record.generations == ledger.current, "\(golden.label)")
                let again = try InitialGenerationsV1Record.make(generations: ledger.current,
                                                                musicalClock: ledger.musicalClock)
                #expect(again == record, "\(golden.label)")
                #expect(try again.encodedJSON() == record.encodedJSON(), "\(golden.label)")
            }
        }

        /// Example 08 declares the musical clock `mus.main` but has no transport or musicalMap counters.
        @Test func initialGenerationsV1EncodesExample08WithoutMusicalCounters() throws {
            let generations = [context: Generation.initial, key(.sampleClock, "smp.main"): .initial]
            let record = try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
            #expect(try json(record) == #"{"context/ctx.main":1,"sampleClock/smp.main":1}"#)
        }

        /// Not an example: a ledger without transport has no musical counters. Its nil musical clock is refused
        /// later, at the `clocks` header, which v1 always requires.
        @Test func initialGenerationsV1SnapshotsALedgerWithoutTransport() throws {
            let ledger = try exampleLedger(musical: false, declaring: [context])
            let record = try InitialGenerationsV1Record.make(from: ledger)
            #expect(try json(record) == #"{"context/ctx.main":1,"sampleClock/smp.main":1}"#)
        }

        @Test func initialGenerationsV1WritesKeysInUTF8ByteOrder() throws {
            // `-` < `.` < `/` < digits < lower case: a numeric or case-folding sort would differ.
            let subjects: [StaticString] = ["src.a9", "src.ab", "src.a10", "src.a.b", "src.a-b", "src.a0", "src.a"]
            var generations = [key(.sampleClock, "smp.main"): Generation.initial]
            for subject in subjects { generations[key(.source, subject)] = .initial }
            generations[key(.cancelScope, "set.z")] = .initial
            generations[key(.transport, "mus.main")] = .initial
            let record = try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
            #expect(try json(record) == #"{"cancelScope/set.z":1,"sampleClock/smp.main":1,"source/src.a":1,"#
                + #""source/src.a-b":1,"source/src.a.b":1,"source/src.a0":1,"source/src.a10":1,"source/src.a9":1,"#
                + #""source/src.ab":1,"transport/mus.main":1}"#)
            // Insertion order does not matter: the same counters built in reverse encode identically.
            let descending = generations.sorted { $0.key.description > $1.key.description }
            let reversed = Dictionary(uniqueKeysWithValues: descending)
            let rebuilt = try InitialGenerationsV1Record.make(generations: reversed, musicalClock: musMain)
            #expect(try rebuilt.encodedJSON() == record.encodedJSON())
        }

        @Test func initialGenerationsV1HoldsSeveralCountersOfEachKindAndWritesValuesAsGiven() throws {
            let generations: [GenerationKey: Generation] = try [
                key(.sampleClock, "smp.main"): .initial, key(.sampleClock, "smp.secondary"): generation(2),
                key(.transport, "mus.main"): generation(3), key(.musicalMap, "mus.main"): generation(4),
                key(.source, "src.backing"): .initial, key(.source, "src.drums"): generation(5),
                key(.context, "ctx.main"): .initial, key(.context, "ctx.lease"): generation(6),
                key(.cancelScope, "set.verse"): .initial,
                key(.cancelScope, "set.chorus"): generation(Generation.maximumValue)
            ]
            let record = try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
            #expect(record.generations == generations)
            #expect(try json(record) == #"{"cancelScope/set.chorus":9007199254740991,"cancelScope/set.verse":1,"#
                + #""context/ctx.lease":6,"context/ctx.main":1,"musicalMap/mus.main":4,"sampleClock/smp.main":1,"#
                + #""sampleClock/smp.secondary":2,"source/src.backing":1,"source/src.drums":5,"transport/mus.main":3}"#)
            let decoded = try JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Int]
            let object = try #require(decoded)
            #expect(object.count == generations.count)
            for (counter, value) in generations {
                #expect(object[counter.description] == value.value, "\(counter)")
            }
        }

        @Test func initialGenerationsV1SnapshotsALedgerWithDeclaredCounters() throws {
            let counters = [
                key(.source, "src.backing"), key(.source, "src.drums"), key(.context, "ctx.main"),
                key(.context, "ctx.lease"), key(.cancelScope, "set.verse"), key(.cancelScope, "set.chorus")
            ]
            var ledger = try exampleLedger(declaring: counters)
            let record = try InitialGenerationsV1Record.make(from: ledger)
            #expect(record.generations.count == 9)
            #expect(record.generations.values.allSatisfy { $0 == .initial })
            #expect(try json(record) == #"{"cancelScope/set.chorus":1,"cancelScope/set.verse":1,"#
                + #""context/ctx.lease":1,"context/ctx.main":1,"musicalMap/mus.main":1,"sampleClock/smp.main":1,"#
                + #""source/src.backing":1,"source/src.drums":1,"transport/mus.main":1}"#)
            // The builder copies a snapshot: a later bump changes neither the record nor its bytes.
            let bytes = try record.encodedJSON()
            try ledger.bump(key(.context, "ctx.main"), reason: .contextChange)
            #expect(try record.encodedJSON() == bytes)
            // A map taken after a bump writes the bumped value; callers snapshot before the first bump.
            let late = try InitialGenerationsV1Record.make(from: ledger)
            #expect(late.generations[key(.context, "ctx.main")] == (try generation(2)))
        }

        @Test func initialGenerationsV1RefusesInOrderWithoutDroppingOrRemapping() throws {
            #expect(initialRefusal([:]) == .empty)
            #expect(initialRefusal([:], musicalClock: nil) == .empty)
            let badSubject = key(.context, "Ctx.main")
            let foreignTransport = key(.transport, "mus.other")
            // Both offences in one counter: the subject is checked first.
            let badTransport = key(.transport, "Mus.main")
            #expect(initialRefusal([badTransport: .initial], musicalClock: ClockID(validated: "Mus.main"))
                        == .invalidCounterSubject(badTransport))
            // Across counters, the first in UTF-8 byte order of `kind/subject` is reported, whatever its offence.
            #expect(initialRefusal([badSubject: .initial, foreignTransport: .initial])
                        == .invalidCounterSubject(badSubject))
            let earlierMap = key(.musicalMap, "mus.other")
            #expect(initialRefusal([foreignTransport: .initial, earlierMap: .initial, key(.source, "Src.a"): .initial])
                        == .undeclaredMusicalClock(earlierMap))
            let invalid: [StaticString] = [
                "ctx_main.a", "ctx", "ctx.", "1ctx.a", "ctx:1.a", "CTX.MAIN", "-ctx.a", "ctx.a_b"
            ]
            for raw in invalid {
                for kind in GenerationKind.allCases {
                    let counter = key(kind, raw)
                    #expect(initialRefusal([counter: .initial]) == .invalidCounterSubject(counter), "\(counter)")
                }
            }
        }

        @Test func initialGenerationsV1MusicalCountersMustNameTheDeclaredMusicalClock() throws {
            for kind in [GenerationKind.transport, .musicalMap] {
                let own = key(kind, "mus.main")
                let foreign = key(kind, "mus.other")
                #expect(initialRefusal([own: .initial]) == nil, "\(own)")
                #expect(initialRefusal([foreign: .initial]) == .undeclaredMusicalClock(foreign), "\(foreign)")
                #expect(initialRefusal([own: .initial], musicalClock: nil) == .undeclaredMusicalClock(own), "\(own)")
                // The primary sample clock's ID is not the musical clock either.
                let primary = key(kind, "smp.main")
                #expect(initialRefusal([primary: .initial]) == .undeclaredMusicalClock(primary), "\(primary)")
            }
            // Other kinds may name any valid subject, including the musical clock's ID.
            for kind in [GenerationKind.sampleClock, .source, .context, .cancelScope] {
                #expect(initialRefusal([key(kind, "mus.main"): .initial], musicalClock: nil) == nil, "\(kind)")
            }
            // A ledger whose primary clock ID fails the v1 pattern is refused, not rewritten.
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "Smp.main"), musicalClock: nil,
                                              nominalRate: 48_000)
            #expect(throws: Refusal.invalidCounterSubject(key(.sampleClock, "Smp.main"))) {
                try InitialGenerationsV1Record.make(from: ledger)
            }
        }
    }
}
