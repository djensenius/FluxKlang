import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private let scopeRunID = "EDBA0840-DFBB-4EC9-B76E-5DCD81455320"
private let invalidContextIssue = "Production access scope has invalid test/case context"
private let invalidRunIssue = "Production access scope requires FLUXKLANG_AUDIT_RUN_ID to be a UUID"
private let submissionIssue = "Production access receipt encoding/submission failed"

private final class ScopeLog: Sendable {
    struct State {
        var bodies = 0
        var submissions: [(json: String, filename: String)] = []
        var issues: [String] = []
    }
    let state = Mutex(State())

    func submit(_ json: String, _ filename: String) {
        state.withLock { $0.submissions.append((json, filename)) }
    }

    func receipts() throws -> [ProductionAccessScope.Receipt] {
        try state.withLock { state in
            try state.submissions.map {
                try JSONDecoder().decode(ProductionAccessScope.Receipt.self, from: Data($0.json.utf8))
            }
        }
    }
}

private func auditIssue(_ operation: ProductionAccessAudit.Operation, factory: UInt64, api: UInt64) -> String {
    "Production access operation \(operation.rawValue): factoryEvaluated=\(factory), apiEntered=\(api)"
}

/// Only these exact local diagnostics are known; assertions and unrelated errors still fail.
private func expectingIssues(
    _ expected: [String],
    log: ScopeLog,
    body: () async throws -> Void
) async throws {
    try await withKnownIssue("Intentional private-audit scope failure") {
        try await body()
    } matching: { issue in
        switch issue.kind {
        case .unconditional, .errorCaught: break
        default: return false
        }
        guard issue.comments.count == 1,
              let message = expected.first(where: { issue.comments[0] == Comment(rawValue: $0) }) else {
            return false
        }
        log.state.withLock { $0.issues.append(message) }
        return true
    }
    #expect(log.state.withLock { $0.issues.sorted() } == expected.sorted())
}

private func checkCounts(
    _ receipt: ProductionAccessScope.Receipt,
    factory: (ProductionAccessAudit.Operation) -> UInt64 = { _ in 0 },
    api: (ProductionAccessAudit.Operation) -> UInt64 = { _ in 0 }
) {
    let operations = ProductionAccessAudit.Operation.allCases
    #expect(receipt.counts.map(\.operationID).sorted() == operations.map(\.rawValue).sorted())
    for operation in operations {
        let rows = receipt.counts.filter { $0.operationID == operation.rawValue }
        #expect(rows.count == 1)
        #expect(rows.first?.factoryEvaluated == factory(operation))
        #expect(rows.first?.apiEntered == api(operation))
    }
}

struct ProductionAccessScopeTests {
    enum ExitMode: CaseIterable, Sendable {
        case normal, sentinel, cancellation
    }

    private final class Sentinel: Error {}
    private struct SubmissionFailure: Error {}

