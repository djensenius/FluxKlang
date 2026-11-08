//
//  OpenSoundControl+ContextScheduler.swift
//  FluxKlang
//
//  A wrapper around `BundleScheduler` that tags every batch it admits with the receive context the packet arrived
//  under and revalidates that context at dispatch (#89, O2c). The scheduler is wrapped, never edited, and the wrapper
//  keeps it private to writes, so no caller can admit a batch without a tag. It holds no clock: every host stamp is
//  passed in. IP allowlists are not authentication; see `ReceiveContext`.
//

extension OpenSoundControl {
    /// A batch released by `due` or `cancel(_:)`, with the context it was admitted under.
    struct TaggedBatch: Sendable, Hashable {
        fileprivate(set) var batch: ScheduledBatch
        fileprivate(set) var context: ReceiveContext

        fileprivate init(batch: ScheduledBatch, context: ReceiveContext) {
            self.batch = batch
            self.context = context
        }
    }

    /// A batch the scheduler refused at dispatch, with the context it was admitted under.
    struct TaggedRefusal: Sendable, Hashable {
        fileprivate(set) var refused: RefusedBatch
        fileprivate(set) var context: ReceiveContext

        fileprivate init(refused: RefusedBatch, context: ReceiveContext) {
            self.refused = refused
            self.context = context
        }
    }

    /// What one `due` call released. Every list keeps the order of the wrapped scheduler's `DueBatches`.
    struct ContextDue: Sendable, Hashable {
        /// Due batches whose context is live: hand these on.
        fileprivate(set) var dispatch: [TaggedBatch] = []
        /// Due batches whose context is not live: dropped, never to be dispatched.
        fileprivate(set) var revoked: [TaggedBatch] = []
        /// Batches the scheduler itself refused (past the late horizon, for one), whether or not the context is live.
        fileprivate(set) var refusedWithContext: [TaggedRefusal] = []

        fileprivate init() {}
    }

    /// A `BundleScheduler` whose queued batches each carry the `ReceiveContext` they were admitted under.
    ///
    /// The tag is stored at `admit` and never trusted at dispatch: `due` takes the contexts the host holds live at
    /// that moment and releases a due batch for dispatch only when its stored context is a member of them (all four
    /// fields equal), for on-time and late batches alike. A batch whose window has not opened stays queued with its
    /// tag, and keeps its slot in the context table, even if its context is no longer live. Such batches can fill the
    /// table, after which `admit` refuses a new context with `contextTableFull`, so the host calls `cancel(context:)`
    /// whenever it revokes an epoch or a permission.
    ///
    /// Invariants, kept by every mutator: the tags are exactly the queued batches (`tags` keys equal the ids in
    /// `scheduler.pending`); `contexts` counts the queued batches of each context and holds no entry for a context
    /// with none; `contexts.count <= maximumContexts`. A refused `admit`, `cancel(_:)` or `due` changes nothing.
    struct ContextScheduler: Sendable, Hashable {
        private(set) var scheduler: BundleScheduler
        private(set) var maximumContexts: Int
        private var tags: [BatchID: ReceiveContext] = [:]
        private var contexts: [ReceiveContext: Int] = [:]

        var taggedBatchCount: Int { tags.count }
        var contextCount: Int { contexts.count }

        /// Wraps `scheduler`, which must hold no batch (the wrapper could not tag it). Validation order:
        /// `maximumContexts` (1 through `EndpointPolicy.peerLimit`), then an empty scheduler.
        init(scheduler: BundleScheduler, maximumContexts: Int) throws(ContextRefusal) {
            guard (1...EndpointPolicy.peerLimit).contains(maximumContexts) else {
                throw .invalidContextLimit(maximumContexts)
            }
            guard scheduler.pending.isEmpty else {
                throw .schedulerNotEmpty(pending: scheduler.pending.count)
            }
            self.scheduler = scheduler
            self.maximumContexts = maximumContexts
        }

        /// How many queued batches `context` holds.
        func pendingCount(for context: ReceiveContext) -> Int { contexts[context] ?? 0 }

