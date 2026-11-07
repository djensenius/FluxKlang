import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginEditorStateTests {
    private static let order = ["wing.zeta", "Alpha", "alpha", "mid.2", "mid.10", "beta"]

    @Test func everyEditorFailureKeepsEveryControlInTheCallersOrder() throws {
        let controls = try Self.controls(Self.order)
        let ids = try Self.order.map { try Self.controlID($0) }
        for failure in PluginEditorFailure.allCases {
            let decision = EditorFallbackPolicy.decide(failure: failure, controls: controls, attempt: .first)
            switch decision {
            case .useGenericControls(let preserved), .useGenericControlsAndOfferRetry(let preserved, _):
                #expect(preserved == ids)
            }
        }
        #expect(PluginEditorFailure.allCases.count == 4)
    }

    @Test func onlyACrashAndATimeoutOfferARetryWithTheNextAttempt() throws {
        let controls = try Self.controls(["a", "b"])
        let ids = controls.ids
        let second = try EditorAttempt(number: 2)
        #expect(EditorFallbackPolicy.decide(failure: .crashed, controls: controls, attempt: .first)
            == .useGenericControlsAndOfferRetry(preserving: ids, next: second))
        #expect(EditorFallbackPolicy.decide(failure: .timedOut, controls: controls, attempt: .first)
            == .useGenericControlsAndOfferRetry(preserving: ids, next: second))
        #expect(EditorFallbackPolicy.decide(failure: .unavailable, controls: controls, attempt: .first)
            == .useGenericControls(preserving: ids))
        #expect(EditorFallbackPolicy.decide(failure: .containmentRefused, controls: controls, attempt: .first)
            == .useGenericControls(preserving: ids))
    }

    @Test func theRetryLimitIsThreeAttemptsAndTheFourthIsRefused() throws {
        let controls = try Self.controls(["a"])
        let ids = controls.ids
        let second = try EditorAttempt(number: 2)
        let third = try EditorAttempt(number: 3)
        #expect(EditorFallbackPolicy.decide(failure: .crashed, controls: controls, attempt: second)
            == .useGenericControlsAndOfferRetry(preserving: ids, next: third))
        #expect(EditorFallbackPolicy.decide(failure: .crashed, controls: controls, attempt: third)
            == .useGenericControls(preserving: ids))
        #expect(EditorFallbackPolicy.decide(failure: .timedOut, controls: controls, attempt: third)
            == .useGenericControls(preserving: ids))
        #expect(throws: EditorFallbackError.attemptOutOfRange(4)) { try EditorAttempt(number: 4) }
        #expect(EditorFallbackPolicy.maximumAttempts == 3)
    }

    @Test func anAttemptBelowOneIsRefusedAndTheFirstAttemptIsNumberOne() throws {
        for bad in [0, -1, Int.min, Int.max] {
            #expect(throws: EditorFallbackError.attemptOutOfRange(bad)) { try EditorAttempt(number: bad) }
        }
        #expect(EditorAttempt.first.number == 1)
        #expect(try EditorAttempt(number: 1) == .first)
        #expect(try EditorAttempt(number: 3).number == 3)
    }

    @Test func theSameAttemptAlwaysGivesTheSameDecisionBecauseThePolicyNeverRetriesByItself() throws {
        let controls = try Self.controls(["a", "b", "c"])
        let before = controls
        let first = EditorFallbackPolicy.decide(failure: .crashed, controls: controls, attempt: .first)
        let again = EditorFallbackPolicy.decide(failure: .crashed, controls: controls, attempt: .first)
        #expect(first == again)
        #expect(controls == before)
        guard case .useGenericControlsAndOfferRetry(_, let next) = first else {
            Issue.record("a crash on the first attempt must offer a retry")
            return
        }
        #expect(next.number == 2)
        #expect(EditorAttempt.first.number == 1)
    }

    @Test func aControlSetOf4096IdsIsAcceptedAndOneMoreIsRefused() throws {
        let ids = try (0..<4_097).map { try Self.controlID("c.\($0)") }
        let accepted = try EditorControlSet(ids: Array(ids.prefix(4_096)))
        #expect(accepted.ids.count == 4_096 && accepted.ids.first == ids[0] && accepted.ids.last == ids[4_095])
        #expect(throws: EditorFallbackError.tooManyControls(count: 4_097, limit: 4_096)) {
            try EditorControlSet(ids: ids)
        }
        let repeated = Array(repeating: ids[0], count: 4_097)
        #expect(throws: EditorFallbackError.tooManyControls(count: 4_097, limit: 4_096)) {
            try EditorControlSet(ids: repeated)
        }
    }

    @Test func aDuplicateControlIsRefusedAndTheFirstRepeatInInputOrderIsNamed() throws {
        #expect(throws: EditorFallbackError.duplicateControl(try Self.controlID("a"))) {
            try Self.controls(["a", "b", "a", "b"])
        }
        #expect(throws: EditorFallbackError.duplicateControl(try Self.controlID("b"))) {
            try Self.controls(["b", "a", "b", "a"])
        }
        #expect(try Self.controls(["a", "A"]).ids.count == 2)
    }

    @Test func aPluginWithoutControlsFallsBackWithAnEmptyPreservedList() throws {
        let empty = try Self.controls([])
        #expect(empty.ids.isEmpty)
        #expect(EditorFallbackPolicy.decide(failure: .unavailable, controls: empty, attempt: .first)
            == .useGenericControls(preserving: []))
        #expect(EditorFallbackPolicy.maximumControls == 4_096)
    }
}
