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
/// depend on how the main actor schedules separate jobs, because there is only one job.
@MainActor
final class MIDIPacketDelivery {
    /// Batches accepted but not yet handled. Past it, `.bufferingOldest` keeps arrival order and drops the newest
    /// batch whole; the next batch accepted after a drop is marked `afterGap`.
    static let defaultMaximumPendingBatches = 1_024

    nonisolated private let continuation: AsyncStream<MIDIPacketBatch>.Continuation
    /// Set by a dropped batch and taken by the next batch `yield` accepts.
    nonisolated private let gapPending = Atomic<Bool>(false)
    private var consumer: Task<Void, Never>?
    private var isCancelled = false

    init(
        maximumPendingBatches: Int = defaultMaximumPendingBatches,
        handler: @escaping @MainActor (MIDIPacketBatch) -> Void
    ) {
        let (batches, continuation) = AsyncStream.makeStream(
            of: MIDIPacketBatch.self, bufferingPolicy: .bufferingOldest(maximumPendingBatches)
        )
        self.continuation = continuation
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

    /// Safe from any thread; the caller passes copied bytes. False when the batch was dropped (buffer full) or the
    /// delivery has ended. A gap is cleared only by a batch that is enqueued, so it is never lost.
    @discardableResult
    nonisolated func yield(_ packets: [[UInt8]]) -> Bool {
        let afterGap = gapPending.exchange(false, ordering: .acquiringAndReleasing)
        if case .enqueued = continuation.yield(MIDIPacketBatch(packets: packets, afterGap: afterGap)) { return true }
        gapPending.store(true, ordering: .releasing)
        return false
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
