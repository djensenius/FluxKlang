//
//  OpenSoundControl+SchedulingRefusal.swift
//  FluxKlang
//
//  Every typed refusal of the pure OSC time-tag scheduling model (#90). A
//  refused call changes nothing: not the scheduler, its counters or its input.
//

extension OpenSoundControl {
    /// The bounded quantity a capacity refusal names.
    enum SchedulingCapacity: Sendable, Hashable {
        case pendingBatches
        case pendingMessages
    }

    enum SchedulingRefusal: Error, Sendable, Hashable {
        // Configuration.
        case invalidTimebase(numer: UInt32, denom: UInt32)
        case eraOutOfRange(Int)
        case rateOutOfRange(partsPerBillion: Int)
        case rateUncertaintyOutOfRange(partsPerBillion: Int)
        case uncertaintyOutOfRange(nanoseconds: UInt64)
        case invalidCapacity(SchedulingCapacity, Int)
        /// The future horizon exceeds `SchedulingPolicy.futureHorizonLimitNanoseconds`.
        case futureHorizonOutOfRange(nanoseconds: UInt64)
        case invalidBundleDepth(Int)
        case invalidAllowList(count: Int)

        // Packets; the first refusal in planning order refuses the whole packet.
        /// Raw 0: NTP's "unknown time", never a schedulable instant.
        case reservedTimeTag(TimeTag)
        /// A non-immediate tag reached the immediate stage, which never schedules.
        case unsupportedScheduling(TimeTag)
        /// OSC 1.0: an enclosed bundle's time must not precede its enclosing bundle's.
        case nestedTimeTagEarlier(enclosing: TimeTag, inner: TimeTag)
        case bundleTooDeep(limit: Int)
        /// More than `SchedulingPolicy.maximumPacketElements` bundle elements, at any depth.
        case tooManyElements(limit: Int)
        /// Incoming patterns cannot be proven to address only allowed methods.
        case wildcardAddress(String)
        case disallowedAddress(String)
        /// The whole host window precedes `now - lateHorizon`.
        case tooLate(TimeTag)
        /// The host window starts after `now + maximumFuture`.
        case tooFarInFuture(TimeTag)
        /// No tick of the window is expressible in unsigned 64-bit host ticks.
        case hostTimeOutOfRange(TimeTag)
        case arithmeticOverflow
        case capacityExceeded(SchedulingCapacity, limit: Int)

        // Scheduler state.
        /// Unknown, already dispatched, cancelled or refused: IDs are never reused.
        case batchNotPending(BatchID)
        /// Injected host time must never run backwards.
        case nowRegressed(previous: HostStamp, now: HostStamp)
    }
}
