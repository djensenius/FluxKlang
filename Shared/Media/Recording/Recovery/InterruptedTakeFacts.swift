//
//  InterruptedTakeFacts.swift
//  FluxKlang
//
//  What a crash left behind for one take, as input to the salvage planner.
//

/// The planner's input for one interrupted take. This is a planner-input contract only: it is not the on-disk
/// journal format, and a later journal reader may map onto it. It is a plain carrier; `InterruptedTakeSalvage.plan`
/// validates it.
struct InterruptedTakeFacts: Equatable, Sendable {
    /// The journaled segments in file order. Each is already validated by its own initializer.
    let segments: [RecordingSegment]
    /// Frames durably present in the take's file, counted from its first frame.
    let durableFileFrames: Int64
    /// Whether the container's header was written as final before the interruption.
    let containerFinalized: Bool
}
