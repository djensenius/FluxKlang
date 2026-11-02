//
//  FakeProcessor.swift
//  FluxKlangTests
//
//  A processor double that only prepares actions. It has no render or write
//  API: preparing changes the fixture's readiness and nothing else.
//

@testable import FluxKlang

/// Why a fake preparation did not make the action ready. The ledger is never changed.
enum FakeProcessorError: Error, Equatable, Sendable {
    /// A scripted fault. `.prepareFailed` means the processor ran and failed:
    /// the action went `preparing → failed` with `preparationFailed`.
    /// `.timedOut`, `.disconnected`, `.capacity` and `.callLimitExceeded` never
    /// reached the processor and leave the readiness unchanged.
    case fault(FixtureFault)
    /// The readiness contract refused the preparation. Only
    /// `timeStretchUnavailable` is kept (the contract records the action as
    /// failed); every other refusal leaves the readiness unchanged. This includes
    /// a `.prepareFailed` fault whose failure the contract cannot record.
    case readiness(ReadinessError)
}

struct FakeProcessor: Sendable {
    /// Local until F1 merges; it then moves to `ContractFixtureIDs`.
    static let fixtureNode = NodeID(validated: "fx.node.processor")

    let node: NodeID
    /// Whether `timeStretch` policies can be prepared.
    let supportsTimeStretch: Bool
    /// Scripted per call; see `FakeProcessorError.fault` for which faults change readiness.
    var faults: FaultScript
    /// Every attempted preparation, including faulted and refused ones.
    private(set) var prepareCalls: BoundedRecorder<ActionID>

    init(
        node: NodeID = Self.fixtureNode,
        supportsTimeStretch: Bool = false,
        faults: FaultScript,
        callCapacity: Int = 64
    ) throws(BoundedRecorderError) {
        self.node = node
        self.supportsTimeStretch = supportsTimeStretch
        self.faults = faults
        prepareCalls = try BoundedRecorder(capacity: callCapacity)
    }

    /// `unprepared`/`invalidated`/`failed → preparing → ready` against
    /// `requirements`, or against the fixture's current requirements when nil.
    mutating func prepare(
        _ action: ActionID,
        policy: ActionPolicy?,
        against requirements: [GenerationRequirement]? = nil,
        in fixture: inout ReadinessFixture
    ) throws(FakeProcessorError) {
        _ = prepareCalls.record(action)
        do {
            try faults.nextCall()
        } catch {
            if error == .prepareFailed { try recordFailure(action, in: &fixture) }
            throw .fault(error)
        }

        var readiness = fixture.readiness
        let requirements = requirements ?? fixture.requirements(for: action)
        do throws(ReadinessError) {
            try readiness.transition(action, to: .preparing)
            try readiness.markReady(action, preparedAgainst: requirements, ledger: fixture.ledger,
                                    policy: policy, supportsTimeStretch: supportsTimeStretch)
        } catch {
            if error == .timeStretchUnavailable { fixture.readiness = readiness }
            throw .readiness(error)
        }
        fixture.readiness = readiness
    }

    /// `preparing → failed(preparationFailed)` on a copy, kept only if both moves are legal.
    private func recordFailure(_ action: ActionID, in fixture: inout ReadinessFixture) throws(FakeProcessorError) {
        var readiness = fixture.readiness
        do throws(ReadinessError) {
            try readiness.transition(action, to: .preparing)
            try readiness.transition(action, to: .failed, reason: .preparationFailed)
        } catch {
            throw .readiness(error)
        }
        fixture.readiness = readiness
    }
}
