//
//  TakeSalvagePlan.swift
//  FluxKlang
//
//  What can truthfully be kept of an interrupted take.
//

/// How much of the take survived.
enum TakeSalvageVerdict: Hashable, Sendable {
    /// Every journaled frame is durable and the container was finalized.
    case intact
    /// Every journaled frame is durable but the container was never finalized.
    case headerRepairOnly
    /// The file holds fewer frames than the journal promises; the plan keeps the durable part.
    case trimmed
    /// No journaled frame is durable (or nothing was journaled).
    case nothingDurable
}

/// A deterministic plan for an interrupted take. It never invents a stop reason, never invents or recomputes a
/// segment's placement, and never keeps a frame the file does not hold.
struct TakeSalvagePlan: Equatable, Sendable {
    let verdict: TakeSalvageVerdict
    /// Journaled segments that are durable, in file order. The one the interruption cut through is clipped.
    let keptSegments: [RecordingSegment]
    /// Journaled frames the file does not hold.
    let lostJournaledFrames: Int64
    /// Frames in the file after the journal's last frame. Reported only; never kept.
    let untrackedTailFrames: Int64
    let needsHeaderRepair: Bool
    /// The plan's own marker that the take did not end cleanly: false only when every journaled frame is durable and
    /// the container was finalized. It is not a stop reason.
    let interrupted: Bool
}
