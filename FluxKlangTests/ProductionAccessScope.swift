import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Cumulative exit evidence only: not success, descendant coverage, or process quiescence.
struct ProductionAccessScope: SuiteTrait, TestTrait, TestScoping {
    enum ScopeKind: String, Codable, Sendable {
        case suiteExit, testCaseExit
    }

    struct Counts: Codable, Sendable {
        let operationID: Int
        let factoryEvaluated: UInt64
        let apiEntered: UInt64
    }

    struct Receipt: Codable, Sendable {
        let schemaVersion: Int
        let scopeKind: ScopeKind
        let testID: Test.ID
        let runID: UUID
        let processInstanceID: UUID
        let processID: Int32
        let invocationID: UUID
        let counts: [Counts]
    }

    private static let processInstanceID = UUID()
    private let audit: ProductionAccessAudit
    private let runID: String?
    private let submit: @Sendable (String, String) throws -> Void

    var isRecursive: Bool { false }

    init() {
        self.init(
            audit: .shared,
            runID: ProcessInfo.processInfo.environment["FLUXKLANG_AUDIT_RUN_ID"]
        ) { json, filename in
            // Void/best-effort: this is not a persistence or delivery acknowledgment.
            Attachment.record(json, named: filename)
        }
    }

    /// Private-audit and local submission-failure seams for this helper's pure tests.
    init(
        audit: ProductionAccessAudit,
        runID: String?,
        submit: @escaping @Sendable (String, String) throws -> Void
    ) {
        self.audit = audit
        self.runID = runID
        self.submit = submit
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let invocationID = UUID()
        defer {
            // Exactly one coherent, absolute snapshot, even on error or cancellation.
            let snapshot = audit.snapshot()
            recordExit(snapshot, test: test, testCase: testCase, invocationID: invocationID)
        }
        try await function()
    }

    private func recordExit(
        _ snapshot: ProductionAccessAudit.Snapshot,
        test: Test,
        testCase: Test.Case?,
        invocationID: UUID
    ) {
        let counts = ProductionAccessAudit.Operation.allCases.map { operation in
            let factory = snapshot.count(.factoryEvaluated, for: operation)
            let api = snapshot.count(.apiEntered, for: operation)
            if factory != 0 || api != 0 {
                Issue.record(
                    "Production access operation \(operation.rawValue): factoryEvaluated=\(factory), apiEntered=\(api)")
            }
            return Counts(operationID: operation.rawValue, factoryEvaluated: factory, apiEntered: api)
        }

        let scopeKind: ScopeKind?
        switch (test.isSuite, testCase != nil) {
        case (true, false): scopeKind = .suiteExit
        case (false, true): scopeKind = .testCaseExit
        default:
            scopeKind = nil
            Issue.record("Production access scope has invalid test/case context")
        }
        let parsedRunID = runID.flatMap(UUID.init(uuidString:))
        if parsedRunID == nil {
            Issue.record("Production access scope requires FLUXKLANG_AUDIT_RUN_ID to be a UUID")
        }
        guard let scopeKind, let parsedRunID else { return }

        let receipt = Receipt(
            schemaVersion: 1,
            scopeKind: scopeKind,
            testID: test.id,
            runID: parsedRunID,
            processInstanceID: Self.processInstanceID,
            processID: ProcessInfo.processInfo.processIdentifier,
            invocationID: invocationID,
            counts: counts)
        do {
            let data = try JSONEncoder().encode(receipt)
            guard let json = String(data: data, encoding: .utf8) else {
                Issue.record("Production access receipt encoding/submission failed")
                return
            }
            try submit(json, "production-access-\(scopeKind.rawValue)-\(invocationID.uuidString).json")
        } catch {
            Issue.record(error, "Production access receipt encoding/submission failed")
        }
    }
}

extension Trait where Self == ProductionAccessScope {
    static var productionAccessAudit: Self { Self() }
}
