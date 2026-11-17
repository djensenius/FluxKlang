//
//  MIDIPacketDelivery.swift
//  FluxKlang
//

import Synchronization

/// One delivered batch: the raw bytes of each packet, in order. `afterGap` marks the first batch accepted after the
/// delivery dropped one or more batches, so framing must not carry into it.
struct MIDIPacketBatch: Equatable, Sendable {
    var packets: [[UInt8]]
    var afterGap = false
}

/// One input start's ordered path from the MIDI read thread to the main actor: a bounded `AsyncStream` with a
/// single consumer task that calls `handler` for each batch, in the order `yield` accepted them. Ordering does not
/// depend on how the main actor schedules separate jobs, because there is only one job. Each `yield` runs under one
/// lock, so accepted and dropped batches have a single order even when yields overlap, and the first batch accepted
/// after any drop is the one marked `afterGap`.
@MainActor
final class MIDIPacketDelivery {
    /// Batches accepted but not yet handled. Past it, `.bufferingOldest` keeps arrival order and drops the newest
    /// batch whole; the first batch accepted after one or more drops, in `yield`'s locked order, is marked
    /// `afterGap`.
    static let defaultMaximumPendingBatches = 1_024

    nonisolated private let continuation: AsyncStream<MIDIPacketBatch>.Continuation
    /// True after a dropped batch until a batch is accepted. Its lock is held across each whole `yield`.
    nonisolated private let gapPending = Mutex<Bool>(false)
    /// Test seam, nil in production: called inside `yield`'s lock with the marked batch, before it is offered.
    nonisolated private let willYield: (@Sendable (MIDIPacketBatch) -> Void)?
    private var consumer: Task<Void, Never>?
    private var isCancelled = false

    init(
        maximumPendingBatches: Int = defaultMaximumPendingBatches,
        willYield: (@Sendable (MIDIPacketBatch) -> Void)? = nil,
        handler: @escaping @MainActor (MIDIPacketBatch) -> Void
    ) {
        let (batches, continuation) = AsyncStream.makeStream(
            of: MIDIPacketBatch.self, bufferingPolicy: .bufferingOldest(maximumPendingBatches)
        )
        self.continuation = continuation
        self.willYield = willYield
        consumer = Task { @MainActor [weak self] in
            for await batch in batches {
                guard let self, !self.isCancelled else { return }
                handler(batch)
            }
        }
    }

    /// A dropped delivery ends its input, so the consumer task finishes instead of waiting forever.
    deinit {
        continuation.finish()
    }

    /// Safe from any thread, also concurrently; the caller passes copied bytes. False when the batch was dropped
    /// (buffer full) or the delivery has ended. A gap is cleared only by a batch that is enqueued, so it is never lost.
    /// Reading the flag, offering the batch and updating the flag share one lock, so an overlapping yield cannot
    /// overtake a post-gap batch unmarked. CoreMIDI's one read thread, not the render thread, keeps it uncontended.
    /// No lock-order inversion: `continuation.yield` takes only the stream's internal lock, and nothing takes this
    /// lock while holding that one.
    @discardableResult
    nonisolated func yield(_ packets: [[UInt8]]) -> Bool {
        gapPending.withLock { pending in
            let batch = MIDIPacketBatch(packets: packets, afterGap: pending)
            willYield?(batch)
            guard case .enqueued = continuation.yield(batch) else {
                pending = true
                return false
            }
            pending = false
            return true
        }
    }

    /// Once this returns, `handler` is never called again, even for batches already accepted.
    func cancel() {
        isCancelled = true
        continuation.finish()
    }

    /// Ends the input and returns once every accepted batch has been handled (or skipped after `cancel()`).
    func finish() async {
        continuation.finish()
        await consumer?.value
    }
}
