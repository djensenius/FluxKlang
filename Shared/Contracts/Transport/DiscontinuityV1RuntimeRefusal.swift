//
//  DiscontinuityV1RuntimeRefusal.swift
//  FluxKlang
//
//  Why a `RuntimeDiscontinuity` cannot become a contract v1 `discontinuityRecord` (#109, #110). In memory
//  only; nothing is clamped, remapped or serialized in its place.
//

/// The first offence `DiscontinuityV1Record.make(_:preparation:sampleClock:stream:seq:note:)` finds, in this
/// order: the sample clock, the generation, the stream, `frames`, the host, then the record's own checks.
enum DiscontinuityV1RuntimeRefusal: Error, Hashable, Sendable {
    /// 1. The preparation does not map the caller's clock as a sample clock.
    case sampleClockNotMapped(ClockID)
    /// 1. The caller's clock maps to a different slot than the discontinuity's sample stamp carries.
    case sampleClockSlotMismatch(runtime: UInt32, mapped: UInt32)
    /// 2. The stamp's generation is outside `Generation`'s range, 1...2^53 - 1.
    case generationOutOfRange(UInt64)
    /// 3. The discontinuity has a stream slot but the caller passed no stream name.
    case streamNameMissing(slot: UInt32)
    /// 3. The caller passed a stream name but the discontinuity has no stream slot.
    case streamSlotMissing(StreamID)
    /// 3. The kind (its `type` string) records a stream and the discontinuity has no stream slot.
    case streamRequired(type: String)
    /// 3. The preparation does not declare the stream in a direction the kind accepts.
    case streamNotDeclared(StreamID)
    /// 3. The stream's slot in the preparation is not the slot the discontinuity carries.
    case streamSlotMismatch(StreamID, runtime: UInt32, mapped: UInt32)
    /// 4. An `underrun` or `overflow` (its `type` string) has no frame count.
    case framesMissing(type: String)
    /// 4. A kind that carries no frames (its `type` string) has a frame count.
    case framesUnexpected(type: String, frames: UInt32)
    /// 5. A `clockRestart` has no host stamp.
    case hostMissing
    /// 6. The record's own refusal (`seq`, clock ID, stream ID, `frames` range, note), payload intact.
    case record(DiscontinuityV1RecordRefusal)
}
