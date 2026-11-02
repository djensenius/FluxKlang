// #64 M7 prepared plan slot: an M6 `RetiringExchange` whose payload is a prepared plan together with its own
// `ScratchArena`, so the two are published, adopted, retired and released as one unit. Reference model; not
// RT-certified.

/// A control-to-render, latest-wins handoff of a prepared plan and its per-plan scratch arena, with deferred
/// release. Reference model; not RT-certified.
///
/// Control calls `publish`, which takes the caller's sole reference to the plan, allocates a fresh `ScratchArena`
/// for it and publishes the pair as one private entry through `RetiringExchange`. Render calls `beginCycle` at
/// each cycle boundary, then `withCurrent` to use the current plan and take scratch. M6 owns adoption,
/// retirement and the backpressure invariant; this type adds the arena and the ownership check.
///
/// Ownership contract (exclusive). From a successful `publish` until the slot releases it, the slot's reference
/// must be the plan's only strong reference, and the arena's (the slot creates the arena and never hands it
/// out except as a borrow). `publish` enforces what it can see: `isKnownUniquelyReferenced` on the caller's
/// variable refuses (`.refused(.notOwner)`, plan untouched) a plan another strong reference holds, and on `.ok`
/// it clears the caller's variable. It cannot see, and the contract therefore forbids: a weak or unowned
/// reference used outside the intervals below, a strong reference the plan keeps to itself (a cycle), and a
/// plan or arena that a `withCurrent` body lets escape.
///
/// Weak and unowned access. Any read of the plan or arena through a weak or unowned reference, even
/// `observer?.value`, takes a temporary strong reference; if that temporary is the last one when it ends, it
/// destroys the object on that thread. So such access is allowed only where the slot's reference is known to
/// outlive the temporary: on render inside a `withCurrent` body (render's next `beginCycle` is the earliest the
/// entry can retire), or on control, or on a thread the caller serialises with control's slot calls, ending
/// before the slot's next release of that object (before control's next `publish`, `reclaim` or teardown, or,
/// for the arena, within the plan's `deinit`). Anywhere else it can race `reclaim`. An unowned read also needs
/// the object to be alive (Swift traps otherwise).
///
/// Supported plans: native Swift classes (the case the uniqueness check is defined for) with synchronous,
/// nonisolated destruction, that is no `deinit` or one that is not `isolated` (the default). Releasing the last
/// reference to such a plan runs its `deinit` inline, on the releasing thread, before the release returns. A
/// class or actor with an `isolated deinit` (for example a `@MainActor` class) is unsupported even as sole owner:
/// the compiler accepts it, but releasing its last reference only schedules the `deinit` on the actor's executor
/// (`swift_task_deinitOnExecutor`) unless the releasing thread is already on it, so it can run later, on another
/// thread, after the arena is gone. The slot cannot detect that.
///
/// Release order and deinit order. The entry releases its plan reference first and its arena reference second.
/// That is the order of the slot's own releases, not by itself an order of `deinit`s. Only for a supported plan
/// under the contract is the first release the plan's last and its `deinit` inline, so the plan's `deinit`
/// runs, completely, before the arena's release, and the plan may read its arena (for example through a weak
/// reference) in its `deinit`. Otherwise (another strong reference, or an isolated `deinit`) the arena can be
/// freed first and the plan must never touch it. The slot cannot detect that.
///
/// Where things happen. Every release by the slot is on control: a superseded entry in `publish` (M6), a refused
/// publish's fresh arena in `publish`, retired entries in `reclaim`, the rest at teardown. For a supported plan
/// used as above, every plan and arena `deinit` runs there too, inline. Scratch storage is allocated once per
/// plan, on control, and reused for every cycle that plan is current. The slot's source frees, allocates and
/// deinitialises nothing on render (for runtime metadata requests in unspecialised code, see Progress).
///
/// Render paths. `beginCycle` and `withCurrent` reach the exchange, the entry, the plan and the arena only
/// through `Unmanaged` and borrowed (`_withUnsafeGuaranteedRef`, `borrowing`) references, so this file's source
/// takes no strong reference to any of them on render. A `withCurrent` body keeps that only if it uses its
/// parameters directly: binding them to a variable, wrapping them, or capturing them in another closure may
/// copy them (a retain/release pair, never a `deinit` under the contract above) at `-Onone`, and keeping them
/// past the call breaks that contract. `R` and `body` are the caller's, and so is any ARC, allocation, lock or
/// metadata request they cost.
///
/// Progress (source level only). `beginCycle` is M6's `beginCycle` (at most two retires and one exchange; a
/// refused retire adds `FaultLatch`'s bounded scope lookup and raise) plus one borrowed M6 `withCurrent` whose
/// body is one store (`resetCycle`). `withCurrent` is M6's `withCurrent` plus `body`. This file adds no loop,
/// lock or allocation on render. Atomic lowering and target progress are unqualified, as in M6. Generated code
/// was inspected only in scratch configurations, with no claim for arbitrary bodies or runtime callees:
/// - Assembly (arm64 macOS): at `-O`, specialised code with a known `Plan` and `R` showed no retain, release,
///   allocation, lock, metadata request or trap from this file. At `-Onone`, unspecialised code showed no
///   retain, release, allocation or lock from this file, only what the last two items list.
/// - `@_noAllocation @_noLocks` wrappers (arm64 and x86_64 macOS, arm64 iOS; `-O` and `-Onone`): the checker
///   accepts `beginCycle` and the arena calls. For `withCurrent` it reports reference counting at `lend`'s inner
///   closure, which captures the borrowed plan. Neither assembly level shows one, but `withCurrent` has no
///   checker-backed proof.
/// - Unspecialised `withCurrent` (all `-Onone` code, or a caller that cannot specialise) passes `body`'s `R` as
///   `R?` through M6's generic `withCurrent`, so every call asks the runtime for `Optional<R>` metadata. A first
///   request for an `R` may lock and allocate inside the runtime; later ones are cache lookups. Only specialised
///   callers avoid it; removing it needs an API change, so it is a known limit, not a waiver.
/// - `-Onone` code also makes indirect calls (closures, value witnesses), `swift_beginAccess` calls, and has
///   compiler-emitted `brk`s on the unreachable error edges of the rethrowing `_withUnsafeGuaranteedRef`.
/// Not an RT certification; this slice does not accept or waive #64's final-target hot-path qualification.
/// On control, `publish` allocates an arena and an entry and may release one superseded entry, and `reclaim`
/// releases up to `retire.capacity` entries. Plan and arena `deinit` time is outside render's source bound.
///
/// Caller invariants (documented; neither the compiler nor the slot enforces or checks them):
/// - Fault context (#190). A refused retire in `beginCycle` raises `.retireBacklog` on the retire queue's
///   `FaultLatch` (M6 `DeferredReleaseQueue.retire`, then `FaultLatch.raise`), so the thread calling `beginCycle`
///   is a raise chain under `FaultLatch`'s raise-context contract. A latch shared with other components must
///   count every chain that can raise on it. That proof is open in #190.
/// - Threads. One control and one render thread per slot (below). Every slot or exchange sharing a retire queue
///   must use the same control/render thread pair: the queue is single-producer, single-consumer.
/// - Strong lifetime. The caller keeps the slot strongly alive across each call, and render never holds the last
///   strong reference to it. The slot's own strong references to its exchange, entries and arenas are what keep
///   the unretained aliases inside valid. A borrow must not escape `body`, re-enter the slot's cycle (`body` must
///   not call `beginCycle`), or be re-acquired through weak or unowned references outside the intervals above.
/// - Control only. Arenas are created by `publish` and destroyed through `reclaim`, a refused `publish` or
///   teardown. Teardown is quiescent: render has detached, and that detachment happens before `deinit` (D10).
///
/// Scratch pointers taken in a cycle are valid only until the next `beginCycle`, which resets the current
/// arena. See `ScratchArena` for the full pointer-lifetime rules.
///
/// `Sendable` because its only state is the exchange, but the M6 roles still hold: one control thread calls
/// `publish`, `reclaim` and teardown; one render thread calls `beginCycle` and `withCurrent`. Teardown requires
/// a detached render side (D10).
final class PreparedPlanSlot<Plan: AnyObject & Sendable>: Sendable {
    /// A plan and the arena prepared for it; one M6 payload. Render borrows entries only inside the slot.
    private final class Entry: Sendable {
        private let retainedPlan: Unmanaged<Plan>
        private let retainedScratch: Unmanaged<ScratchArena>

