//
//  MediaBlockLease.swift
//  FluxKlang
//
//  The value that identifies one leased block of one media block pool
//  (#109 IO1, media-contract.md §8.2). A lease grants nothing by itself: every
//  pool operation re-validates it, so a released, stale, retired or foreign
//  lease is refused and never reaches storage.
//

/// A small value that identifies one leased block of one `MediaBlockPool`.
///
/// It carries the issuing pool's identity token, the block's slot index and the slot generation current when the
/// lease was issued. It cannot be forged: its initialiser needs a `MediaBlockPoolIdentity`, and only the pool can
/// create one. The lease holds its pool's identity token, so it is a reference-counted value (not
/// `BitwiseCopyable`); a lease is only meaningful to the pool that issued it.
struct MediaBlockLease: Hashable, Sendable {
    /// The block's index in its pool, `0..<blockCount`.
    let slot: Int
    /// The slot generation this lease was issued at; a later lease of the same block has a higher one.
    let generation: UInt32
    private let identity: MediaBlockPoolIdentity

    /// Callable only by a holder of a `MediaBlockPoolIdentity`, which only `MediaBlockPool` can create.
    init(identity: MediaBlockPoolIdentity, slot: Int, generation: UInt32) {
        self.identity = identity
        self.slot = slot
        self.generation = generation
    }

    /// Whether `issuer` is the identity token of the pool that issued this lease.
    func wasIssued(by issuer: MediaBlockPoolIdentity) -> Bool {
        identity === issuer
    }
}

/// What `MediaBlockPool.release(_:)` did with the block.
enum MediaBlockReleaseOutcome: Equatable, Sendable {
    /// The block is free again and a later lease will receive it.
    case returned
    /// The block's slot generation had reached the pool's maximum, so it was permanently withdrawn instead.
    case retired
}
