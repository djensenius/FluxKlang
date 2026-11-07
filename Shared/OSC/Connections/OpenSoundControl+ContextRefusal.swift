//
//  OpenSoundControl+ContextRefusal.swift
//  FluxKlang
//
//  The typed refusals of the context-tagged scheduler (#89, O2c).
//

extension OpenSoundControl {
    /// Why `ContextScheduler` refused. A refused `init` builds nothing; a refused `admit`, `cancel(_:)` or `due`
    /// leaves the whole wrapper equal to before.
    enum ContextRefusal: Error, Sendable, Hashable {
        /// `maximumContexts` is outside 1 through `EndpointPolicy.peerLimit`.
        case invalidContextLimit(Int)
        /// The scheduler given to `init` already holds batches the wrapper could not tag.
        case schedulerNotEmpty(pending: Int)
        /// The packet's context holds no queued batch and the table already holds `limit` contexts.
        case contextTableFull(limit: Int)
        /// The wrapped scheduler refused; its refusal is carried as it is.
        case scheduling(SchedulingRefusal)
        /// The scheduler released a batch the wrapper holds no tag for. Not exercised by any test: the invariants
        /// documented on `ContextScheduler` keep the tags equal to the queued batches, and `due` answers this way,
        /// changing nothing, if they were ever wrong.
        case untaggedBatch(BatchID)
    }
}
