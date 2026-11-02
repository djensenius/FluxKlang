// #64 handoff policy: every realtime kernel queue declares its producer and consumer cardinality, capacity,
// ordering, deadline horizon, overflow and lifetime. Validation is control-side only, uses typed throws and
// never traps. Reference model; not RT-certified.

/// Fixed bounds shared by every kernel handoff.
enum KernelLimits {
    /// Largest capacity, in elements, any single handoff may declare (inclusive).
    static let maximumCapacity = 65_536
    /// Largest number of concurrent producers any single handoff may declare (inclusive).
    static let maximumProducers = 64
    /// Producer count assumed for callbacks whose concurrency is unverified (MIDI receive, AU host, worker).
    static let defaultFanInProducers = 64
    /// Largest lookahead, in frames, any deadline horizon may declare (inclusive); about 5.8 min at 48 kHz.
    static let maximumHorizonFrames: Int64 = 1 << 24
    /// Smallest default reservation for note-release and safety traffic.
    static let minimumCriticalReserve = 16
    /// The default reservation is `capacity / criticalReserveDivisor`, but never below the minimum.
    static let criticalReserveDivisor = 8
}

/// The thread or callback context that produces into or consumes from a handoff.
enum ExecutionContext: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case render, control
    // swiftlint:disable:next identifier_name
    case ui
    case midiReceive, auHost, worker

    /// MIDI receive and AU host callbacks are owned by the OS or a host, not by the app.
    var isExternallyOwned: Bool { self == .midiReceive || self == .auHost }
}

/// How the declared producer count is known.
enum CardinalityEvidence: Sendable, Equatable, CaseIterable {
    /// Measured or documented for this context (for example by #81 or #65).
    case verified
    /// The app owns and serialises the producing context.
    case appOwned
    /// Not known; the declaration must assume concurrent producers.
    case assumedConservative
}

struct ProducerCardinality: Sendable, Equatable {
    let maximum: Int
    let evidence: CardinalityEvidence

    /// MIDI receive, AU host and worker producers default to the widest fan-in because their concurrency is
    /// unverified; the app's own render, control and UI contexts default to one app-owned producer.
    static func conservativeDefault(for context: ExecutionContext) -> ProducerCardinality {
        switch context {
        case .midiReceive, .auHost, .worker:
            ProducerCardinality(maximum: KernelLimits.defaultFanInProducers, evidence: .assumedConservative)
        case .render, .control, .ui:
            ProducerCardinality(maximum: 1, evidence: .appOwned)
        }
    }
}

enum HandoffPurpose: Sendable, Equatable, CaseIterable {
    case events, telemetry, sysex, faults, retire
}

enum HandoffOrdering: Sendable, Equatable {
    case fifo, fifoPerProducer, latestOnly, completeMessagesFIFO
}

/// Frames are at the prepared sample rate.
enum DeadlineHorizon: Sendable, Equatable {
    case none
    case frames(lateTolerance: Int64, lookahead: Int64)
}

enum OverflowPolicy: Sendable, Equatable {
    case refuseProducer
    case reservedCritical(reserved: Int)
    case overwriteLatest

    /// The default note-release and safety reservation: one eighth of `capacity`, at least
    /// `KernelLimits.minimumCriticalReserve`, always leaving general room. `nil` when `capacity` is out of
    /// range or too small to hold the minimum reservation plus one general slot.
    static func defaultCriticalReserve(capacity: Int) -> OverflowPolicy? {
        guard capacity > KernelLimits.minimumCriticalReserve, capacity <= KernelLimits.maximumCapacity else {
            return nil
        }
        return .reservedCritical(
            reserved: max(capacity / KernelLimits.criticalReserveDivisor, KernelLimits.minimumCriticalReserve))
    }
}

enum HandoffLifetime: Sendable, Equatable {
    case preparedPlan, session, process
}

enum HandoffPolicyRule: Sendable, Equatable {
    case r1SingleConsumer, r2Cardinality, r3Capacity, r4LatestOnly
    /// Telemetry never drains on render; render drains only events; retirements drain only on control.
    case r5TelemetryNotRender
    /// Deadline horizon: render-consumed events declare frames, and every declared horizon is bounded.
    case r6RenderDeadline
    /// Structural only (`1..<capacity`); the note-carrying minimum is enforced by M4 and the X1 catalog.
    case r7Reserve
    /// SysEx is complete-message and refusing, and complete-message ordering is SysEx-only.
    case r8SysExSeparate
}

enum HandoffPolicyError: Error, Equatable, Sendable {
    case violates(HandoffPolicyRule)
}

struct HandoffPolicy: Sendable, Equatable {
    let purpose: HandoffPurpose
    let producer: ExecutionContext
    let producers: ProducerCardinality
    let consumer: ExecutionContext
    /// Declared explicitly so a shared drain is visible; must be 1.
    let consumers: Int
    let capacity: Int
    let ordering: HandoffOrdering
    let deadline: DeadlineHorizon
    let overflow: OverflowPolicy
    let lifetime: HandoffLifetime

    /// Checks rules R1–R8 in order and throws the first violation. Control-side only.
    func validate() throws(HandoffPolicyError) {
        guard consumers == 1 else { throw .violates(.r1SingleConsumer) }
        guard validCardinality else { throw .violates(.r2Cardinality) }
        guard capacity >= 1, capacity <= KernelLimits.maximumCapacity else { throw .violates(.r3Capacity) }
        let telemetry = purpose == .telemetry
        guard (ordering == .latestOnly) == telemetry, (overflow == .overwriteLatest) == telemetry else {
            throw .violates(.r4LatestOnly)
        }
        guard validDrain else { throw .violates(.r5TelemetryNotRender) }
        guard validDeadline else { throw .violates(.r6RenderDeadline) }
        // R7 is structural; the note-carrying minimum (`minimumCriticalReserve`) is enforced in M4 and X1.
        if case .reservedCritical(let reserved) = overflow, reserved < 1 || reserved >= capacity {
            throw .violates(.r7Reserve)
        }
        let sysex = purpose == .sysex
        guard (ordering == .completeMessagesFIFO) == sysex, !sysex || overflow == .refuseProducer else {
            throw .violates(.r8SysExSeparate)
        }
    }

    /// R2: a bounded producer count; one producer only with verified or app-owned evidence; externally owned
    /// callbacks can never claim app-owned evidence.
    private var validCardinality: Bool {
        guard producers.maximum >= 1, producers.maximum <= KernelLimits.maximumProducers else { return false }
        if producer.isExternallyOwned, producers.evidence == .appOwned { return false }
        return producers.maximum > 1 || producers.evidence != .assumedConservative
    }

    /// R5: telemetry flows from render to UI or control; render drains only events; retirements drain only on
    /// control, so deferred `deinit` runs only during control-side reclaim.
    private var validDrain: Bool {
        if purpose == .telemetry, producer != .render || (consumer != .ui && consumer != .control) { return false }
        if purpose == .retire, consumer != .control { return false }
        return consumer != .render || purpose == .events
    }

    /// R6: render-consumed events declare a frame horizon; any declared horizon satisfies
    /// `0 <= lateTolerance <= lookahead` and `0 < lookahead <= KernelLimits.maximumHorizonFrames`.
    private var validDeadline: Bool {
        switch deadline {
        case .none:
            !(purpose == .events && consumer == .render)
        case .frames(let lateTolerance, let lookahead):
            lateTolerance >= 0 && lateTolerance <= lookahead && lookahead > 0
                && lookahead <= KernelLimits.maximumHorizonFrames
        }
    }
}
