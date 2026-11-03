import XCTest

/// Pure return/interruption simulations. No SDK owner, application, reader or attachment calls.
@MainActor
final class UIAuditCaptureSessionTests: XCTestCase {
    private typealias State = UIAuditCaptureState
    private typealias Observation = UIAuditSnapshotReader.Observation
    private typealias Interruption = (State.Phase, State.Boundary) -> Bool
    private struct Scenario {
        let state: State
        let launch: State.Launch
        let token: State.Token
        let old: State.Launch
    }
    private let runID = "40a478e3-b71d-4849-a918-02247e7061d8"
    private let processID = "61858439-82bc-46d0-8c99-22133d325b84"

    private var environment: [String: String] {
        ["FLUXKLANG_AUDIT_RUN_ID": runID, "FLUXKLANG_ISOLATED_TESTING": "1",
         "FLUXKLANG_QUALIFY_APPLE_ROUTING": "0", "FLUXKLANG_RUN_APPLE_MODEL_TESTS": "0"]
    }

    private func receipt(sequence: UInt64 = 1, pid: Int = 42, counter: UInt64 = 0) -> String {
        let rows = (0..<14).map {
            "{\"operation\":\($0),\"factoryEvaluated\":\(counter),\"apiEntered\":0}"
        }.joined(separator: ",")
        return """
        {"schemaVersion":1,"runID":"\(runID)","processInstanceID":"\(processID)",
        "pid":\(pid),"sequence":\(sequence),"counts":[\(rows)]}
        """
    }

    private var observations: [Observation] {
        [.missingValue, .receipt(receipt()), .receipt(receipt()), .receipt(receipt(sequence: 2))]
    }

    private func admission(_ state: State) throws -> (State.Launch, State.Token) {
        guard case .admitted(let launch, let token) = state.open(
            runner: environment, app: environment, arguments: ["-ui-testing"]
        ) else { throw FixtureFailure.admission }
        return (launch, token)
    }

    private func opened(_ state: State) throws -> State.Launch {
        let (launch, token) = try admission(state)
        XCTAssertTrue(drain(state, token))
        XCTAssertTrue(state.settle(token))
        return launch
    }

    private func admitted(_ beginning: State.Beginning) throws -> State.Token {
        guard case .admitted(let token) = beginning else { throw FixtureFailure.admission }
        return token
    }

    /// Test-only simulation of individual boundaries, not a runtime transport or acknowledgement.
    @discardableResult
    private func drain(
        _ state: State, _ token: State.Token, values: [Observation]? = nil,
        interrupt: Interruption? = nil
    ) -> Bool {
        let values = values ?? observations
        for _ in 0..<32 {
            let phase = token.phase
            if phase == .done { return true }
            if case .read(let position) = phase {
                guard state.start(token, phase: phase, boundary: .read) else { return false }
                if interrupt?(phase, .read) == true { return false }
                guard state.returnedObservation(values[position.rawValue], token: token, position: position) else {
                    return false
                }
            } else if case .command = phase {
                guard commandReturn(state, token, interrupt: interrupt) else { return false }
            } else {
                guard emit(state, token, interrupt: interrupt) else { return false }
            }
        }
        XCTFail("Fixed phase bound exceeded")
        return false
    }

    private func commandReturn(_ state: State, _ token: State.Token, interrupt: Interruption?) -> Bool {
        let phase = token.phase
        guard state.start(token, phase: phase, boundary: .command),
              interrupt?(phase, .command) != true else { return false }
        return state.returned(token, phase: phase, boundary: .command)
    }

    private func emit(_ state: State, _ token: State.Token, interrupt: Interruption?) -> Bool {
        let phase = token.phase
        guard let evidence = state.evidence(token, phase: phase) else { return false }
        XCTAssertNil(state.evidence(token, phase: phase)) // Position consumed before constructor.
        XCTAssertFalse(state.start(token, phase: .done, boundary: .construct))
        if case .observation(let position, let raw) = phase {
            let value = token.launch?.observations[position.rawValue].value
            if raw, case .receipt(let original) = value {
                XCTAssertEqual(Array(evidence.text.utf8), Array(original.utf8))
            }
            if value == nil { XCTAssertTrue(evidence.text.hasPrefix("notRead;")) }
        }
        for boundary: State.Boundary in [.construct, .name, .lifetime, .add] {
            guard state.start(token, phase: phase, boundary: boundary) else { return false }
            XCTAssertFalse(state.returned(token, phase: .done, boundary: boundary))
            if interrupt?(phase, boundary) == true { return false }
            guard state.returned(token, phase: phase, boundary: boundary) else { return false }
        }
        return true
    }

