// #109 IO3: the one typed refusal of the capture tap plan and its claim table. Pure Swift; no clock, no ring.

/// Why a tap id, consumer spec, tap plan or claim operation was refused. A refused operation changes nothing.
enum MediaTapRefusal: Error, Equatable, Sendable {
    /// A tap id below 1.
    case invalidTap(Int)
    /// The consumer context is not one this role may drain from (`MediaTapRole.accepts(_:)`).
    case invalidContext(MediaTapRole)
    /// The capacity, in blocks, is outside the role's range (`MediaTapRole.minimumCapacityBlocks` through
    /// `KernelLimits.maximumCapacity`).
    case invalidCapacity(MediaTapRole, Int)
    /// A plan needs at least one consumer.
    case emptyPlan
    /// A role appears more than once in one plan: a second consumer of a role is refused, never merged onto one ring.
    case duplicateRole(MediaTapRole)
    /// The role's handoff policy failed `HandoffPolicy.validate()`.
    case policy(MediaTapRole, HandoffPolicyError)
    /// A claim on a new tap would make the table hold this many distinct taps, above `MediaTapClaims.maximumTaps`.
    case tooManyTaps(Int)
    /// The role already holds a claim on this tap.
    case alreadyClaimed(MediaTapID, MediaTapRole)
    /// The role holds no claim on this tap (the tap may be unknown to the table).
    case notClaimed(MediaTapID, MediaTapRole)
}
