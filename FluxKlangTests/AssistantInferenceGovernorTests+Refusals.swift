//
//  AssistantInferenceGovernorTests+Refusals.swift
//  FluxKlangTests
//
//  What `evaluate` refuses and in which order (invalid budget, then invalid load, then a request while active), that
//  a refusal leaves the whole governor value as it was, that hostile integers are refused without trapping, that
//  one script gives the same answers twice, and a scan of the three production files.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AssistantInferenceGovernorTests {
    static let invalidBudgets: [AssistantInferenceBudget] = [
        budget(resumeBelow: 0), budget(suspendAt: 101), budget(deferAt: 59, suspendAt: 80, resumeBelow: 60),
        budget(deferAt: 81, suspendAt: 80), budget(misses: 0), budget(misses: 1_001), budget(settle: -1),
        budget(settle: 65), budget(deferAt: -1, resumeBelow: -2)
    ]

    static let invalidLoads: [AssistantInferenceLoad] = [
        load(-1), load(101), load(10, misses: -1), load(10, misses: 1_001), load(Int.min), load(Int.max),
        load(10, misses: Int.min), load(10, misses: Int.max, context: .perform)
    ]

    // MARK: - Refusal order

    @Test
    func anInvalidBudgetIsReportedBeforeAnInvalidLoadWhenBothAreInvalid() {
        var governor = AssistantInferenceGovernor(budget: Self.budget(resumeBelow: 0))
        let before = governor
        let outcome = Self.step(&governor, Self.load(101), request: .interactive)
        let expected: Outcome = .refused(.invalidBudget)
        #expect(outcome == expected)
        #expect(governor == before)
    }

    @Test
    func anInvalidLoadIsReportedBeforeARequestWhileActiveForARunningAndASuspendedGovernor() {
        var running = Self.running(.interactive)
        var suspended = Self.suspended(.background, calm: 1)
        let runningBefore = running
        let suspendedBefore = suspended
        let runningOutcome = Self.step(&running, Self.load(101), request: .background)
        let suspendedOutcome = Self.step(&suspended, Self.load(10, misses: -1), request: .interactive)
        let expected: Outcome = .refused(.invalidLoad)
        #expect(runningOutcome == expected)
        #expect(suspendedOutcome == expected)
        #expect(running == runningBefore)
        #expect(suspended == suspendedBefore)
    }

    @Test
    func aRequestWhileActiveIsRefusedForARunningAndASuspendedGovernorWithAValidLoad() {
        var governors = [
            Self.running(.interactive), Self.running(.background),
            Self.suspended(.interactive, calm: 0), Self.suspended(.background, calm: 2)
        ]
        let before = governors
        var outcomes: [Outcome] = []
        for index in governors.indices {
            outcomes.append(Self.step(&governors[index], Self.load(0), request: .interactive))
            outcomes.append(Self.step(&governors[index], Self.load(0), request: .background))
        }
        let expected = Array(repeating: Outcome.refused(.requestWhileActive), count: 8)
        #expect(outcomes == expected)
        #expect(governors == before)
    }

    // MARK: - Refusals change nothing

    @Test
    func everyBudgetInTheInvalidListIsRefusedAsInvalidBudgetAndLeavesTheGovernorUnchanged() {
        var outcomes: [Outcome] = []
        var changed = 0
        for invalid in Self.invalidBudgets {
            var governor = AssistantInferenceGovernor(budget: invalid)
            let before = governor
            outcomes.append(Self.step(&governor, Self.load(0), request: .interactive))
            if governor != before { changed += 1 }
        }
        let expected = Array(repeating: Outcome.refused(.invalidBudget), count: Self.invalidBudgets.count)
        #expect(outcomes == expected)
        #expect(changed == 0)
    }

    @Test
    func theInvalidLoadsAreRefusedAsInvalidLoadInIdleRunningAndSuspendedAndLeaveTheGovernorUnchanged() {
        let starts = [
            AssistantInferenceGovernor(budget: Self.fixtureBudget), Self.running(.interactive),
            Self.running(.background), Self.suspended(.interactive, calm: 2), Self.suspended(.background, calm: 0)
        ]
        var outcomes: [Outcome] = []
        var changed = 0
        for start in starts {
            for invalid in Self.invalidLoads {
                var governor = start
                outcomes.append(Self.step(&governor, invalid))
                if governor != start { changed += 1 }
            }
        }
        let expected = Array(repeating: Outcome.refused(.invalidLoad), count: starts.count * Self.invalidLoads.count)
        #expect(outcomes == expected)
        #expect(changed == 0)
    }

    @Test
    func aBudgetOfHostileIntegersIsRefusedWithoutTrappingAndAnIdleRequestIsNotStarted() {
        let extremes = [Int.min, Int.max]
        var outcomes: [Outcome] = []
        var started = 0
        for extreme in extremes {
            let budgets = [
                Self.budget(deferAt: extreme), Self.budget(suspendAt: extreme), Self.budget(resumeBelow: extreme),
                Self.budget(misses: extreme), Self.budget(settle: extreme)
            ]
            for hostile in budgets {
                var governor = AssistantInferenceGovernor(budget: hostile)
                outcomes.append(Self.step(&governor, Self.load(0), request: .interactive))
                if governor.phase != .idle { started += 1 }
            }
        }
        let expected = Array(repeating: Outcome.refused(.invalidBudget), count: 10)
        #expect(outcomes == expected)
        #expect(started == 0)
    }

    // MARK: - Determinism

    @Test
    func twoGovernorsFedTheSameScriptHaveEqualDecisionsAndEqualPhasesAtEveryStep() {
        let script: [(AssistantInferenceLoad, AssistantInferenceRequestKind?)] = Self.determinismScript
        var first = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        var second = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        var firstOutcomes: [Outcome] = []
        var secondOutcomes: [Outcome] = []
        var phasesAgree = true
        for (reading, request) in script {
            firstOutcomes.append(Self.step(&first, reading, request: request))
            secondOutcomes.append(Self.step(&second, reading, request: request))
            if first.phase != second.phase { phasesAgree = false }
        }
        let sawStart = firstOutcomes.contains(.decided(.start(.interactive)))
        let sawResume = firstOutcomes.contains(.decided(.resume))
        #expect(firstOutcomes == secondOutcomes)
        #expect(phasesAgree)
        #expect(first == second)
        #expect(sawStart)
        #expect(sawResume)
    }

    static let determinismScript: [(AssistantInferenceLoad, AssistantInferenceRequestKind?)] = [
        (load(10), .interactive), (load(70), nil), (load(90), nil), (load(10), nil), (load(10), nil),
        (load(10), nil), (load(10, misses: 5), nil), (load(0), nil), (load(0), nil), (load(0), nil),
        (load(0), nil), (load(50, context: .perform), .background), (load(0), nil)
    ]

    // MARK: - Source scan

    static func containsBytes(_ needle: String, in haystack: String) -> Bool {
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard !wanted.isEmpty, wanted.count <= bytes.count else { return false }
        let last = bytes.count - wanted.count
        for start in 0...last {
            var matched = true
            for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Assistant/Budget",
            "../../Sources/FluxKlang/Shared/Assistant/Budget"
        ]
        let marker = "AssistantInferenceGovernor.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["import", " "].joined(), ["Da", "te("].joined(),
            ["Cl", "ock"].joined(), ["Ta", "sk"].joined(), ["Dispatch", "Queue"].joined(), ["Ti", "mer"].joined(),
            ["defa", "ult:"].joined(), ["arc4", "random"].joined()
        ]
    }

    /// Looks for each text of `forbiddenSourceWords()` in the three production files. The search is over the raw bytes,
    /// so a text in a comment is found too, and an API that the list does not name is not. It is skipped when the
    /// sources are not next to the tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the governor sources are not next to the tests"))
    func theThreeProductionFilesContainNoForbiddenText() throws {
        let directory = try #require(Self.sourceDirectory(), "the governor sources are not next to the tests")
        let names = [
            "AssistantInferenceBudget.swift", "AssistantInferenceDecision.swift", "AssistantInferenceGovernor.swift"
        ]
        var hits: [String] = []
        var scanned = 0
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            scanned += 1
            for word in Self.forbiddenSourceWords() where Self.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
        }
        #expect(scanned == 3)
        #expect(hits.isEmpty)
    }
}