    private func sample(_ state: State, _ launch: State.Launch, _ slot: State.Slot,
                        values: [Observation]? = nil) throws {
        let token = try admitted(state.begin(launch, slot: slot))
        XCTAssertTrue(drain(state, token, values: values))
        XCTAssertTrue(state.settle(token))
    }

    private func close(_ state: State, _ launch: State.Launch) throws {
        let token = try admitted(state.finish(launch))
        XCTAssertNotEqual(state.outcome, .completedClean)
        XCTAssertNil(launch.terminal)
        XCTAssertTrue(drain(state, token))
        XCTAssertTrue(state.settle(token))
    }

    func testTypedBaselinesAndPostsUseOnlyPermittedValidatorInputs() throws {
        let kinds: [Observation] = [.snapshotUnavailable, .observationIncomplete, .absent, .ambiguous,
                                    .missingValue, .nonStringValue, .receipt(""), .receipt(receipt())]
        for value in kinds {
            let state = State()
            let launch = try opened(state)
            var values = observations
            values[0] = value
            try sample(state, launch, .entry, values: values)
            XCTAssertNil(launch.observations[0].validation)
            XCTAssertEqual(launch.sampled.contains(.entry), value == .missingValue)
            XCTAssertEqual(launch.records[.command(.entry)] != nil, value == .missingValue)
        }
        for value in kinds {
            let state = State()
            let launch = try opened(state)
            var values = observations
            values[1] = value
            let token = try admitted(state.begin(launch, slot: .entry))
            XCTAssertTrue(drain(state, token, values: values))
            XCTAssertFalse(state.returnedObservation(value, token: token, position: .entryPost))
            XCTAssertTrue(state.settle(token))
            let validation = launch.observations[1].validation
            switch value {
            case .receipt(let raw):
                XCTAssertEqual(validation?.rawReceipt, raw)
                XCTAssertEqual(validation?.outcome, raw.isEmpty ? .failed : .clean)
            case .missingValue:
                XCTAssertNotNil(validation)
                XCTAssertNil(validation?.rawReceipt)
                XCTAssertEqual(validation?.diagnostics, [.missingReceipt])
            default: XCTAssertNil(validation)
            }
            XCTAssertEqual(launch.sampled.contains(.entry), value == .receipt(receipt()))
        }
        for value in kinds {
            let state = State()
            let launch = try opened(state)
            try sample(state, launch, .entry)
            var values = observations
            values[2] = value
            try sample(state, launch, .exit, values: values)
            XCTAssertNil(launch.observations[2].validation)
            XCTAssertEqual(launch.records[.command(.exit)] != nil, value == .receipt(receipt()))
        }
    }

    func testOriginalReceiptBytesAndSequenceIdentityCounterFailuresAreSticky() throws {
        // Valid receipt grammar has ASCII-only fields. Exercise its consumed comparison
        // directly for canonical Unicode equivalence, plus valid JSON whitespace end-to-end.
        let original = receipt()
        let altered = original + "\n"
        let canonicallyEqual = ("é", "e\u{301}")
        XCTAssertEqual(canonicallyEqual.0, canonicallyEqual.1)
        XCTAssertFalse(State.receiptsMatch(canonicallyEqual.0, canonicallyEqual.1))
        XCTAssertTrue(State.receiptsMatch(canonicallyEqual.1, canonicallyEqual.1))
        let refusals = [receipt(sequence: 1), receipt(sequence: 2, pid: 43),
                        receipt(sequence: 2, counter: 1),
                        receipt(sequence: 2).replacingOccurrences(of: processID, with: runID),
                        receipt(sequence: 2).replacingOccurrences(of: runID, with: processID)]
        for exitReceipt in refusals {
            let state = State()
            let launch = try opened(state)
            try sample(state, launch, .entry)
            var values = observations
            values[3] = .receipt(exitReceipt)
            try sample(state, launch, .exit, values: values)
            XCTAssertEqual(launch.observations[3].validation?.outcome, .failed)
            XCTAssertEqual(state.outcome, .failed)
            try close(state, launch)
            XCTAssertEqual(launch.terminal, .failed)
        }
        let state = State()
        let launch = try opened(state)
        try sample(state, launch, .entry)
        var values = observations
        values[2] = .receipt(altered)
        try sample(state, launch, .exit, values: values)
        XCTAssertNil(launch.records[.command(.exit)])
        XCTAssertEqual(Array(launch.observations[1].validation?.rawReceipt?.utf8 ?? "".utf8), Array(original.utf8))
    }

