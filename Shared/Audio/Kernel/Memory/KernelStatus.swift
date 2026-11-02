// #64 realtime kernel status vocabulary. Hot-path operations return these fixed-size values instead of
// throwing, trapping or unwinding. Reference model; not RT-certified.

/// Why a hot-path operation declined to accept or deliver a value.
enum KernelRefusal: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case full, criticalExhausted, notOwner, slotOutOfRange, beyondLookahead, nonMonotonic, invalidLength
}

/// Why a render cycle produced silence rather than its prepared output.
enum SilenceReason: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case noPlan, scopeFaulted, safetyMute, scratchExhausted
}

/// The explicit result of a hot-path operation.
enum KernelStatus: Equatable, Sendable, BitwiseCopyable {
    // swiftlint:disable:next identifier_name
    case ok
    case empty
    case refused(KernelRefusal)
    case silenced(SilenceReason)
}
