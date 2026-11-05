//
//  MeterClassifiedRead.swift
//  FluxKlang
//
//  The only read the truthful meter model accepts (#102 M1): a tap read that
//  has been through the kernel's render-stamp staleness rule. A raw
//  `TelemetrySlots.latest(slot:)` read can hold a long-dead sample, so it
//  never reaches a meter unclassified.
//

/// A tap read classified by `TelemetrySlots.classify` (D5) against the caller's clock generation and render frame.
///
/// The only way to build one is `classify(_:generation:frame:maximumAgeFrames:)`. It maps the kernel's rule
/// exactly: a sample from another clock generation becomes `.unavailable(.staleGeneration)`, and one older than
/// `maximumAgeFrames` (or whose age overflows) becomes `.unavailable(.tooOld)`. A sample that has sat in its slot
/// since long before the meter first looked is therefore never shown as live. Host-time staleness in
/// `MeterDisplayModel` is layered on top and catches a producer that stalls after the meter has seen its sample.
struct MeterClassifiedRead: Equatable, Sendable {
    /// 1 frame through 2^24 frames inclusive (about 5.8 min at 48 kHz, 43.7 s at 384 kHz). Zero, negative and
    /// longer frame-age rules are refused: they would show nothing or let a long-dead sample through.
    static let allowedMaximumAgeFrames: ClosedRange<Int64> = 1...(1 << 24)

    /// The kernel's classification: the sample, or why there is none to show.
    let read: TelemetryRead<MeterTapValue>

    private init(read: TelemetryRead<MeterTapValue>) {
        self.read = read
    }

    /// Classifies `read` (normally `TelemetrySlots.latest(slot:)`) with the kernel's staleness rule. `generation`
    /// and `frame` are the render clock generation and frame the caller reads from the kernel; `.unavailable`
    /// reads pass through unchanged. The frame-age rule is checked first, so a refusal classifies nothing.
    static func classify(_ read: TelemetryRead<MeterTapValue>, generation: UInt64, frame: Int64,
                         maximumAgeFrames: Int64) throws(MeterDisplayRefusal) -> MeterClassifiedRead {
        guard allowedMaximumAgeFrames.contains(maximumAgeFrames) else {
            throw .maximumAgeFramesOutOfRange(maximumAgeFrames)
        }
        return MeterClassifiedRead(read: TelemetrySlots<MeterTapValue>.classify(
            read, generation: generation, frame: frame, maximumAgeFrames: maximumAgeFrames))
    }
}