    func testPostCloseEvidenceIsFixedAndAlreadyFailedRunStillInvalidatesNewTokens() throws {
        for nested in [false, true] {
            let state = State()
            let old = try opened(state)
            try sample(state, old, .entry)
            try sample(state, old, .exit)
            try close(state, old)
            guard case .refused(.closed, let rejection) = state.begin(old, slot: .exit) else {
                throw FixtureFailure.admission
            }
            let token = try XCTUnwrap(rejection)
            XCTAssertTrue(drain(state, token))
            XCTAssertTrue(state.settle(token))
            guard case .refused(.closed, nil) = state.begin(old, slot: .entry) else {
                throw FixtureFailure.admission
            }
            let later = try opened(state)
            let current = try admitted(state.begin(later, slot: .entry))
            XCTAssertTrue(current.valid)
            if nested {
                guard case .refused(.closed, nil) = state.begin(old, slot: .exit) else {
                    throw FixtureFailure.admission
                }
                XCTAssertFalse(current.valid)
            } else {
                XCTAssertTrue(drain(state, current))
            }
            _ = state.settle(current)
            try close(state, later)
            XCTAssertEqual(later.terminal, .failed)
            XCTAssertEqual(old.terminal, .completedClean)
            XCTAssertEqual(old.records[.misuse], .attempted)
            XCTAssertEqual(state.outcome, .failed)
        }
    }

    func testZeroOneTwoSamplesFinishProvisionallyAndAggregateAcrossLaunches() throws {
        for count in 0...2 {
            let state = State()
            let launch = try opened(state)
            if count > 0 { try sample(state, launch, .entry) }
            if count > 1 { try sample(state, launch, .exit) }
            try close(state, launch)
            let expected: State.Outcome = count == 2 ? .completedClean : .incomplete
            XCTAssertEqual(state.outcome, expected)
            let records = launch.records
            guard case .closed(let cached) = state.finish(launch) else { throw FixtureFailure.admission }
            XCTAssertEqual(cached, expected)
            XCTAssertEqual(launch.records, records)
            let later = try opened(state)
            try sample(state, later, .entry)
            try sample(state, later, .exit)
            try close(state, later)
            XCTAssertEqual(state.outcome, expected)
        }
    }

    func testOrderingDuplicateSubmissionAndOldSessionMisuse() throws {
        let state = State()
        let launch = try opened(state)
        let token = try admitted(state.begin(launch, slot: .entry))
        XCTAssertTrue(drain(state, token))
        XCTAssertFalse(state.returnedObservation(.receipt(receipt()), token: token, position: .entryPost))
        XCTAssertTrue(state.settle(token))
        try sample(state, launch, .exit)
        XCTAssertEqual(launch.observations[3].validation?.diagnostics, [])
        try close(state, launch)
        let later = try opened(state)
        let current = try admitted(state.begin(later, slot: .entry))
        guard case .closed(.completedClean) = state.finish(launch) else { throw FixtureFailure.admission }
        XCTAssertTrue(current.valid)
        guard case .refused(.closed, nil) = state.begin(launch, slot: .entry) else {
            throw FixtureFailure.admission
        }
        XCTAssertFalse(current.valid)
        XCTAssertEqual(launch.records[.misuse], .suppressed)
        XCTAssertEqual(launch.terminal, .completedClean)
        XCTAssertEqual(state.outcome, .failed)
        XCTAssertFalse(state.settle(token)) // Old identity cannot clear new ownership.
        XCTAssertTrue(state.busy === current)
        XCTAssertFalse(state.settle(current))
        XCTAssertTrue(state.active === later)
        let ordered = State()
        let other = try opened(ordered)
        guard case .refused(.wrongOrder, let rejection) = ordered.begin(other, slot: .exit) else {
            throw FixtureFailure.admission
        }
        let rejected = try XCTUnwrap(rejection)
        XCTAssertTrue(drain(ordered, rejected))
        XCTAssertTrue(ordered.settle(rejected))
        try sample(ordered, other, .entry)
        guard case .refused(.wrongOrder, _) = ordered.begin(other, slot: .entry) else {
            throw FixtureFailure.admission
        }
    }

