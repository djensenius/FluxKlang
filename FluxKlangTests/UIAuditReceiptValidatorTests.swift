import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@MainActor
struct UIAuditReceiptValidatorTests {
    private typealias Validator = UIAuditReceiptValidator
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

    private func encoded(sequence: UInt64 = 1, factory: UInt64 = 0, api: UInt64 = 0) throws -> String {
        let receipt = UIAuditCaptureState.Receipt(
            schemaVersion: 1, runID: runID, processInstanceID: processID, pid: 123, sequence: sequence,
            counts: (0...13).map {
                .init(operation: $0, factoryEvaluated: factory, apiEntered: api)
            }
        )
        return try #require(String(data: JSONEncoder().encode(receipt), encoding: .utf8))
    }

    private func row(_ operation: Int, factory: String = "0", api: String = "0") -> String {
        """
        {"operation":\(operation),"factoryEvaluated":\(factory),"apiEntered":\(api)}
        """
    }

    private func wire(sequence: String = "1", rows: [String]? = nil) -> String {
        let counts = (rows ?? (0...13).map { row($0) }).joined(separator: ",")
        return """
        {"schemaVersion":1,"runID":"\(runID.uuidString)","processInstanceID":"\(processID.uuidString)",
        "pid":123,"sequence":\(sequence),"counts":[\(counts)]}
        """
    }

    private func expectMalformed(_ raw: String) {
        var validator = Validator(expectedRunID: runID)
        let result = validator.observe(raw)
        #expect(result.diagnostics == [.malformedReceipt])
        #expect(result.outcome == .failed)
        #expect(Array(result.rawReceipt!.utf8) == Array(raw.utf8))
        #expect(validator.observe(wire()).diagnostics.isEmpty)
        #expect(validator.outcome == .failed)
    }

