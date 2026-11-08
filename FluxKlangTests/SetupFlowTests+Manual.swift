//
//  SetupFlowTests+Manual.swift
//  FluxKlangTests
//
//  Staying manual, suspending and reopening, what an ended flow refuses, and a scan of the three production files.
//  Stay manual is accepted from every running and suspended step under facts that fail gates, because it reads no fact.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SetupFlowTests {
    /// Facts that fail a gate: no present device, denied access, and 1_024 lost devices with none present.
    static func hostileFacts() throws(SetupFlowRefusal) -> [SetupFlowFacts] {
        [
            try facts(present: 0), try facts(access: .denied), try facts(present: 0, lost: 1_024)
        ]
    }

    /// One flow of each ending, both built under good facts.
    static func endedFlows() throws(SetupFlowRefusal) -> [SetupFlowState] {
        let good = try facts()
        let manual = try SetupFlowReducer.reduce(SetupFlowState.begin(), .stayManual, facts: good)
        let decided = try running(at: .decide, facts: good)
        let applied = try SetupFlowReducer.reduce(decided, .requestApply, facts: good)
        return [manual, applied]
    }

    // MARK: - Stay manual

    @Test
    func setupFlowStayManualEndsARunningFlowAtEveryStepUnderHostileFacts() throws {
        let good = try Self.facts()
        let hostile = try Self.hostileFacts()
        let expected: SetupFlowPhase? = .ended(.manual)
        for step in Self.steps {
            let state = try Self.running(at: step, facts: good)
            for facts in hostile {
                let after = Self.phase(state, .stayManual, facts)
                #expect(after == expected)
            }
        }
    }

    @Test
    func setupFlowStayManualEndsASuspendedFlowAtEveryStepUnderHostileFacts() throws {
        let hostile = try Self.hostileFacts()
        let expected: SetupFlowPhase? = .ended(.manual)
        for step in Self.steps {
            let state = try Self.suspended(at: step)
            for facts in hostile {
                let after = Self.phase(state, .stayManual, facts)
                #expect(after == expected)
            }
        }
    }

    @Test
    func setupFlowStayManualKeepsThePickAndBothAcknowledgements() throws {
        let offered = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let decided = try Self.running(at: .decide, facts: offered, pick: Self.rigB)
        let ended = try SetupFlowReducer.reduce(decided, .stayManual, facts: offered)
        #expect(ended.pickedRig == Self.rigB)
        #expect(ended.homeSeenUnder == decided.homeSeenUnder)
        #expect(ended.runtimeMapSeenUnder == decided.runtimeMapSeenUnder)
        #expect(ended.homeSeenUnder != nil)
    }

    // MARK: - Cancel and reopen

    @Test
    func setupFlowCancelSuspendsARunningFlowAtItsStepAndKeepsEveryDecision() throws {
        let offered = try Self.facts(rigs: [Self.rigA, Self.rigB])
        for step in Self.steps {
            let state = try Self.running(at: step, facts: offered, pick: Self.rigA)
            let cancelled = try SetupFlowReducer.reduce(state, .cancel, facts: offered)
            let expectedPhase: SetupFlowPhase = .suspended(step)
            #expect(cancelled.phase == expectedPhase)
            #expect(cancelled.pickedRig == Self.rigA)
            #expect(cancelled.homeSeenUnder == state.homeSeenUnder)
            #expect(cancelled.runtimeMapSeenUnder == state.runtimeMapSeenUnder)
        }
        let atReview = try Self.running(at: .review, facts: offered, pick: Self.rigA)
        let homeDone = try SetupFlowReducer.reduce(atReview, .acknowledge(.home), facts: offered)
        let bothDone = try SetupFlowReducer.reduce(homeDone, .acknowledge(.runtimeMap), facts: offered)
        let suspendedBoth = try SetupFlowReducer.reduce(bothDone, .cancel, facts: offered)
        #expect(suspendedBoth.homeSeenUnder == offered)
        #expect(suspendedBoth.runtimeMapSeenUnder == offered)
    }

    @Test
    func setupFlowReopenGivesBackTheRunningFlowThatWasCancelledAtEveryStep() throws {
        let offered = try Self.facts(rigs: [Self.rigA, Self.rigB])
        for step in Self.steps {
            let state = try Self.running(at: step, facts: offered, pick: Self.rigB)
            let cancelled = try SetupFlowReducer.reduce(state, .cancel, facts: offered)
            let reopened = try SetupFlowReducer.reduce(cancelled, .reopen, facts: offered)
            #expect(reopened == state)
        }
    }

    @Test
    func setupFlowReopenWhileRunningIsRefusedAsNotSuspendedAtEveryStep() throws {
        let good = try Self.facts()
        let expected: SetupFlowRefusal? = .notSuspended
        for step in Self.steps {
            let state = try Self.running(at: step, facts: good)
            let refusal = Self.refusal(state, .reopen, good)
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowASuspendedFlowRefusesTheSixOtherEventsAsSuspendedAtEveryStep() throws {
        let good = try Self.facts()
        let others: [SetupFlowEvent] = [
            .next, .back, .chooseRig(Self.rigA), .acknowledge(.home), .requestApply, .cancel
        ]
        let expected: SetupFlowRefusal? = .suspended
        for step in Self.steps {
            let state = try Self.suspended(at: step)
            for event in others {
                let refusal = Self.refusal(state, event, good)
                #expect(refusal == expected)
            }
        }
    }

    // MARK: - Ended

    @Test
    func setupFlowAnEndedFlowRefusesAllEightEventsAsFlowEndedAfterEitherEnding() throws {
        let good = try Self.facts()
        let events: [SetupFlowEvent] = [
            .next, .back, .chooseRig(Self.rigA), .acknowledge(.runtimeMap), .requestApply, .stayManual, .cancel, .reopen
        ]
        let flows = try Self.endedFlows()
        #expect(flows.count == 2)
        let expected: SetupFlowRefusal? = .flowEnded
        for flow in flows {
            for event in events {
                let refusal = Self.refusal(flow, event, good)
                #expect(refusal == expected)
            }
        }
    }

    // MARK: - Source scan

    static func startsAt(_ wanted: [UInt8], in bytes: [UInt8], at start: Int) -> Bool {
        guard start + wanted.count <= bytes.count else { return false }
        for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
            return false
        }
        return true
    }

    static func containsBytes(_ needle: String, in haystack: String) -> Bool {
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard !wanted.isEmpty, wanted.count <= bytes.count else { return false }
        for start in 0...(bytes.count - wanted.count) where startsAt(wanted, in: bytes, at: start) {
            return true
        }
        return false
    }

    /// True when the text holds `static func ` followed by a symbol byte. Other operator forms (a global or instance
    /// operator function, a `prefix` or `postfix` one) are not looked for.
    static func declaresAStaticOperatorFunction(_ text: String) -> Bool {
        let wanted = Array(["static", " func", " "].joined().utf8)
        let bytes = Array(text.utf8)
        let symbols = Array("=<>+-*/!&|%^~".utf8)
        guard wanted.count < bytes.count else { return false }
        for start in 0...(bytes.count - wanted.count - 1) where startsAt(wanted, in: bytes, at: start) {
            let following = bytes[start + wanted.count]
            if symbols.contains(following) { return true }
        }
        return false
    }

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    static func forbiddenSourceWords() -> [String] {
        [
            ["im", "port "].joined(), ["Da", "te"].joined(), ["Dispatch", "Queue"].joined(),
            ["Swift", "UI"].joined(), ["Ta", "sk"].joined(), ["Cl", "ock"].joined(), ["Dou", "ble"].joined(),
            ["Flo", "at"].joined(), ["defa", "ult:"].joined(), ["mutat", "ing"].joined(),
            ["static", " var"].joined(), ["nonisolated", "(unsafe)"].joined(), ["try", "!"].joined()
        ]
    }

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Rig/Setup",
            "../../Sources/FluxKlang/Shared/Rig/Setup"
        ]
        let marker = "SetupFlowReducer.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    @Test
    func setupFlowTheSourceScanFindsAPlantedWordAndAPlantedStaticOperatorFunctionButNotAPlainStaticFunction() {
        let word = Self.forbiddenSourceWords().first ?? ""
        let planted = "a " + word + "b"
        let foundWord = Self.containsBytes(word, in: planted)
        #expect(foundWord)
        let missingWord = Self.containsBytes(word, in: "nothing to see")
        #expect(!missingWord)
        let plantedOperator = ["static", " func", " == (left: Int) -> Bool"].joined()
        let foundOperator = Self.declaresAStaticOperatorFunction(plantedOperator)
        #expect(foundOperator)
        let plainFunction = ["static", " func", " begin() -> Self"].joined()
        let foundPlain = Self.declaresAStaticOperatorFunction(plainFunction)
        #expect(!foundPlain)
    }

    /// Looks for each text of `forbiddenSourceWords()` and for a static operator function in the three
    /// production files. The search is over the raw bytes, so a text in a comment is found too, and an API that the
    /// list does not name is not. It is skipped when the sources are not next to the tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the setup flow sources are not next to the tests"))
    func setupFlowTheThreeProductionFilesContainNoForbiddenTextAndNoStaticOperatorFunction() throws {
        let directory = try #require(Self.sourceDirectory(), "the setup flow sources are not next to the tests")
        let names = ["SetupFlowFacts.swift", "SetupFlowRefusal.swift", "SetupFlowReducer.swift"]
        var hits: [String] = []
        var scanned = 0
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            scanned += 1
            for word in Self.forbiddenSourceWords() where Self.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
            if Self.declaresAStaticOperatorFunction(text) { hits.append("\(name): static operator function") }
        }
        #expect(scanned == 3)
        #expect(hits.isEmpty)
    }
}