    func testPreflightRefusalCleanupOverlapPrecedenceAndCheckedExhaustion() throws {
        let state = State(lastOrdinal: UInt64.max - 1)
        guard case .refused(.preflight(.missingRunnerRunID), let refusal) = state.open(
            runner: [:], app: [:], arguments: []
        ) else { throw FixtureFailure.admission }
        XCTAssertNil(state.pendingOrdinal)
        let rejected = try XCTUnwrap(refusal)
        XCTAssertTrue(drain(state, rejected))
        XCTAssertTrue(state.settle(rejected))
        for _ in 0..<3 {
            guard case .refused(.ordinalExhaustion, let token) = state.open(
                runner: [:], app: [:], arguments: []
            ) else { throw FixtureFailure.admission }
            if let token {
                XCTAssertTrue(drain(state, token))
                XCTAssertTrue(state.settle(token))
            }
        }
        XCTAssertEqual(state.lastOrdinal, UInt64.max)
        XCTAssertEqual(state.runRecords.count, 2)
        let pending = State(lastOrdinal: UInt64.max - 1)
        let (_, token) = try admission(pending)
        for _ in 0..<3 {
            guard case .refused(.overlap, nil) = pending.open(runner: [:], app: [:], arguments: []) else {
                throw FixtureFailure.admission
            }
        }
        XCTAssertFalse(token.valid)
        XCTAssertFalse(pending.settle(token))
        XCTAssertEqual(pending.pendingOrdinal, UInt64.max)
        XCTAssertEqual(pending.runRecords[.overlap], .suppressed)
        XCTAssertEqual(pending.outcome, .failed)
    }

    func testSuppliedMetadataUsesUnchangedPreflightRefusalOrder() throws {
        var runner = environment
        let state = State()
        let flags: [UIAuditRunPreflight.Flag] = [.isolatedTesting, .qualifyAppleRouting, .runAppleModelTests]
        for flag in flags {
            runner[flag.rawValue] = "wrong"
            guard case .refused(.preflight(.invalidFlag(.runner, flag)), let token) = state.open(
                runner: runner, app: [:], arguments: []
            ) else { throw FixtureFailure.admission }
            if let token {
                XCTAssertTrue(drain(state, token))
                XCTAssertTrue(state.settle(token))
            }
            XCTAssertNil(state.pendingOrdinal)
            runner[flag.rawValue] = environment[flag.rawValue]
        }
        XCTAssertEqual(state.lastOrdinal, 3)
        XCTAssertEqual(state.runRecords.count, 1)
        let launch = try opened(state)
        XCTAssertEqual(launch.configuration.runID.uuidString.lowercased(), runID)
        XCTAssertEqual(launch.configuration.appEnvironment, environment)
        XCTAssertEqual(launch.configuration.appArguments, ["-ui-testing"])
    }

