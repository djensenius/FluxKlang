// #64 X1 catalog: typed refusals. Control-side only; not RT-certified.

/// Why a note-carrying queue lacks the reserve a note release needs.
enum NoteReserveDefect: Sendable, Equatable {
    /// Only an events queue may carry notes.
    case notAnEventsQueue
    /// The overflow policy is not `.reservedCritical`.
    case reserveMissing
    /// The reserve (per producer lane when fanned in) is below `KernelLimits.minimumCriticalReserve`.
    case reserveBelowMinimum(Int)
    /// More than one producer, but the ordering is not `.fifoPerProducer`.
    case multiProducerNeedsPerProducerLanes
    /// The capacity or the reserve is not a multiple of the producer count.
    case lanesDoNotDivide
}

/// The first defect found by `KernelQueueCatalog.make`. Indices are positions in the declared list.
enum KernelQueueCatalogRefusal: Error, Equatable, Sendable {
    case invalidByteBudget(Int)
    case tooManyQueues(Int)
    case invalidName(index: Int)
    case invalidElementStride(index: Int, stride: Int)
    case policy(index: Int, HandoffPolicyError)
    case noteReserve(index: Int, NoteReserveDefect)
    case queueBytesOverflow(index: Int)
    case duplicateName(index: Int)
    case totalBytesOverflow(index: Int)
    case overBudget(totalBytes: Int, byteBudget: Int)
}
