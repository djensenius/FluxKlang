import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct UIAuditCaptureStateTests {
    private let runID = UUID(uuidString: "F767034A-C02C-47D7-A076-0110C8824C4E")!
    private let processID = UUID(uuidString: "4AD230C8-19F8-4D53-A673-63075124540A")!

    private func context() -> UIAuditCaptureState.Context {
        UIAuditCaptureState.Context(
            isDebug: true, isIOS: true, arguments: ["FluxKlang", "-ui-testing"],
            environment: [
                "FLUXKLANG_ISOLATED_TESTING": "1",
                "FLUXKLANG_QUALIFY_APPLE_ROUTING": "0",
                "FLUXKLANG_RUN_APPLE_MODEL_TESTS": "0",
                "FLUXKLANG_AUDIT_RUN_ID": runID.uuidString
            ],
            selectedTesting: true, pid: 123
        )
    }

    private func ineligibleContexts() -> [UIAuditCaptureState.Context] {
        let valid = context()
        var contexts: [UIAuditCaptureState.Context] = []
        for (key, literal) in [
            ("FLUXKLANG_ISOLATED_TESTING", "1"),
            ("FLUXKLANG_QUALIFY_APPLE_ROUTING", "0"),
            ("FLUXKLANG_RUN_APPLE_MODEL_TESTS", "0")
        ] {
            var missing = valid
            missing.environment.removeValue(forKey: key)
            contexts.append(missing)
            for value in ["", "true", "false", "TRUE", "01", "00", " 1", "1 ", " 0", "0 ", "1\n", "0\n",
                          "2", "-1", literal == "1" ? "0" : "1"] {
                var invalid = valid
                invalid.environment[key] = value
                contexts.append(invalid)
            }
        }
        var missingRun = valid
        missingRun.environment.removeValue(forKey: "FLUXKLANG_AUDIT_RUN_ID")
        contexts.append(missingRun)
        for value in ["", "not-a-uuid", "123", " \(runID.uuidString)", "\(runID.uuidString)\n"] {
            var invalid = valid
            invalid.environment["FLUXKLANG_AUDIT_RUN_ID"] = value
            contexts.append(invalid)
        }
        for arguments in [[], ["-ui-testing=1"], ["-UI-TESTING"]] {
            var invalid = valid
            invalid.arguments = arguments
            contexts.append(invalid)
        }
        var notDebug = valid
        notDebug.isDebug = false
        contexts.append(notDebug)
        var notIOS = valid
        notIOS.isIOS = false
        contexts.append(notIOS)
        var notSelected = valid
        notSelected.selectedTesting = false
        contexts.append(notSelected)
        for pid: Int32 in [0, -1] {
            var invalid = valid
            invalid.pid = pid
            contexts.append(invalid)
        }
        return contexts
    }

    private func receipt(_ state: UIAuditCaptureState) throws -> UIAuditCaptureState.Receipt {
        let value = try #require(state.publication)
        return try JSONDecoder().decode(UIAuditCaptureState.Receipt.self, from: Data(value.utf8))
    }

    @Test func rejectsEveryIneligibleInitialContext() {
        let invalid = ineligibleContexts()
        #expect(invalid.count == 62)
        for context in invalid {
            #expect(context.eligibleRunID == nil)
            #expect(UIAuditCaptureState(context: context, audit: ProductionAccessAudit()) == nil)
        }
    }

    @Test func everyInvalidGateClearsExistingPublicationWithoutAdvancing() throws {
        for invalid in ineligibleContexts() {
            let state = try #require(UIAuditCaptureState(context: context(), audit: ProductionAccessAudit()))
            state.capture(context())
            #expect(state.publication != nil)
            state.capture(invalid)
            #expect(state.publication == nil)
            #expect(state.sequence == 1)
            #expect(!state.validate(invalid))
            #expect(state.publication == nil)
        }
    }

    @Test func initialReadsAndValidationNeverCapture() throws {
        let audit = ProductionAccessAudit()
        let state = try #require(UIAuditCaptureState(context: context(), audit: audit))
        audit.record(.apiEntered, for: .wingTransport)
        for _ in 0..<5 {
            #expect(state.validate(context()))
            #expect(state.sequence == 0)
            #expect(state.publication == nil)
        }
        state.capture(context())
        #expect(try receipt(state).sequence == 1)
        #expect(try receipt(state).counts[0].apiEntered == 1)
    }

    @Test func encodedSchemaPinsIdentityKeysAndOperations() throws {
        let state = try #require(UIAuditCaptureState(
            context: context(), audit: ProductionAccessAudit(), processInstanceID: processID
        ))
        state.capture(context())
        let value = try #require(state.publication)
        let object = try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "runID", "processInstanceID", "pid", "sequence", "counts"])
        let rows = try #require(object["counts"] as? [[String: Any]])
        #expect(rows.count == 14)
        #expect(rows.compactMap { $0["operation"] as? Int }.sorted() == Array(0...13))
        for row in rows {
            #expect(Set(row.keys) == ["operation", "factoryEvaluated", "apiEntered"])
        }
        let decoded = try receipt(state)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.runID == runID)
        #expect(decoded.processInstanceID == processID)
        #expect(decoded.pid == 123)
        #expect(decoded.sequence == 1)
        #expect(decoded.counts.allSatisfy { $0.factoryEvaluated == 0 && $0.apiEntered == 0 })
        #expect(ProductionAccessAudit.Operation.allCases.map(\.rawValue) == Array(0...13))
    }

    @Test func cumulativeNonzeroReceiptsRemainImmutable() throws {
        let audit = ProductionAccessAudit()
        for operation in ProductionAccessAudit.Operation.allCases {
            for _ in 0...operation.rawValue { audit.record(.factoryEvaluated, for: operation) }
        }
        let state = try #require(UIAuditCaptureState(
            context: context(), audit: audit, processInstanceID: processID
        ))
        state.capture(context())
        let firstJSON = try #require(state.publication)
        let first = try receipt(state)
        for operation in ProductionAccessAudit.Operation.allCases {
            audit.record(.factoryEvaluated, for: operation)
            audit.record(.apiEntered, for: operation)
        }
        #expect(state.publication == firstJSON)
        state.capture(context())
        let second = try receipt(state)
        #expect(second.sequence == 2)
        #expect(second.runID == first.runID)
        #expect(second.processInstanceID == first.processInstanceID)
        #expect(second.pid == first.pid)
        for index in 0...13 {
            #expect(first.counts[index].factoryEvaluated == UInt64(index + 1))
            #expect(first.counts[index].apiEntered == 0)
            #expect(second.counts[index].factoryEvaluated == UInt64(index + 2))
            #expect(second.counts[index].apiEntered == 1)
        }
        #expect(try JSONDecoder().decode(UIAuditCaptureState.Receipt.self, from: Data(firstJSON.utf8)) == first)
    }

    @Test func allowedEventsAreExcludedRatherThanSubstituted() throws {
        let audit = ProductionAccessAudit()
        for operation in ProductionAccessAudit.Operation.allCases {
            for event: ProductionAccessAudit.Event in [.attempted, .denied, .passiveConstruction] {
                audit.record(event, for: operation)
            }
        }
        let state = try #require(UIAuditCaptureState(context: context(), audit: audit))
        state.capture(context())
        #expect(try receipt(state).counts.allSatisfy { $0.factoryEvaluated == 0 && $0.apiEntered == 0 })
        #expect(audit.snapshot().count(.attempted, for: .wingTransport) == 1)
        #expect(audit.snapshot().count(.denied, for: .wingTransport) == 1)
        #expect(audit.snapshot().count(.passiveConstruction, for: .wingTransport) == 1)
    }

    @Test func privateRecordersStayIndependent() throws {
        let audit = ProductionAccessAudit()
        let first = try #require(UIAuditCaptureState(context: context(), audit: audit))
        let second = try #require(UIAuditCaptureState(context: context(), audit: ProductionAccessAudit()))
        audit.record(.apiEntered, for: .cloudKitHistory)
        first.capture(context())
        second.capture(context())
        #expect(try receipt(first).counts[13].apiEntered == 1)
        #expect(try receipt(second).counts[13].apiEntered == 0)
        #expect(first.processInstanceID != second.processInstanceID)
    }

    @Test func changedRunOrPIDCannotRebindSession() throws {
        var changedRun = context()
        changedRun.environment["FLUXKLANG_AUDIT_RUN_ID"] = processID.uuidString
        var changedPID = context()
        changedPID.pid += 1
        for changed in [changedRun, changedPID] {
            #expect(changed.eligibleRunID != nil)
            let state = try #require(UIAuditCaptureState(context: context(), audit: ProductionAccessAudit()))
            state.capture(context())
            state.capture(changed)
            #expect(state.publication == nil)
            #expect(state.sequence == 1)
            #expect(state.runID == runID)
            #expect(state.pid == 123)
            #expect(!state.validate(changed))
        }
    }

    @Test func restorationAndRevalidationDoNotRepublishStaleReceipt() throws {
        let state = try #require(UIAuditCaptureState(context: context(), audit: ProductionAccessAudit()))
        state.capture(context())
        var invalid = context()
        invalid.selectedTesting = false
        #expect(!state.validate(invalid))
        #expect(state.publication == nil)
        #expect(state.validate(context()))
        #expect(state.publication == nil)
        #expect(state.sequence == 1)
        state.capture(context())
        #expect(try receipt(state).sequence == 2)
    }

    @Test func processInstanceIdentitySurvivesRepeatedCapturesAndReads() throws {
        let state = try #require(UIAuditCaptureState(context: context(), audit: ProductionAccessAudit()))
        let identity = state.processInstanceID
        for sequence: UInt64 in 1...3 {
            state.capture(context())
            let published = state.publication
            #expect(state.validate(context()))
            #expect(state.publication == published)
            #expect(try receipt(state).processInstanceID == identity)
            #expect(try receipt(state).sequence == sequence)
        }
    }

    @Test func snapshotPrecedesEncodingAndIsNotLive() throws {
        let audit = ProductionAccessAudit()
        var encodings = 0
        let state = try #require(UIAuditCaptureState(context: context(), audit: audit) { receipt in
            encodings += 1
            for operation in ProductionAccessAudit.Operation.allCases {
                audit.record(.factoryEvaluated, for: operation)
                audit.record(.apiEntered, for: operation)
            }
            return try JSONEncoder().encode(receipt)
        })
        state.capture(context())
        #expect(encodings == 1)
        #expect(try receipt(state).counts.allSatisfy { $0.factoryEvaluated == 0 && $0.apiEntered == 0 })
        state.capture(context())
        #expect(encodings == 2)
        #expect(try receipt(state).counts.allSatisfy { $0.factoryEvaluated == 1 && $0.apiEntered == 1 })
        #expect(audit.snapshot().count(.apiEntered, for: .wingTransport) == 2)
    }

    @Test func encodingFailureClearsPublicationAndDoesNotReuseSequence() throws {
        var fail = false
        let state = try #require(UIAuditCaptureState(
            context: context(), audit: ProductionAccessAudit()
        ) { receipt in
            if fail { throw EncodingFailure.expected }
            return try JSONEncoder().encode(receipt)
        })
        state.capture(context())
        #expect(state.publication != nil)
        fail = true
        state.capture(context())
        #expect(state.publication == nil)
        #expect(state.sequence == 2)
        #expect(state.validate(context()))
        #expect(state.publication == nil)
        fail = false
        state.capture(context())
        #expect(try receipt(state).sequence == 3)
    }

    @Test func nonUTF8EncodingClearsExistingPublication() throws {
        var invalidUTF8 = false
        let state = try #require(UIAuditCaptureState(
            context: context(), audit: ProductionAccessAudit()
        ) { receipt in
            if invalidUTF8 { return Data([0xFF]) }
            return try JSONEncoder().encode(receipt)
        })
        state.capture(context())
        #expect(state.publication != nil)
        invalidUTF8 = true
        state.capture(context())
        #expect(state.publication == nil)
        #expect(state.sequence == 2)
    }

    @Test func checkedExhaustionIsTerminalAndClearsLastReceipt() throws {
        var encodings = 0
        let state = try #require(UIAuditCaptureState(
            context: context(), audit: ProductionAccessAudit(), initialSequence: .max - 1
        ) { receipt in
            encodings += 1
            return try JSONEncoder().encode(receipt)
        })
        #expect(state.publication == nil)
        state.capture(context())
        #expect(try receipt(state).sequence == UInt64.max)
        #expect(encodings == 1)
        for _ in 0..<3 {
            state.capture(context())
            #expect(state.publication == nil)
            #expect(state.sequence == UInt64.max)
            #expect(!state.validate(context()))
            #expect(encodings == 1)
        }
    }

    @Test func initiallyExhaustedSeedNeverPublishes() throws {
        let state = try #require(UIAuditCaptureState(
            context: context(), audit: ProductionAccessAudit(), initialSequence: .max
        ))
        state.capture(context())
        #expect(state.publication == nil)
        #expect(state.sequence == UInt64.max)
        #expect(!state.validate(context()))
    }

    @Test func schemaPreservesFullWidthUnsignedCounters() throws {
        let receipt = UIAuditCaptureState.Receipt(
            schemaVersion: 1, runID: runID, processInstanceID: processID, pid: .max, sequence: .max,
            counts: (0...13).map {
                .init(operation: $0, factoryEvaluated: UInt64.max, apiEntered: UInt64.max - 1)
            }
        )
        let encoded = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(UIAuditCaptureState.Receipt.self, from: encoded) == receipt)
    }
}

private enum EncodingFailure: Error {
    case expected
}
