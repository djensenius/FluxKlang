import Foundation

/// Pure producer state. A receipt describes one snapshot, not success or quiescence.
@MainActor
final class UIAuditCaptureState {
    struct Context: Sendable {
        var isDebug: Bool
        var isIOS: Bool
        var arguments: [String]
        var environment: [String: String]
        var selectedTesting: Bool
        var pid: Int32

        var eligibleRunID: UUID? {
            guard isDebug, isIOS, selectedTesting, pid > 0,
                  arguments.contains("-ui-testing"),
                  environment["FLUXKLANG_ISOLATED_TESTING"] == "1",
                  environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "0",
                  environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "0",
                  let rawRunID = environment["FLUXKLANG_AUDIT_RUN_ID"] else { return nil }
            return UUID(uuidString: rawRunID)
        }
    }

    struct Counts: Codable, Equatable, Sendable {
        let operation: Int
        let factoryEvaluated: UInt64
        let apiEntered: UInt64
    }

    struct Receipt: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let runID: UUID
        let processInstanceID: UUID
        let pid: Int32
        let sequence: UInt64
        let counts: [Counts]
    }

    // Schema 1 is deliberately pinned, not expanded when the audit enum grows.
    private static let operations: [ProductionAccessAudit.Operation] = [
        .wingTransport, .midiInput, .permissionProbe, .localNetworkProbe,
        .discoveryInterfaces, .wingPeerResolution, .credentialStore, .assistantHTTP,
        .assistantSpeech, .assistantModelGenerator, .assistantActionInterpreter,
        .ubiquitousCloudStore, .cloudChangeObserver, .cloudKitHistory
    ]

    let runID: UUID
    let processInstanceID: UUID
    let pid: Int32
    private(set) var sequence: UInt64
    private(set) var publication: String?
    private var exhausted = false
    private let audit: ProductionAccessAudit
    private let encode: (Receipt) throws -> Data

    /// The sequence seed and throwing encoder are confined to this pure testing seam.
    init?(
        context: Context,
        audit: ProductionAccessAudit,
        processInstanceID: UUID = UUID(),
        initialSequence: UInt64 = 0,
        encode: @escaping (Receipt) throws -> Data = { try JSONEncoder().encode($0) }
    ) {
        guard let runID = context.eligibleRunID else { return nil }
        self.runID = runID
        self.processInstanceID = processInstanceID
        self.pid = context.pid
        self.sequence = initialSequence
        self.audit = audit
        self.encode = encode
    }

    /// Validation and reads never snapshot or advance. Refusal also affects future attachments.
    @discardableResult
    func validate(_ context: Context) -> Bool {
        guard !exhausted, context.eligibleRunID == runID, context.pid == pid else {
            publication = nil
            return false
        }
        return true
    }

    /// Called synchronously only by the explicit UI command in the canonical service.
    func capture(_ context: Context) {
        guard validate(context) else { return }
        let (next, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow else {
            exhausted = true
            publication = nil
            return
        }
        sequence = next
        let snapshot = audit.snapshot()
        let receipt = Receipt(
            schemaVersion: 1, runID: runID, processInstanceID: processInstanceID,
            pid: pid, sequence: next,
            counts: Self.operations.map {
                Counts(
                    operation: $0.rawValue,
                    factoryEvaluated: snapshot.count(.factoryEvaluated, for: $0),
                    apiEntered: snapshot.count(.apiEntered, for: $0)
                )
            }
        )
        do {
            let data = try encode(receipt)
            publication = String(data: data, encoding: .utf8)
        } catch {
            publication = nil
        }
    }
}
