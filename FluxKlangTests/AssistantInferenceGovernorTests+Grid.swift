//
//  AssistantInferenceGovernorTests+Grid.swift
//  FluxKlangTests
//
//  Every combination of the sampled phases, contexts, requests, loads and miss counts, against an expected table
//  written by hand.
//  The table is not computed by the governor and not derived from its rules: one 32-character row per (phase,
//  context, request), one character per (load, misses) pair. A character is decoded only by a mapping to an
//  outcome and a phase that uses the row's own request kind and held kind.
//  Fixture budget: resume 40, defer 60, suspend 80, misses 5, settle 3.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AssistantInferenceGovernorTests {
    /// One expected outcome per character; the letters are only labels for the table below.
    enum GridCode: Character {
        case idle = "."
        case start = "S"
        case deferLoad = "l"
        case deferMisses = "m"
        case deferPerform = "p"
        case keepRunning = "c"
        case suspendLoad = "L"
        case suspendMisses = "M"
        case suspendPerform = "P"
        case stayedZero = "0"
        case stayedOne = "1"
        case resume = "r"
        case refused = "X"
    }

    struct GridRow {
        let phase: AssistantInferencePhase
        let context: AssistantInferenceContext
        let request: AssistantInferenceRequestKind?
        let codes: String
    }

    struct GridExpectation {
        let outcome: Outcome
        /// nil means the phase is unchanged.
        let phase: AssistantInferencePhase?
    }

    static let gridLoads = [0, 39, 40, 59, 60, 79, 80, 100]
    static let gridMisses = [0, 1, 4, 5]

    // Loads vary slowest, misses fastest: four characters per load, in the order of `gridLoads`.
    static let idleCells = "................................"
    static let startCells = "SSSmSSSmSSSmSSSmlllmlllmlllmlllm"
    static let performDeferCells = "pppppppppppppppppppppppppppppppp"
    static let runningCells = "cccMcccMcccMcccMcccMcccMLLLMLLLM"
    static let runningBackgroundPerformCells = "PPPMPPPMPPPMPPPMPPPMPPPMLLLMLLLM"
    static let suspendedFreshCells = "10001000000000000000000000000000"
    static let suspendedSettledCells = "r000r000000000000000000000000000"
    static let suspendedNeverCells = "00000000000000000000000000000000"
    static let refusedCells = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

    static let gridRows: [GridRow] = idleRows + runningRows + suspendedRows

    static let idleRows: [GridRow] = [
        row(.idle, .edit, nil, idleCells), row(.idle, .edit, .interactive, startCells),
        row(.idle, .edit, .background, startCells), row(.idle, .perform, nil, idleCells),
        row(.idle, .perform, .interactive, startCells), row(.idle, .perform, .background, performDeferCells)
    ]

    static let runningRows: [GridRow] = [
        row(.running(.interactive), .edit, nil, runningCells),
        row(.running(.interactive), .edit, .interactive, refusedCells),
        row(.running(.interactive), .edit, .background, refusedCells),
        row(.running(.interactive), .perform, nil, runningCells),
        row(.running(.interactive), .perform, .interactive, refusedCells),
        row(.running(.interactive), .perform, .background, refusedCells),
        row(.running(.background), .edit, nil, runningCells),
        row(.running(.background), .edit, .interactive, refusedCells),
        row(.running(.background), .edit, .background, refusedCells),
        row(.running(.background), .perform, nil, runningBackgroundPerformCells),
        row(.running(.background), .perform, .interactive, refusedCells),
        row(.running(.background), .perform, .background, refusedCells)
    ]

    static let suspendedRows: [GridRow] = interactiveSuspendedRows + backgroundSuspendedRows

    static let interactiveSuspendedRows: [GridRow] = [
        row(.suspended(.interactive, calmEvaluations: 0), .edit, nil, suspendedFreshCells),
        row(.suspended(.interactive, calmEvaluations: 0), .edit, .interactive, refusedCells),
        row(.suspended(.interactive, calmEvaluations: 0), .edit, .background, refusedCells),
        row(.suspended(.interactive, calmEvaluations: 0), .perform, nil, suspendedFreshCells),
        row(.suspended(.interactive, calmEvaluations: 0), .perform, .interactive, refusedCells),
        row(.suspended(.interactive, calmEvaluations: 0), .perform, .background, refusedCells),
        row(.suspended(.interactive, calmEvaluations: 2), .edit, nil, suspendedSettledCells),
        row(.suspended(.interactive, calmEvaluations: 2), .edit, .interactive, refusedCells),
        row(.suspended(.interactive, calmEvaluations: 2), .edit, .background, refusedCells),
        row(.suspended(.interactive, calmEvaluations: 2), .perform, nil, suspendedSettledCells),
        row(.suspended(.interactive, calmEvaluations: 2), .perform, .interactive, refusedCells),
        row(.suspended(.interactive, calmEvaluations: 2), .perform, .background, refusedCells)
    ]

    static let backgroundSuspendedRows: [GridRow] = [
        row(.suspended(.background, calmEvaluations: 0), .edit, nil, suspendedFreshCells),
        row(.suspended(.background, calmEvaluations: 0), .edit, .interactive, refusedCells),
        row(.suspended(.background, calmEvaluations: 0), .edit, .background, refusedCells),
        row(.suspended(.background, calmEvaluations: 0), .perform, nil, suspendedNeverCells),
        row(.suspended(.background, calmEvaluations: 0), .perform, .interactive, refusedCells),
        row(.suspended(.background, calmEvaluations: 0), .perform, .background, refusedCells),
        row(.suspended(.background, calmEvaluations: 2), .edit, nil, suspendedSettledCells),
        row(.suspended(.background, calmEvaluations: 2), .edit, .interactive, refusedCells),
        row(.suspended(.background, calmEvaluations: 2), .edit, .background, refusedCells),
        row(.suspended(.background, calmEvaluations: 2), .perform, nil, suspendedNeverCells),
        row(.suspended(.background, calmEvaluations: 2), .perform, .interactive, refusedCells),
        row(.suspended(.background, calmEvaluations: 2), .perform, .background, refusedCells)
    ]

    static func row(
        _ phase: AssistantInferencePhase,
        _ context: AssistantInferenceContext,
        _ request: AssistantInferenceRequestKind?,
        _ codes: String
    ) -> GridRow {
        GridRow(phase: phase, context: context, request: request, codes: codes)
    }

    static func governor(reaching phase: AssistantInferencePhase) -> AssistantInferenceGovernor {
        switch phase {
        case .idle: AssistantInferenceGovernor(budget: fixtureBudget)
        case .running(let kind): running(kind)
        case .suspended(let kind, let calm): suspended(kind, calm: calm)
        }
    }

    static func kind(of phase: AssistantInferencePhase) -> AssistantInferenceRequestKind? {
        switch phase {
        case .idle: nil
        case .running(let kind): kind
        case .suspended(let kind, _): kind
        }
    }

    /// The decoded meaning of one table character for one row.
    static func expectation(_ code: GridCode, row: GridRow) -> GridExpectation {
        let held = kind(of: row.phase) ?? .interactive
        let asked = row.request ?? .interactive
        switch code {
        case .idle, .start, .deferLoad, .deferMisses, .deferPerform, .keepRunning, .refused:
            return admission(code, asked)
        case .suspendLoad, .suspendMisses, .suspendPerform, .stayedZero, .stayedOne, .resume:
            return suspendedOutcome(code, held)
        }
    }

    private static func admission(_ code: GridCode, _ asked: AssistantInferenceRequestKind) -> GridExpectation {
        switch code {
        case .start: return GridExpectation(outcome: .decided(.start(asked)), phase: .running(asked))
        case .deferLoad: return GridExpectation(outcome: .decided(.deferStart(.loadHigh)), phase: nil)
        case .deferMisses: return GridExpectation(outcome: .decided(.deferStart(.deadlineMisses)), phase: nil)
        case .deferPerform: return GridExpectation(outcome: .decided(.deferStart(.performContext)), phase: nil)
        case .keepRunning: return GridExpectation(outcome: .decided(.continueRunning), phase: nil)
        case .refused: return GridExpectation(outcome: .refused(.requestWhileActive), phase: nil)
        case .idle, .suspendLoad, .suspendMisses, .suspendPerform, .stayedZero, .stayedOne, .resume:
            return GridExpectation(outcome: .decided(.idle), phase: nil)
        }
    }

    private static func suspendedOutcome(
        _ code: GridCode,
        _ held: AssistantInferenceRequestKind
    ) -> GridExpectation {
        switch code {
        case .suspendLoad: return suspension(.loadHigh, held)
        case .suspendMisses: return suspension(.deadlineMisses, held)
        case .suspendPerform: return suspension(.performContext, held)
        case .stayedZero: return stayed(0, held)
        case .stayedOne: return stayed(1, held)
        case .resume: return GridExpectation(outcome: .decided(.resume), phase: .running(held))
        case .idle, .start, .deferLoad, .deferMisses, .deferPerform, .keepRunning, .refused:
            return GridExpectation(outcome: .decided(.idle), phase: nil)
        }
    }

    private static func stayed(_ count: Int, _ held: AssistantInferenceRequestKind) -> GridExpectation {
        GridExpectation(outcome: .decided(.stayedSuspended(count)), phase: .suspended(held, calmEvaluations: count))
    }

    private static func suspension(
        _ reason: AssistantInferenceReason,
        _ held: AssistantInferenceRequestKind
    ) -> GridExpectation {
        GridExpectation(outcome: .decided(.suspend(reason)), phase: .suspended(held, calmEvaluations: 0))
    }

    /// nil when the cell matches the table, otherwise a description of the cell.
    static func mismatch(_ row: GridRow, percent: Int, misses: Int, code: GridCode) -> String? {
        var governor = Self.governor(reaching: row.phase)
        let before = governor
        guard before.phase == row.phase else { return "setup \(row.phase)" }
        let reading = load(percent, misses: misses, context: row.context)
        let outcome = step(&governor, reading, request: row.request)
        let expected = expectation(code, row: row)
        let expectedPhase = expected.phase ?? before.phase
        let sameOutcome = outcome == expected.outcome
        let samePhase = governor.phase == expectedPhase
        let sameBudget = governor.budget == before.budget
        let refusedOutcome: Outcome = .refused(.requestWhileActive)
        let refusalKeptValue = outcome != refusedOutcome || governor == before
        let allMatch = sameOutcome && samePhase && sameBudget && refusalKeptValue
        if allMatch { return nil }
        return "\(row.phase) \(row.context) \(String(describing: row.request)) load \(percent) misses \(misses)"
    }

    @Test
    func everyCellOfTheGridOf1344EvaluationsGivesTheOutcomeAndPhaseOfTheHandWrittenTable() throws {
        var mismatches: [String] = []
        var cells = 0
        for row in Self.gridRows {
            let codes = Array(row.codes)
            var index = 0
            for percent in Self.gridLoads {
                for misses in Self.gridMisses {
                    let character = try #require(codes.dropFirst(index).first)
                    let code = try #require(GridCode(rawValue: character))
                    index += 1
                    cells += 1
                    if let text = Self.mismatch(row, percent: percent, misses: misses, code: code) {
                        mismatches.append(text)
                    }
                }
            }
        }
        let none: [String] = []
        #expect(mismatches == none)
        #expect(cells == 1_344)
    }

    @Test
    func theHandWrittenTableHasFortyTwoRowsOfThirtyTwoCellsAndTheExpectedCountOfEachKindOfCell() {
        let rows = Self.gridRows
        let widths = Set(rows.map { $0.codes.count })
        let all = rows.map { $0.codes }.joined()
        let starts = all.filter { $0 == "S" }.count
        let resumes = all.filter { $0 == "r" }.count
        let refusals = all.filter { $0 == "X" }.count
        let rowCount = rows.count
        let expectedWidths: Set<Int> = [32]
        #expect(rowCount == 42)
        #expect(widths == expectedWidths)
        #expect(starts == 36)
        #expect(resumes == 6)
        #expect(refusals == 768)
    }
}
