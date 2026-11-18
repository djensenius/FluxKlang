import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

/// One `emit` call: the event and the frame it was dispatched at.
struct CycleEmission: Equatable {
    let event: KernelEvent
    let frame: Int64
}

/// A `KernelCycle` over a fan-in, its latch and two ownership/safety scopes. Shared with
/// `RealtimeHandoffTests+KernelCycleStress.swift`.
struct CycleRig {
    static let criticalScope = FaultScope(handoff: 64, target: 5)
    static let slotsScope = FaultScope(handoff: 64, target: 6)
    /// A neighbouring scope on the same latch, as a SysEx assembler would use.
    static let sysexScope = FaultScope(handoff: 65, target: 0)

    let faults: FaultChainAuthority
    let claims: FaultChainAuthority
    let events: FanInHandoff<KernelEvent>
    let ownership: NoteOwnership
    let safety: SafetyFlags
    let ramps: RampSlots
    let cycle: KernelCycle

    init(lanes: Int = 2, laneCapacity: Int = 20, blockCapacity: Int = 64, pulsesPerBlock: Int = 4,
         staleTolerance: Int64 = 48, perLaneQuota: Int = 64, telemetry: KernelCycleTelemetryOutput? = nil) throws {
        faults = try FaultChainAuthority.testing(scopes: [Self.criticalScope, Self.slotsScope, Self.sysexScope])
        claims = try FaultChainAuthority(scopes: [Self.slotsScope], chainBudget: 1)
        events = try FanInHandoff(policy: Self.policy(lanes: lanes, laneCapacity: laneCapacity),
                                  laneCapacity: laneCapacity, reserved: 16, faults: faults, claimFaults: claims,
                                  criticalScope: Self.criticalScope, producerSlotsScope: Self.slotsScope)
        ownership = try NoteOwnership(scopes: 2)
        safety = try SafetyFlags(scopes: 2)
        ramps = try RampSlots(parameterCount: 4)
        let parts = KernelCycleParts(events: events, faults: faults, ownership: ownership, safety: safety,
                                     ramps: ramps, telemetry: telemetry, start: .freshFanIn)
        cycle = try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: pulsesPerBlock,
                                                              staleTolerance: staleTolerance),
                                blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
    }

    /// A MIDI-receive fan-in to render with a 480-frame tolerance and a 96,000-frame lookahead.
    static func policy(lanes: Int = 2, laneCapacity: Int = 20, consumer: ExecutionContext = .render) -> HandoffPolicy {
        Root.policy(producer: .midiReceive,
                    producers: ProducerCardinality(maximum: lanes,
                                                   evidence: lanes == 1 ? .verified : .assumedConservative),
                    consumer: consumer, capacity: laneCapacity &* lanes, ordering: .fifoPerProducer,
                    overflow: .reservedCritical(reserved: 16 &* lanes))
    }

    func push(_ event: KernelEvent, _ token: ProducerToken, caller: inout RefusalCallerToken) -> KernelStatus {
        events.tryPush(event, class: event.eventClass, frame: event.frame, token: token, caller: &caller)
    }

    /// Runs one cycle and returns its result with everything it emitted.
    func run(_ blockStart: Int64, _ frames: Int64) -> (KernelCycleResult, [CycleEmission]) {
        var emitted: [CycleEmission] = []
        let result = cycle.run(blockStart: blockStart, frames: frames) {
            emitted.append(CycleEmission(event: $0, frame: $1))
        }
        return (result, emitted)
    }
}

/// An event at `frame` with `payload`.
func cycleEvent(_ frame: Int64, _ payload: KernelEventPayload, scope: UInt32 = 0, sequence: UInt64 = 0) -> KernelEvent {
    KernelEvent(frame: frame, scope: scope, sequence: sequence, payload: payload)
}

/// Render → control telemetry slots for one `KernelCycle`. Shared with
/// `RealtimeHandoffTests+KernelCycleOrderingStress.swift`.
func kernelCycleTelemetrySlots() throws -> TelemetrySlots<KernelCycleTelemetry> {
    try TelemetrySlots(policy: Root.policy(purpose: .telemetry, producer: .render, consumer: .control, capacity: 2,
                                           ordering: .latestOnly, deadline: .none, overflow: .overwriteLatest),
                       slotCount: 2)
}