    func testEveryEffectBoundaryNonreturnAndReentrantMutationSuppressLaterPermits() throws {
        // Creation, both slots, finishes, structural/raw refusal, and run rejection.
        for scenario in 0..<9 {
            let reference = try scenarioState(scenario)
            var count = 0
            XCTAssertTrue(drain(reference.state, reference.token, values: scenarioValues(scenario)) { _, _ in
                count += 1
                return false
            })
            for index in 0..<count {
                for mutation in 0..<6 {
                    let fixture = try scenarioState(scenario)
                    let state = fixture.state
                    let launch = fixture.launch
                    let current = fixture.token
                    var boundaryIndex = 0
                    var stopped: (State.Phase, State.Boundary)?
                    XCTAssertFalse(drain(state, current, values: scenarioValues(scenario)) { phase, boundary in
                        defer { boundaryIndex += 1 }
                        guard boundaryIndex == index else { return false }
                        stopped = (phase, boundary)
                        if mutation != 0 {
                            self.mutate(state, mutation == 5 ? fixture.old : launch, kind: mutation)
                        }
                        return true // Simulate a call not yet returned.
                    })
                    let (phase, boundary) = try XCTUnwrap(stopped)
                    XCTAssertFalse(state.settle(current))
                    XCTAssertTrue(state.busy === current)
                    XCTAssertNil(launch.terminal)
                    XCTAssertNotEqual(state.outcome, .completedClean)
                    guard mutation != 0 else { continue } // Nonreturn stays outstanding.
                    XCTAssertFalse(current.valid)
                    XCTAssertFalse(state.start(current, phase: phase, boundary: boundary))
                    if case .read(let position) = phase {
                        XCTAssertFalse(state.returnedObservation(
                            scenarioValues(scenario)[position.rawValue], token: current, position: position
                        ))
                        XCTAssertNotNil(launch.observations[position.rawValue].value)
                        XCTAssertNil(launch.observations[position.rawValue].validation)
                    } else {
                        XCTAssertFalse(state.returned(current, phase: phase, boundary: boundary))
                    }
                    XCTAssertFalse(state.evidence(current, phase: phase) != nil)
                    XCTAssertFalse(state.settle(current))
                    XCTAssertNil(state.busy)
                    XCTAssertEqual(state.outcome, .failed)
                    if [3, 4, 8].contains(scenario) { XCTAssertEqual(launch.terminal, .failed) }
                    if scenario == 0 { XCTAssertEqual(state.pendingOrdinal, launch.ordinal) }
                }
            }
        }
    }
}

extension UIAuditCaptureSessionTests {
    private func scenarioValues(_ scenario: Int) -> [Observation] {
        if scenario == 5 { return [.absent, .missingValue, .missingValue, .missingValue] }
        if scenario == 7 { return [.receipt(receipt()), .missingValue, .missingValue, .missingValue] }
        return observations
    }

    private func scenarioState(_ scenario: Int) throws -> Scenario {
        let state = State()
        let old = try opened(state)
        try sample(state, old, .entry)
        try sample(state, old, .exit)
        try close(state, old)
        if scenario == 0 {
            let (launch, token) = try admission(state)
            return Scenario(state: state, launch: launch, token: token, old: old)
        }
        let launch = try opened(state)
        if scenario == 2 || scenario == 4 { try sample(state, launch, .entry) }
        if scenario == 4 { try sample(state, launch, .exit) }
        if scenario == 6 {
            guard case .refused(.overlap, let token) = state.open(runner: [:], app: [:], arguments: []) else {
                throw FixtureFailure.admission
            }
            return Scenario(state: state, launch: launch, token: try XCTUnwrap(token), old: old)
        }
        if scenario == 8 {
            let token = try admitted(state.begin(launch, slot: .entry))
            XCTAssertFalse(drain(state, token) { phase, boundary in
                guard phase == .observation(.entryPost, raw: false), boundary == .construct else { return false }
                self.mutate(state, launch, kind: 1)
                XCTAssertFalse(state.returned(token, phase: phase, boundary: boundary))
                return true
            })
            XCTAssertFalse(state.settle(token))
        }
        let operation = [3, 4, 8].contains(scenario)
            ? state.finish(launch) : state.begin(launch, slot: scenario == 2 ? .exit : .entry)
        return Scenario(state: state, launch: launch, token: try admitted(operation), old: old)
    }

    private func mutate(_ state: State, _ launch: State.Launch, kind: Int) {
        switch kind {
        case 1:
            guard case .refused(.overlap, nil) = state.open(runner: [:], app: [:], arguments: []) else {
                return XCTFail("Nested open emitted")
            }
        case 2:
            guard case .refused(_, nil) = state.begin(launch, slot: .entry) else {
                return XCTFail("Nested entry emitted")
            }
        case 3:
            guard case .refused(_, nil) = state.begin(launch, slot: .exit) else {
                return XCTFail("Nested exit emitted")
            }
        case 4:
            guard case .refused(.finishInFlight, nil) = state.finish(launch) else {
                return XCTFail("Nested finish emitted")
            }
        default:
            guard case .refused(.closed, nil) = state.begin(launch, slot: .entry) else {
                return XCTFail("Old session misuse emitted")
            }
        }
        XCTAssertTrue(state.failed)
    }
}

private enum FixtureFailure: Error { case admission }