        init(plan: Plan, scratch: ScratchArena) {
            retainedPlan = .passRetained(plan)
            retainedScratch = .passRetained(scratch)
        }

        /// Control only (M6 releases payloads on control). Releases the plan reference, then the arena's. For a
        /// supported plan the first is its last reference, so its `deinit` runs inline here, before the arena's
        /// release; for any other plan this orders only the releases, not its destruction (see the type's notes).
        deinit {
            retainedPlan.release()
            retainedScratch.release()
        }

        /// Render. Starts a scratch cycle without retaining the arena.
        func resetScratch() {
            retainedScratch._withUnsafeGuaranteedRef { $0.resetCycle() }
        }

        /// Render. Lends the plan and its arena to `body` without retaining either. `scratch` is hoisted so the
        /// closures capture only trivial values and the borrowed plan, never `self`.
        func lend<R>(_ body: (Plan, ScratchArena) -> R) -> R {
            let scratch = retainedScratch
            return retainedPlan._withUnsafeGuaranteedRef { (plan: borrowing Plan) in
                scratch._withUnsafeGuaranteedRef { body(plan, $0) }
            }
        }
    }

    /// +1 for the slot's lifetime, released in `deinit`; borrowed everywhere else, so no access retains it.
    private let exchange: Unmanaged<RetiringExchange<Entry>>

