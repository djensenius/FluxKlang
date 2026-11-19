/// Sole noncopyable, non-Sendable owner of inheritance-independent execution components.
///
/// Module-internal only for candidate -> cycle movement across files; neither exposes this owner.
/// Pending/extracted storage is control-only. Ready storage is private to the cycle, under its existing
/// render/control contracts. Preparation follows validation and acknowledgement issuance, but precedes claim:
/// it retains shared references and reads immutable dimensions, never their mutable execution state.
/// No inheritance, fault raising, event drain, telemetry publication or second installation occurs here.
///
/// Moving this work earlier increases pending retention: ramp offsets up to 512 KiB, takeover bits up to
/// 64 KiB, plus watermark, refusal counters, telemetry and object overhead. Aggregate pending retention is
/// unbounded. This is not allocation-free binding, retirement-gap reduction or realtime qualification.
struct KernelCycleExecutionStorage: ~Copyable {
    let watermark: KernelFlushWatermark
    let decider: KernelBlockDecider
    let admissionRefusals: KernelAdmissionRefusals
    private let counters: UnsafeMutablePointer<KernelCycleTelemetry>

    /// No failable work after validation/issuance; the default table allocates counters, not caller identities
    /// or fault chains. The supplied table is retained unchanged, including any producer progress.
    init(parts: KernelCycleParts, deadline: DeadlinePolicy, pulses: ClockPulseGate, ackRequests: KernelAckRequests) {
        watermark = KernelFlushWatermark(laneCount: parts.events.laneCount, armed: parts.start == .replacingCycle)
        decider = KernelBlockDecider(deadline: deadline, ownership: parts.ownership, ramps: parts.ramps,
                                     pulses: pulses, takeover: parts.start == .replacingCycle)
        admissionRefusals = parts.admissionRefusals ?? KernelAdmissionRefusals(laneCount: parts.events.laneCount,
                                                                               handoff: parts.events.identity)
        counters = .allocate(capacity: 1)
        counters.initialize(to: KernelCycleTelemetry(ackCycle: ackRequests.identity))
    }

    /// Render only after readiness. Returns a value, never an owning pointer or cleanup capability.
    var telemetry: KernelCycleTelemetry {
        get { counters.pointee }
        nonmutating set { counters.pointee = newValue }
    }

    /// Synchronous control teardown for pending cancellation/abandonment, failed claim or final ready release.
    /// Components release their own private backing through their existing destructors. Telemetry is
    /// BitwiseCopyable; readmission's separate exact initialized-prefix destructor is unchanged.
    deinit { counters.deallocate() }
}