    @Test func privateProducerAllowedEventsAndSkippedEncodingSequence() throws {
        let audit = ProductionAccessAudit()
        var failEncoding = false
        let state = try #require(UIAuditCaptureState(
            context: context(), audit: audit, processInstanceID: processID
        ) { receipt in
            if failEncoding { throw ReceiptEncodingFailure.expected }
            return try JSONEncoder().encode(receipt) // Real producer order, no sortedKeys.
        })
        var validator = Validator(expectedRunID: runID)
        #expect(validator.outcome == .unobserved)
        for operation in ProductionAccessAudit.Operation.allCases {
            for event: ProductionAccessAudit.Event in [.attempted, .denied, .passiveConstruction] {
                audit.record(event, for: operation)
            }
        }
        state.capture(context())
        let first = validator.observe(state.publication)
        #expect(first.diagnostics.isEmpty)
        #expect(first.outcome == .clean)
        #expect(first.rawReceipt == state.publication)
        failEncoding = true
        state.capture(context())
        #expect(state.publication == nil)
        #expect(state.sequence == 2)
        failEncoding = false
        state.capture(context())
        #expect(state.sequence == 3)
        #expect(validator.observe(state.publication).outcome == .clean)
        #expect(audit.snapshot().count(.attempted, for: .wingTransport) == 1)
        audit.record(.factoryEvaluated, for: .midiInput)
        audit.record(.apiEntered, for: .cloudKitHistory)
        state.capture(context())
        #expect(validator.observe(state.publication).diagnostics == [
            .nonzero(operation: 1, counter: .factoryEvaluated, value: 1),
            .nonzero(operation: 13, counter: .apiEntered, value: 1)
        ])
    }

    @Test func missingAndMalformedFailBeforeBindingWithoutResettingFailure() throws {
        for raw: String? in [nil, "", "null", "{", "[]", wire(sequence: "0")] {
            var validator = Validator(expectedRunID: runID)
            #expect(validator.outcome == .unobserved)
            let first = validator.observe(raw)
            #expect(first.rawReceipt == raw)
            #expect(first.diagnostics == [raw == nil ? .missingReceipt : .malformedReceipt])
            #expect(first.outcome == .failed)
            #expect(validator.observe(try encoded(sequence: 42)).diagnostics.isEmpty)
            #expect(validator.observe(try encoded(sequence: 43)).outcome == .failed)
            #expect(validator.observe(try encoded(sequence: 43)).diagnostics == [
                .nonIncreasingSequence(previous: 43, incoming: 43)
            ])
        }
    }

    @Test func firstNonzeroBindsIdentityAndSequenceDespiteFailure() throws {
        var validator = Validator(expectedRunID: runID)
        #expect(validator.observe(try encoded(sequence: 9, factory: 5)).diagnostics.count == 14)
        let changed = wire(sequence: "10").replacingOccurrences(of: "\"pid\":123", with: "\"pid\":124")
        #expect(validator.observe(changed).diagnostics == [.changedPID])
        let next = validator.observe(try encoded(sequence: 10, factory: 5))
        #expect(next.diagnostics.count == 14)
        #expect(next.outcome == .failed)
        #expect(validator.observe(try encoded(sequence: 10)).diagnostics == [
            .nonIncreasingSequence(previous: 10, incoming: 10)
        ])
    }

    @Test func wrongRunCannotBindEvenBeforeFirstValidReceipt() {
        var validator = Validator(expectedRunID: runID)
        let foreign = wire(sequence: "100").replacingOccurrences(of: runID.uuidString, with: processID.uuidString)
        #expect(validator.observe(foreign).diagnostics == [.unexpectedRunID])
        #expect(validator.observe(wire(sequence: "2")).diagnostics.isEmpty)
        #expect(validator.outcome == .failed)
    }

    @Test func unknownMissingAndDuplicateDecodedKeysAtBothLevels() {
        let original = wire()
        let rootFields = [
            "\"schemaVersion\":1,", "\"runID\":\"\(runID.uuidString)\",",
            "\"processInstanceID\":\"\(processID.uuidString)\",", "\"pid\":123,", "\"sequence\":1,"
        ]
        for field in rootFields {
            expectMalformed(original.replacingOccurrences(of: field, with: ""))
            expectMalformed(original.replacingOccurrences(of: field, with: field + field))
        }
        expectMalformed(original.replacingOccurrences(of: "\"counts\"", with: "\"unknown\""))
        expectMalformed(original.replacingOccurrences(of: "\"pid\":123", with: "\"pid\":123,\"extra\":0"))
        expectMalformed(original.replacingOccurrences(
            of: "\"pid\":123", with: "\"pid\":123,\"\\u0070id\":124"
        ))
        let countField = "\"counts\":[" + (0...13).map { row($0) }.joined(separator: ",") + "]"
        expectMalformed(original.replacingOccurrences(of: "," + countField, with: ""))
        expectMalformed(original.replacingOccurrences(of: countField, with: countField + "," + countField))
        expectMalformed(original.replacingOccurrences(
            of: countField, with: countField + "," + countField.replacingOccurrences(of: "counts", with: "\\u0063ounts")
        ))
        for field in ["\"operation\":0,", "\"factoryEvaluated\":0,", ",\"apiEntered\":0"] {
            let changed = row(0).replacingOccurrences(of: field, with: "")
            expectMalformed(original.replacingOccurrences(of: row(0), with: changed))
        }
        for key in ["operation", "factoryEvaluated", "apiEntered"] {
            let escaped = "\\u00" + String(key.utf8.first!, radix: 16) + key.dropFirst()
            for duplicateKey in [key, escaped] {
                let changed = row(0).replacingOccurrences(
                    of: "\"\(key)\":0", with: "\"\(key)\":0,\"\(duplicateKey)\":1"
                )
                expectMalformed(original.replacingOccurrences(of: row(0), with: changed))
            }
        }
        expectMalformed(original.replacingOccurrences(of: "\"operation\":0", with: "\"extra\":0,\"operation\":0"))
    }

    @Test func lexicalNumbersRefuseNormalizationInEveryNumericField() {
        let tokens = [
            "-1", "-0", "+1", "1.0", "0.0", "1e0", "1E+0", "1e-0", "true", "false",
            "\"1\"", "null", "01", "00", "18446744073709551616", "999999999999999999999999999999"
        ]
        for (key, value) in [
            ("schemaVersion", "1"), ("pid", "123"), ("sequence", "1"),
            ("operation", "0"), ("factoryEvaluated", "0"), ("apiEntered", "0")
        ] {
            for token in tokens {
                expectMalformed(wire().replacingOccurrences(of: "\"\(key)\":\(value)", with: "\"\(key)\":\(token)"))
            }
        }
    }

    @Test func closedSchemaAndExactPIDUUIDRanges() {
        for value in ["0", "2", "18446744073709551615"] {
            expectMalformed(wire().replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":\(value)"))
        }
        for value in ["0", "-1", "2147483648", "18446744073709551615"] {
            expectMalformed(wire().replacingOccurrences(of: "\"pid\":123", with: "\"pid\":\(value)"))
        }
        for key in ["runID", "processInstanceID"] {
            let uuid = key == "runID" ? runID : processID
            for token in ["\"invalid\"", "\"\"", "\" \(uuid.uuidString)\"", "123", "true", "null", "{}"] {
                expectMalformed(wire().replacingOccurrences(of: "\"\(uuid.uuidString)\"", with: token))
            }
        }
        for pid in [1, Int32.max] {
            var validator = Validator(expectedRunID: runID)
            #expect(validator.observe(wire().replacingOccurrences(
                of: "\"pid\":123", with: "\"pid\":\(pid)"
            )).outcome == .clean)
        }
    }

    @Test func rowOmissionDuplicationAndOperationRanges() {
        let rows = (0...13).map { row($0) }
        expectMalformed(wire(rows: []))
        expectMalformed(wire(rows: Array(rows.dropLast())))
        expectMalformed(wire(rows: rows + [row(0)]))
        for operation in [-1, 0, 14, Int.max] {
            expectMalformed(wire(rows: Array(rows.dropLast()) + [row(operation)]))
        }
        expectMalformed(wire().replacingOccurrences(of: "\"counts\":[", with: "\"counts\":{"))
        expectMalformed(wire(rows: ["null"] + Array(rows.dropFirst())))
    }

    @Test func stringAwareGuardAcceptsEscapesWhitespaceAndReordering() {
        var raw = wire(rows: (0...13).reversed().map {
            "{\"apiEntered\":0,\"factoryEvaluated\":0,\"operation\":\($0)}"
        })
        for (key, escaped) in [
            ("schemaVersion", "\\u0073chemaVersion"), ("counts", "\\u0063ounts"),
            ("operation", "\\u006fperation"), ("runID", "run\\u0049D")
        ] {
            raw = raw.replacingOccurrences(of: "\"\(key)\"", with: "\"\(escaped)\"")
        }
        raw = raw.replacingOccurrences(of: runID.uuidString, with: "\\u0046" + runID.uuidString.dropFirst())
        raw = " \t\r\n" + raw.replacingOccurrences(of: ":", with: " \n: \t") + "\r\n "
        var validator = Validator(expectedRunID: runID)
        let result = validator.observe(raw)
        #expect(result.diagnostics.isEmpty)
        #expect(result.outcome == .clean)
        #expect(Array(result.rawReceipt!.utf8) == Array(raw.utf8))
    }

    @Test func malformedStringsStructureAndTrailingInputPreserveRawBytes() {
        let original = wire()
        let invalid = [
            original + "{}", original + "false", original + "\u{00A0}", original + "\0",
            original.replacingOccurrences(of: "\"pid\":123", with: "\"p\\q id\":123"),
            original.replacingOccurrences(of: "\"pid\":123", with: "\"pid\n\":123"),
            original.replacingOccurrences(of: "\"pid\":123", with: "\"\\uD800\":123"),
            original.replacingOccurrences(of: "\"pid\":123", with: "\"pid\":123,"),
            original.replacingOccurrences(of: "\"pid\":123", with: "\"pid\" 123"),
            original.replacingOccurrences(of: "\"pid\":123", with: "\"pid\":/*comment*/123"),
            original.replacingOccurrences(of: "\"pid\":123", with: "\"pid\":123,\"é🙂\\\"}\\\\\":0"),
            String(original.dropLast()), original.replacingOccurrences(of: "\"counts\":[", with: "\"counts\":[,")
        ]
        for raw in invalid { expectMalformed(raw) }
    }

    @Test func foreignMalformedAndStaleReceiptsNeverPoisonComparisonState() throws {
        let larger = wire(sequence: "100", rows: (0...13).map { row($0, factory: "99", api: "99") })
        let refused: [(String, Validator.Diagnostic)] = [
            (larger.replacingOccurrences(of: runID.uuidString, with: processID.uuidString), .unexpectedRunID),
            (larger.replacingOccurrences(of: processID.uuidString, with: runID.uuidString), .changedProcessInstanceID),
            (larger.replacingOccurrences(of: "\"pid\":123", with: "\"pid\":124"), .changedPID),
            (larger + "x", .malformedReceipt),
            (try encoded(sequence: 10, factory: 99, api: 99), .nonIncreasingSequence(previous: 10, incoming: 10)),
            (try encoded(sequence: 9, factory: 99, api: 99), .nonIncreasingSequence(previous: 10, incoming: 9))
        ]
        for (raw, diagnostic) in refused {
            var validator = Validator(expectedRunID: runID)
            _ = validator.observe(try encoded(sequence: 10, factory: 5, api: 5))
            #expect(validator.observe(raw).diagnostics == [diagnostic])
            let result = validator.observe(try encoded(sequence: 11, factory: 5, api: 5))
            #expect(result.diagnostics.count == 28)
            #expect(result.outcome == .failed)
            for operation in 0...13 {
                for counter in Validator.Counter.allCases {
                    #expect(result.diagnostics.contains(.nonzero(operation: operation, counter: counter, value: 5)))
                }
            }
        }
    }

    @Test func everyCounterUsesHighWaterNotLastObservationForFiveThreeFour() throws {
        var validator = Validator(expectedRunID: runID)
        #expect(validator.observe(try encoded(sequence: 1, factory: 5, api: 5)).diagnostics.count == 28)
        for (sequence, value): (UInt64, UInt64) in [(2, 3), (3, 4), (4, 0)] {
            let result = validator.observe(try encoded(sequence: sequence, factory: value, api: value))
            #expect(result.diagnostics.count == (value == 0 ? 28 : 56))
            #expect(result.outcome == .failed)
            for operation in 0...13 {
                for counter in Validator.Counter.allCases {
                    #expect(result.diagnostics.contains(.regression(
                        operation: operation, counter: counter, highWater: 5, incoming: value
                    )))
                    if value != 0 {
                        #expect(result.diagnostics.contains(.nonzero(
                            operation: operation, counter: counter, value: value
                        )))
                    }
                }
            }
        }
        #expect(validator.observe(try encoded(sequence: 4)).diagnostics == [
            .nonIncreasingSequence(previous: 4, incoming: 4)
        ])
    }

    @Test func componentMaximaAdvanceIndependentlyEvenWhenOtherComponentsRegress() {
        var validator = Validator(expectedRunID: runID)
        _ = validator.observe(wire(rows: (0...13).map {
            row($0, factory: $0 == 0 ? "5" : "0", api: $0 == 13 ? "8" : "0")
        }))
        let second = validator.observe(wire(sequence: "2", rows: (0...13).map { row($0, factory: "3", api: "4") }))
        #expect(second.diagnostics.count == 30) // 28 nonzero, only two regressions.
        let third = validator.observe(wire(sequence: "3", rows: (0...13).map { row($0, factory: "2", api: "3") }))
        #expect(third.diagnostics.count == 56)
        for operation in 0...13 {
            #expect(third.diagnostics.contains(.regression(
                operation: operation, counter: .factoryEvaluated, highWater: operation == 0 ? 5 : 3, incoming: 2
            )))
            #expect(third.diagnostics.contains(.regression(
                operation: operation, counter: .apiEntered, highWater: operation == 13 ? 8 : 4, incoming: 3
            )))
        }
    }

    @Test func exactFullWidthIntegersAroundDoublePrecisionBoundary() throws {
        let boundary: UInt64 = 9_007_199_254_740_992
        var validator = Validator(expectedRunID: runID)
        for value in [boundary - 1, boundary, boundary + 1, boundary + 2] {
            let result = validator.observe(try encoded(sequence: value, factory: value, api: value))
            #expect(result.diagnostics.count == 28)
            for operation in 0...13 {
                for counter in Validator.Counter.allCases {
                    #expect(result.diagnostics.contains(.nonzero(operation: operation, counter: counter, value: value)))
                }
            }
        }
        let result = validator.observe(try encoded(sequence: boundary + 3, factory: boundary + 1, api: boundary))
        #expect(result.diagnostics.count == 56)
        #expect(result.diagnostics.contains(.regression(
            operation: 0, counter: .factoryEvaluated, highWater: boundary + 2, incoming: boundary + 1
        )))
    }

    @Test func uint64MaximumIsExactAndSequenceExhaustionCannotReset() throws {
        var validator = Validator(expectedRunID: runID)
        let maximum = try encoded(sequence: .max - 1, factory: .max, api: .max - 1)
        let first = validator.observe(maximum)
        #expect(first.diagnostics.count == 28)
        #expect(first.diagnostics.contains(.nonzero(operation: 13, counter: .factoryEvaluated, value: .max)))
        let next = validator.observe(try encoded(sequence: .max, factory: .max - 1, api: .max))
        #expect(next.diagnostics.count == 42)
        #expect(next.diagnostics.contains(.regression(
            operation: 13, counter: .factoryEvaluated, highWater: .max, incoming: .max - 1
        )))
        for sequence: UInt64 in [.max, .max - 1, 1] {
            #expect(validator.observe(try encoded(sequence: sequence)).diagnostics == [
                .nonIncreasingSequence(previous: .max, incoming: sequence)
            ])
        }
        #expect(validator.observe(wire(sequence: "18446744073709551616")).diagnostics == [.malformedReceipt])
        #expect(validator.outcome == .failed)
        var initiallyMaximum = Validator(expectedRunID: runID)
        #expect(initiallyMaximum.observe(try encoded(sequence: .max)).outcome == .clean)
    }
}

private enum ReceiptEncodingFailure: Error {
    case expected
}
