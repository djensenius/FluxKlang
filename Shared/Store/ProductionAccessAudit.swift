import Synchronization

/// Control-side observation only: no policy decisions, I/O, reset, or real-time use.
final class ProductionAccessAudit: Sendable {
    enum Operation: Int, CaseIterable, Sendable {
        case wingTransport
        case midiInput
        case permissionProbe
        case localNetworkProbe
        case discoveryInterfaces
        case wingPeerResolution
        case credentialStore
        case assistantHTTP
        case assistantSpeech
        case assistantModelGenerator
        case assistantActionInterpreter
        case ubiquitousCloudStore
    }

    enum Event: Int, CaseIterable, Sendable {
        case attempted
        case denied
        case factoryEvaluated
        case passiveConstruction
        case apiEntered
    }

    struct Snapshot: Equatable, Sendable {
        fileprivate let counts: [UInt64]

        func count(_ event: Event, for operation: Operation) -> UInt64 {
            counts[ProductionAccessAudit.index(event, for: operation)]
        }
    }

    /// Bounds synchronous construction, not later startup tasks or exclusive attribution.
    struct Checkpoint: Equatable, Sendable {
        let before: Snapshot
        let after: Snapshot
    }

    static let shared = ProductionAccessAudit()

    private static let eventCount = Event.allCases.count
    private let counts = Mutex(
        Array(repeating: UInt64(0), count: Operation.allCases.count * eventCount))

    func record(_ event: Event, for operation: Operation) {
        counts.withLock { values in
            let index = Self.index(event, for: operation)
            if values[index] < .max { values[index] += 1 }
        }
    }

    func record(_ event: Event, for operation: Operation, mirroring mirror: ProductionAccessAudit?) {
        record(event, for: operation)
        if let mirror, mirror !== self { mirror.record(event, for: operation) }
    }

    func snapshot() -> Snapshot {
        counts.withLock { Snapshot(counts: $0) }
    }

    func captureConstruction<Value>(_ make: () -> Value) -> (value: Value, checkpoint: Checkpoint) {
        let before = snapshot()
        let value = make()
        return (value, Checkpoint(before: before, after: snapshot()))
    }

    private static func index(_ event: Event, for operation: Operation) -> Int {
        operation.rawValue * eventCount + event.rawValue
    }
}