    @Test func zeroCountsEncodePublicIdentityAndIgnoreAllowedEvents() async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let audit = ProductionAccessAudit()
        for operation in ProductionAccessAudit.Operation.allCases {
            for event in [ProductionAccessAudit.Event.attempted, .denied, .passiveConstruction] {
                audit.record(event, for: operation)
            }
        }
        let log = ScopeLog()
        let scope = ProductionAccessScope(audit: audit, runID: scopeRunID, submit: log.submit)
        #expect(scope.scopeProvider(for: test, testCase: nil) == nil)
        #expect(scope.scopeProvider(for: test, testCase: testCase) != nil)
        try await scope.provideScope(for: test, testCase: testCase) {
            log.state.withLock { $0.bodies += 1 }
        }
        #expect(log.state.withLock { $0.bodies } == 1)
        let receipts = try log.receipts()
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.schemaVersion == 1)
        #expect(receipt.scopeKind == .testCaseExit)
        #expect(receipt.testID == test.id)
        #expect(receipt.runID == UUID(uuidString: scopeRunID))
        #expect(receipt.processID == ProcessInfo.processInfo.processIdentifier)
        checkCounts(receipt)

        let submission = try #require(log.state.withLock { $0.submissions.first })
        let object = try #require(JSONSerialization.jsonObject(with: Data(submission.json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set([
            "schemaVersion", "scopeKind", "testID", "runID", "processInstanceID", "processID", "invocationID", "counts"
        ]))
        let encodedID = try JSONSerialization.data(withJSONObject: #require(object["testID"]))
        #expect(try JSONDecoder().decode(Test.ID.self, from: encodedID) == test.id)
        #expect(submission.filename.contains(receipt.invocationID.uuidString))
    }

    @Test(arguments: ProductionAccessAudit.Operation.allCases,
          [ProductionAccessAudit.Event.factoryEvaluated, .apiEntered])
    func preexistingAbsoluteNonzeroIsDetected(
        operation: ProductionAccessAudit.Operation,
        event: ProductionAccessAudit.Event
    ) async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let audit = ProductionAccessAudit()
        audit.record(event, for: operation)
        let factory: UInt64 = event == .factoryEvaluated ? 1 : 0
        let api: UInt64 = event == .apiEntered ? 1 : 0
        let log = ScopeLog()
        let scope = ProductionAccessScope(audit: audit, runID: scopeRunID, submit: log.submit)
        try await expectingIssues([auditIssue(operation, factory: factory, api: api)], log: log) {
            try await scope.provideScope(for: test, testCase: testCase) {
                log.state.withLock { $0.bodies += 1 }
            }
        }
        #expect(log.state.withLock { $0.bodies } == 1)
        let receipts = try log.receipts()
        #expect(receipts.count == 1)
        checkCounts(try #require(receipts.first),
                    factory: { $0 == operation ? factory : 0 }, api: { $0 == operation ? api : 0 })
    }

    @Test(arguments: ExitMode.allCases, [false, true])
    func exitPathsCheckAndSubmitOnceWithoutReplacingBodyError(mode: ExitMode, sinkFails: Bool) async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let audit = ProductionAccessAudit()
        let log = ScopeLog()
        let sentinel = Sentinel()
        let scope = ProductionAccessScope(audit: audit, runID: scopeRunID) { json, filename in
            log.submit(json, filename)
            if sinkFails { throw SubmissionFailure() }
        }
        let expected = [auditIssue(.wingTransport, factory: 1, api: 1)] + (sinkFails ? [submissionIssue] : [])
        try await expectingIssues(expected, log: log) {
            // Self-cancel a child task, not the runner's task; cancellation remains cooperative.
            let task = Task {
                try await scope.provideScope(for: test, testCase: testCase) {
                    log.state.withLock { $0.bodies += 1 }
                    audit.record(.factoryEvaluated, for: .wingTransport)
                    audit.record(.apiEntered, for: .wingTransport)
                    switch mode {
                    case .normal: break
                    case .sentinel: throw sentinel
                    case .cancellation:
                        withUnsafeCurrentTask { $0?.cancel() }
                        try Task.checkCancellation()
                    }
                }
            }
            do {
                try await task.value
                #expect(mode == .normal)
            } catch {
                switch mode {
                case .normal: Issue.record(error, "Normal body unexpectedly threw")
                case .sentinel: #expect((error as? Sentinel) === sentinel)
                case .cancellation: #expect(error is CancellationError)
                }
            }
        }
        #expect(log.state.withLock { $0.bodies } == 1)
        let receipts = try log.receipts()
        #expect(receipts.count == 1)
        checkCounts(try #require(receipts.first),
                    factory: { $0 == .wingTransport ? 1 : 0 }, api: { $0 == .wingTransport ? 1 : 0 })
    }

    @Test func repeatedInvocationsKeepProcessIdentityButNotInvocationIdentity() async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let log = ScopeLog()
        let scope = ProductionAccessScope(audit: ProductionAccessAudit(), runID: scopeRunID, submit: log.submit)
        let anotherScope = ProductionAccessScope(audit: ProductionAccessAudit(), runID: scopeRunID, submit: log.submit)
        for invocationScope in [scope, scope, anotherScope] {
            try await invocationScope.provideScope(for: test, testCase: testCase) {
                log.state.withLock { $0.bodies += 1 }
            }
        }
        let receipts = try log.receipts()
        #expect(log.state.withLock { $0.bodies } == 3)
        #expect(receipts.count == 3)
        #expect(Set(receipts.map(\.invocationID)).count == 3)
        #expect(Set(receipts.map(\.processInstanceID)).count == 1)
        #expect(Set(receipts.map(\.processID)) == [ProcessInfo.processInfo.processIdentifier])
        #expect(receipts.allSatisfy { $0.testID == test.id && $0.runID == UUID(uuidString: scopeRunID) })
    }

    @Test(arguments: [nil, "not-a-uuid"] as [String?])
    func invalidRunStillExecutesBodyAndAuditWithoutReceipt(runID: String?) async throws {
        try await checkInvalidMetadata(runID: runID, omitCase: false, expected: invalidRunIssue)
    }

    @Test func ordinaryTestWithoutCaseStillExecutesBodyAndAuditWithoutReceipt() async throws {
        try await checkInvalidMetadata(runID: scopeRunID, omitCase: true, expected: invalidContextIssue)
    }

    private func checkInvalidMetadata(runID: String?, omitCase: Bool, expected: String) async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let log = ScopeLog()
        let audit = ProductionAccessAudit()
        audit.record(.apiEntered, for: .cloudKitHistory)
        let sentinel = Sentinel()
        let scope = ProductionAccessScope(audit: audit, runID: runID, submit: log.submit)
        try await expectingIssues([expected, auditIssue(.cloudKitHistory, factory: 0, api: 1)], log: log) {
            do {
                try await scope.provideScope(for: test, testCase: omitCase ? nil : testCase) {
                    log.state.withLock { $0.bodies += 1 }
                    throw sentinel
                }
                Issue.record("Expected original body error")
            } catch {
                #expect((error as? Sentinel) === sentinel)
            }
        }
        #expect(log.state.withLock { $0.bodies } == 1)
        #expect(log.state.withLock { $0.submissions.isEmpty })
    }

    @Test func issueTimeRecordingCannotChangeTheExitSnapshot() async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let audit = ProductionAccessAudit()
        audit.record(.factoryEvaluated, for: .wingTransport)
        let log = ScopeLog()
        let expected = auditIssue(.wingTransport, factory: 1, api: 0)
        let scope = ProductionAccessScope(audit: audit, runID: scopeRunID, submit: log.submit)
        try await withKnownIssue("Mutate private audit after its exit snapshot") {
            try await scope.provideScope(for: test, testCase: testCase) {
                log.state.withLock { $0.bodies += 1 }
            }
        } matching: { issue in
            guard case .unconditional = issue.kind, issue.comments == [Comment(rawValue: expected)] else {
                return false
            }
            log.state.withLock { $0.issues.append(expected) }
            audit.record(.apiEntered, for: .cloudKitHistory)
            return true
        }
        #expect(log.state.withLock { $0.bodies } == 1)
        #expect(log.state.withLock { $0.issues } == [expected])
        let receipts = try log.receipts()
        #expect(receipts.count == 1)
        checkCounts(try #require(receipts.first), factory: { $0 == .wingTransport ? 1 : 0 })
        #expect(audit.snapshot().count(.apiEntered, for: .cloudKitHistory) == 1)
    }

    @Test func concurrentIndependentAuditsCannotMaskForbiddenCounts() async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for dirty in [false, true] {
                group.addTask {
                    let audit = ProductionAccessAudit()
                    let log = ScopeLog()
                    if dirty {
                        for operation in ProductionAccessAudit.Operation.allCases {
                            audit.record(.factoryEvaluated, for: operation)
                        }
                    }
                    let scope = ProductionAccessScope(audit: audit, runID: scopeRunID, submit: log.submit)
                    let run: @Sendable () async throws -> Void = {
                        try await scope.provideScope(for: test, testCase: testCase) {
                            log.state.withLock { $0.bodies += 1 }
                            await withTaskGroup(of: Void.self) { writers in
                                for operation in ProductionAccessAudit.Operation.allCases {
                                    writers.addTask {
                                        for _ in 0..<32 {
                                            audit.record(dirty ? .factoryEvaluated : .attempted, for: operation)
                                            await Task.yield()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if dirty {
                        let expected = ProductionAccessAudit.Operation.allCases.map {
                            auditIssue($0, factory: 33, api: 0)
                        }
                        try await expectingIssues(expected, log: log, body: run)
                    } else {
                        try await run()
                    }
                    #expect(log.state.withLock { $0.bodies } == 1)
                    let receipts = try log.receipts()
                    #expect(receipts.count == 1)
                    checkCounts(try #require(receipts.first), factory: { _ in dirty ? 33 : 0 })
                }
            }
            try await group.waitForAll()
        }
    }
}

/// Obtain real suite metadata through the public runner, never a fabricated Test or case.
private struct SuiteExitProbe: SuiteTrait, TestScoping {
    @TaskLocal static var owningSuite: Test?
    var isRecursive: Bool { false }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let log = ScopeLog()
        let scope = ProductionAccessScope(audit: ProductionAccessAudit(), runID: scopeRunID, submit: log.submit)
        #expect(scope.scopeProvider(for: test, testCase: nil) != nil)
        try await scope.provideScope(for: test, testCase: testCase) {
            log.state.withLock { $0.bodies += 1 }
            try await Self.$owningSuite.withValue(test) { try await function() }
        }
        let receipts = try log.receipts()
        #expect(log.state.withLock { $0.bodies } == 1)
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.scopeKind == .suiteExit)
        #expect(receipt.testID == test.id)
        #expect(Test.current?.id == test.id)
        checkCounts(receipt)
    }
}

@Suite(SuiteExitProbe())
struct ProductionAccessScopeSuiteTests {
    @Test func suiteWithCaseIsInvalidButStillRunsBodyAndAudit() async throws {
        let suite = try #require(SuiteExitProbe.owningSuite)
        let testCase = try #require(Test.Case.current)
        let audit = ProductionAccessAudit()
        audit.record(.apiEntered, for: .midiInput)
        let log = ScopeLog()
        let scope = ProductionAccessScope(audit: audit, runID: scopeRunID, submit: log.submit)
        try await expectingIssues([invalidContextIssue, auditIssue(.midiInput, factory: 0, api: 1)], log: log) {
            try await scope.provideScope(for: suite, testCase: testCase) {
                log.state.withLock { $0.bodies += 1 }
            }
        }
        #expect(log.state.withLock { $0.bodies } == 1)
        #expect(log.state.withLock { $0.submissions.isEmpty })
    }
}