    /// Control-side preparation. Starts with no plan. `retire` may be shared with other exchanges that use the
    /// same control and render threads.
    init(retire: DeferredReleaseQueue) {
        exchange = .passRetained(RetiringExchange(initial: nil, retire: retire))
    }

    /// Control-side teardown with render detached (D10): M6 releases what is still pending, current or stalled.
    deinit {
        exchange.release()
    }

    /// Control. Takes `plan` (the caller's sole strong reference; see the ownership contract), prepares a
    /// `scratchBytes`-byte arena aligned to `alignment` for it and publishes both for render to adopt at its
    /// next `beginCycle`, replacing any entry render has not adopted yet.
    /// - `.ok`: published; `plan` is set to `nil`, so the slot holds the only strong reference.
    /// - `.refused(.notOwner)`: `plan` is `nil` or another strong reference holds it; nothing is prepared or
    ///   published and `plan` is untouched. Checked before the geometry.
    /// - `.refused(.full)` (M6 backpressure): nothing is published, `plan` is untouched and the fresh, never
    ///   lent arena is freed here.
    /// - Throws, publishing nothing and leaving `plan` untouched, when the arena geometry is invalid.
    func publish(_ plan: inout Plan?, scratchBytes: Int, alignment: Int) throws(ScratchArena.PreparationError)
        -> KernelStatus {
        guard isKnownUniquelyReferenced(&plan), let owned = plan else { return .refused(.notOwner) }
        let scratch = try ScratchArena(byteCapacity: scratchBytes, alignment: alignment)
        let status = exchange._withUnsafeGuaranteedRef { $0.publish(Entry(plan: owned, scratch: scratch)) }
        if status == .ok { plan = nil }
        return status
    }

    /// Render. Starts a cycle: lets M6 adopt a pending entry, if any, and retire the previous one, then resets
    /// the current entry's arena, whatever the status (`.refused(.full)` included). Returns M6's status
    /// unchanged: `.ok` means a new entry was adopted (even if the previous one's retire stalled); see
    /// `RetiringExchange.beginCycle` for the others. Must not be called from inside `withCurrent`. The reset
    /// closure discards its optional-chained result, so M6's `withCurrent<R>` gets `R == ()`, whose metadata is
    /// static; an inferred `()?` made unspecialised code ask the runtime for `Optional<()>` metadata.
    func beginCycle(frame: Int64) -> KernelStatus {
        exchange._withUnsafeGuaranteedRef { exchange in
            let status = exchange.beginCycle(frame: frame)
            exchange.withCurrent { (entry: borrowing Entry?) in _ = entry?.resetScratch() }
            return status
        }
    }

    /// Render. Lends the current plan and its arena to `body` without retaining either, or returns `nil` without
    /// calling `body` before the first adoption. Use the parameters directly (see the render-path notes);
    /// neither they nor any scratch buffer may escape `body`, and `body` must not call `beginCycle` on this slot
    /// (M6: no re-entrant cycle). Unspecialised calls ask the runtime for `Optional<R>` metadata (see Progress).
    func withCurrent<R>(_ body: (Plan, ScratchArena) -> R) -> R? {
        exchange._withUnsafeGuaranteedRef { $0.withCurrent { (entry: borrowing Entry?) in entry?.lend(body) } }
    }

    /// Control. Releases every entry render retired (plan reference, then arena) to the possibly shared queue;
    /// returns how many entries were released.
    @discardableResult
    func reclaim() -> Int {
        exchange._withUnsafeGuaranteedRef { $0.reclaim() }
    }
}
