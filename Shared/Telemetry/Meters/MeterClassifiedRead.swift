//
//  MeterClassifiedRead.swift
//  FluxKlang
//
//  The only read the truthful meter model accepts (#102 M1): a tap read that
//  has been through the kernel's render-stamp staleness rule, carrying the
//  injected host time it was classified at. A raw `TelemetrySlots.latest(slot:)`
//  read can hold a long-dead sample, so it never reaches a meter unclassified,
//  and a classified read consumed late is aged from its classification time.
//

/// A tap read classified by `TelemetrySlots.classify` (D5) against the caller's clock generation and render frame,
/// at an injected host time.
///
/// The only way to build one is `classify(_:generation:frame:maximumAgeFrames:at:)`. It maps the kernel's rule
/// exactly: a sample from another clock generation becomes `.unavailable(.staleGeneration)`, and one older than
/// `maximumAgeFrames` (or whose age overflows) becomes `.unavailable(.tooOld)`. A sample that has sat in its slot
/// since long before the meter first looked is therefore never shown as live. The classification only holds at the
/// host time it was made, so `MeterDisplayModel` measures host-time staleness from `classifiedAt`, not from when it
/// consumes the read: a read held back past the staleness window is stale in any model, including a new or rebound
/// one. Reads need not be consumed in classification order: a read from another clock generation classified before
/// a channel's latest sample was first classified, or a read of an earlier frame or older sequence in the same
/// generation, is ignored and counted (see the ordering contract on `MeterChannelState`). Across generations,
/// `classifiedAt` is the only order, so every read must be classified with one monotonic host clock.
struct MeterClassifiedRead: Equatable, Sendable {
    /// 1 frame through 2^24 frames inclusive (about 5.8 min at 48 kHz, 43.7 s at 384 kHz). Zero, negative and
    /// longer frame-age rules are refused: they would show nothing or let a long-dead sample through.
    static let allowedMaximumAgeFrames: ClosedRange<Int64> = 1...(1 << 24)

    /// The kernel's classification: the sample, or why there is none to show.
    let read: TelemetryRead<MeterTapValue>
    /// The injected host time the read was classified at. `MeterDisplayModel` refuses a read classified after the
    /// update that consumes it.
    let classifiedAt: MeterInstant

    private init(read: TelemetryRead<MeterTapValue>, classifiedAt: MeterInstant) {
        self.read = read
        self.classifiedAt = classifiedAt
    }

    /// Classifies `read` (normally `TelemetrySlots.latest(slot:)`) with the kernel's staleness rule. `generation`
    /// and `frame` are the render clock generation and frame the caller reads from the kernel, and `classifiedAt`
    /// is the host time of that reading, on the same clock as `MeterDisplayModel.update(_:at:)`; `.unavailable`
    /// reads pass through unchanged. A time from another clock that happens to be at or before the update's `now`
    /// cannot be detected; only one after it is refused. The frame-age rule is checked first, so a refusal
    /// classifies nothing.
    static func classify(_ read: TelemetryRead<MeterTapValue>, generation: UInt64, frame: Int64,
                         maximumAgeFrames: Int64,
                         at classifiedAt: MeterInstant) throws(MeterDisplayRefusal) -> MeterClassifiedRead {
        guard allowedMaximumAgeFrames.contains(maximumAgeFrames) else {
            throw .maximumAgeFramesOutOfRange(maximumAgeFrames)
        }
        let classified = TelemetrySlots<MeterTapValue>.classify(read, generation: generation, frame: frame,
                                                                 maximumAgeFrames: maximumAgeFrames)
        return MeterClassifiedRead(read: classified, classifiedAt: classifiedAt)
    }
}