        /// The context `id` was admitted under, if it is queued.
        func context(of id: BatchID) -> ReceiveContext? { tags[id] }

        /// Admits `packet` under `context`, or refuses it with everything unchanged. Refusal order: the context table
        /// (a context without queued batches needs a free slot, even for a packet that carries no message), then the
        /// scheduler's own refusals in its own order. Returns the batches queued, in the scheduler's admit order.
        mutating func admit(
            _ packet: Packet, context: ReceiveContext, now: HostStamp
        ) throws(ContextRefusal) -> [ScheduledBatch] {
            try requireRoom(for: context)
            let admitted: [ScheduledBatch]
            do throws(SchedulingRefusal) {
                admitted = try scheduler.admit(packet, now: now)
            } catch {
                throw .scheduling(error)
            }
            for batch in admitted { tags[batch.id] = context }
            if !admitted.isEmpty { contexts[context, default: 0] += admitted.count }
            return admitted
        }

        /// Removes one queued batch; an id that is not queued is `.scheduling(.batchNotPending)`.
        mutating func cancel(_ id: BatchID) throws(ContextRefusal) -> TaggedBatch {
            guard let removed = remove(id) else { throw .scheduling(.batchNotPending(id)) }
            return removed
        }

        /// Removes every queued batch admitted under `context` and returns their ids ascending by `BatchID.value`
        /// (admit order, which can differ from the queue order). A context with no queued batch returns `[]`: that is
        /// an empty answer, not a refusal. Costs O((k + 1) n) for k removed batches among n queued.
        mutating func cancel(context: ReceiveContext) -> [BatchID] {
            let ids = tags.filter { $0.value == context }.keys.sorted { $0.value < $1.value }
            return ids.compactMap { remove($0)?.batch.id }
        }

        /// Releases every batch whose window has opened at `now`. A due batch whose stored context is a member of
        /// `live` is in `dispatch`, any other in `revoked`; batches the scheduler refuses are in `refusedWithContext`.
        /// Each released batch loses its tag. A refusal (`now` earlier than the latest stamp) changes nothing.
        mutating func due(now: HostStamp, live: Set<ReceiveContext>) throws(ContextRefusal) -> ContextDue {
            var next = self
            let inner: DueBatches
            do throws(SchedulingRefusal) {
                inner = try next.scheduler.due(now: now)
            } catch {
                throw .scheduling(error)
            }
            var result = ContextDue()
            for batch in inner.dispatch {
                let context = try next.release(batch.id)
                let tagged = TaggedBatch(batch: batch, context: context)
                if live.contains(context) {
                    result.dispatch.append(tagged)
                } else {
                    result.revoked.append(tagged)
                }
            }
            for refused in inner.refused {
                let context = try next.release(refused.batch.id)
                result.refusedWithContext.append(TaggedRefusal(refused: refused, context: context))
            }
            self = next
            return result
        }

        private func requireRoom(for context: ReceiveContext) throws(ContextRefusal) {
            guard contexts[context] != nil || contexts.count < maximumContexts else {
                throw .contextTableFull(limit: maximumContexts)
            }
        }

        private func tag(of id: BatchID) throws(ContextRefusal) -> ReceiveContext {
            guard let context = tags[id] else { throw .untaggedBatch(id) }
            return context
        }

        private mutating func release(_ id: BatchID) throws(ContextRefusal) -> ReceiveContext {
            let context = try tag(of: id)
            untag(id, context)
            return context
        }

        private mutating func remove(_ id: BatchID) -> TaggedBatch? {
            guard let context = tags[id], let batch = try? scheduler.cancel(id) else { return nil }
            untag(id, context)
            return TaggedBatch(batch: batch, context: context)
        }

        private mutating func untag(_ id: BatchID, _ context: ReceiveContext) {
            tags[id] = nil
            if let count = contexts[context], count > 1 {
                contexts[context] = count - 1
            } else {
                contexts[context] = nil
            }
        }
    }
}
