import Foundation

/// Pure sampled-receipt consistency checks, not process corroboration or quiescence.
/// The caller owns evidence retention and any separately authorized new-process boundary.
struct UIAuditReceiptValidator {
    enum Outcome: Equatable {
        case unobserved
        case clean
        case failed
    }

    enum Counter: Int, CaseIterable {
        case factoryEvaluated
        case apiEntered
    }

    enum Diagnostic: Equatable {
        case missingReceipt
        case malformedReceipt
        case unexpectedRunID
        case changedPID
        case changedProcessInstanceID
        case nonIncreasingSequence(previous: UInt64, incoming: UInt64)
        case nonzero(operation: Int, counter: Counter, value: UInt64)
        case regression(operation: Int, counter: Counter, highWater: UInt64, incoming: UInt64)
    }

    struct Result {
        /// Original input, including nil versus present-but-invalid; never re-encoded.
        let rawReceipt: String?
        let diagnostics: [Diagnostic]
        let outcome: Outcome
    }

    private struct Identity {
        // Both values are app-reported, bound only for consistency.
        let pid: Int32
        let processInstanceID: UUID
    }

    private let expectedRunID: UUID
    private var identity: Identity?
    private var sequenceHighWater: UInt64 = 0
    // Comparison maxima, NOT an actual captured receipt. Exactly 28 components.
    private var counterHighWaters = Array(repeating: UInt64(0), count: 28)
    private var hasFailed = false

    var outcome: Outcome {
        if hasFailed { return .failed }
        return identity == nil ? .unobserved : .clean
    }

    init(expectedRunID: UUID) {
        self.expectedRunID = expectedRunID
    }

    mutating func observe(_ rawReceipt: String?) -> Result {
        let diagnostics = inspect(rawReceipt)
        if !diagnostics.isEmpty { hasFailed = true }
        return Result(rawReceipt: rawReceipt, diagnostics: diagnostics, outcome: outcome)
    }

    private mutating func inspect(_ rawReceipt: String?) -> [Diagnostic] {
        guard let rawReceipt else { return [.missingReceipt] }
        let receipt: UIAuditDecodedReceipt
        do {
            let data = Data(rawReceipt.utf8)
            var guardrail = UIAuditReceiptTokenGuard(bytes: Array(data))
            try guardrail.validate()
            receipt = try JSONDecoder().decode(UIAuditDecodedReceipt.self, from: data)
        } catch {
            return [.malformedReceipt]
        }
        guard receipt.schemaVersion == 1, receipt.pid > 0, receipt.sequence > 0,
              receipt.counts.count == 14,
              receipt.counts.map(\.operation).sorted() == Array(UInt64(0)...13) else {
            return [.malformedReceipt]
        }
        guard receipt.runID == expectedRunID else { return [.unexpectedRunID] }
        if let identity {
            var refusals: [Diagnostic] = []
            if receipt.pid != identity.pid { refusals.append(.changedPID) }
            if receipt.processInstanceID != identity.processInstanceID {
                refusals.append(.changedProcessInstanceID)
            }
            if receipt.sequence <= sequenceHighWater {
                refusals.append(.nonIncreasingSequence(previous: sequenceHighWater, incoming: receipt.sequence))
            }
            guard refusals.isEmpty else { return refusals }
        } else {
            identity = Identity(pid: receipt.pid, processInstanceID: receipt.processInstanceID)
        }

        sequenceHighWater = receipt.sequence
        return compareCounters(receipt.counts)
    }

    private mutating func compareCounters(_ rows: [UIAuditDecodedReceipt.Counts]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        for row in rows {
            let operation = Int(row.operation) // Already restricted to 0...13.
            for counter in Counter.allCases {
                let value = counter == .factoryEvaluated ? row.factoryEvaluated : row.apiEntered
                let index = operation * 2 + counter.rawValue
                let previous = counterHighWaters[index]
                if value < previous {
                    diagnostics.append(.regression(
                        operation: operation, counter: counter, highWater: previous, incoming: value
                    ))
                }
                if value != 0 {
                    diagnostics.append(.nonzero(operation: operation, counter: counter, value: value))
                }
                counterHighWaters[index] = max(previous, value)
            }
        }
        return diagnostics
    }
}

private struct UIAuditDecodedReceipt: Decodable {
    struct Counts: Decodable {
        let operation: UInt64
        let factoryEvaluated: UInt64
        let apiEntered: UInt64
    }

    let schemaVersion: UInt64
    let runID: UUID
    let processInstanceID: UUID
    let pid: Int32
    let sequence: UInt64
    let counts: [Counts]
}

/// Only the schema-one shape: root object -> counts array -> row objects.
/// Reject ambiguous keys and non-integer spellings BEFORE typed decoding can normalize them.
/// Foundation handles JSON string grammar/escapes and subsequent exact integer range checks.
private struct UIAuditReceiptTokenGuard {
    private enum Invalid: Error {
        case receipt
    }

    private static let rootKeys: Set<String> = [
        "schemaVersion", "runID", "processInstanceID", "pid", "sequence", "counts"
    ]
    private static let rowKeys: Set<String> = ["operation", "factoryEvaluated", "apiEntered"]

    let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func validate() throws {
        try object(isRoot: true)
        skipWhitespace()
        guard offset == bytes.count else { throw Invalid.receipt }
    }

    private mutating func object(isRoot: Bool) throws {
        try require(123) // {
        let required = isRoot ? Self.rootKeys : Self.rowKeys
        var seen: Set<String> = []
        repeat {
            let key = try string()
            guard required.contains(key), seen.insert(key).inserted else { throw Invalid.receipt }
            try require(58) // :
            if isRoot && key == "counts" {
                try counts()
            } else if isRoot && (key == "runID" || key == "processInstanceID") {
                _ = try string()
            } else {
                try unsignedInteger()
            }
        } while consume(44) // ,
        try require(125) // }
        guard seen == required else { throw Invalid.receipt }
    }

    private mutating func counts() throws {
        try require(91) // [
        for index in 0..<14 {
            if index != 0 { try require(44) }
            try object(isRoot: false)
        }
        try require(93) // ]
    }

    private mutating func string() throws -> String {
        skipWhitespace()
        let start = offset
        try require(34) // "
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            if byte == 92 { // Skip the escaped byte; Foundation validates the complete string.
                guard offset < bytes.count else { throw Invalid.receipt }
                offset += 1
            }
        }
        throw Invalid.receipt
    }

    private mutating func unsignedInteger() throws {
        skipWhitespace()
        guard offset < bytes.count else { throw Invalid.receipt }
        if bytes[offset] == 48 {
            offset += 1
            return // Any following digit/sign/fraction/exponent fails the required separator.
        }
        guard (49...57).contains(bytes[offset]) else { throw Invalid.receipt }
        repeat {
            offset += 1
        } while offset < bytes.count && (48...57).contains(bytes[offset])
    }

    private mutating func skipWhitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) {
            offset += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    private mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw Invalid.receipt }
    }
}
