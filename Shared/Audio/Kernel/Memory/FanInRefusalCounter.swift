import Synchronization

/// Saturation point of the multi-writer refusal counters; reads clamp to it.
private let refusalCap: UInt64 = .max / 2

/// A multi-writer event counter that clamps at `cap` instead of wrapping, under the caller contract below. Any
/// context; target progress unqualified. Reference model; not RT-certified.
///
/// `bump` loads relaxed and, only below `cap`, adds 1 with one relaxed `wrappingAdd`: no retry loop, no lock, and
/// no count below `cap` is lost. `count` clamps to `cap`. The check alone does not bound the raw value: every
/// `bump` whose load saw a value below `cap` adds 1, so with no bound on such callers the raw value could wrap past
/// `UInt64.max` and `count` would fall. Saturation is conditional on this contract, never unconditional.
///
/// Caller contract. Every `bump` on one counter belongs to one logical chain, and:
/// - over its whole lifetime the counter has at most K < 2^39 chains;
/// - a chain's `bump` calls never overlap (no reentry), and each completed `bump` happens before the chain's next
///   one; a chain moves to another thread only through a real happens-before handoff.
/// Then, by coherence, a chain's next load reads at least the value its own previous add wrote, so each chain makes
/// at most one stale admitted add past saturation (its load saw a value below `cap`; the add lands above it). With
/// `cap = 2^63 − 1` the raw value stays at most `max(initial, cap + K) < 2^64`: it never wraps and `count` never
/// falls. Since #768 K-RC2 `bump` borrows an exclusive `RefusalCallerToken` (`caller`), so a chain is one prepared
/// `RefusalCaller` role: K is at most that type's process lifetime budget (2^38 − 1) and a role's token is never
/// shared or overlapped. Its role's releasing `put` and acquiring `take` are the supported cross-thread handoff;
/// any other exclusive transfer needs its own happens-before edge (see
/// docs/transformation/refusal-caller-ownership.md). Unsafe casts, pointers or unchecked boxes around a token
/// are outside this argument. Nothing else bounds K: not the lane count, not the number of threads and not
/// `FaultLatch` (see `FanInHandoff`, Refusal counting). This is reference-model acceptance only (this argument, a
/// reduced-width interleaving test and the K-RC2 accounting tests), not RT qualification of any real caller.
struct FanInRefusalCounter: ~Copyable, Sendable {
    /// Where `count` clamps: `UInt64.max / 2`, 2^63 − 1.
    static var cap: UInt64 { refusalCap }

    private let raw: Atomic<UInt64>

    /// A counter at `initial`.
    init(_ initial: UInt64 = 0) {
        raw = Atomic(initial)
    }

    /// The count, at most `cap`.
    var count: UInt64 { min(raw.load(ordering: .relaxed), refusalCap) }

    /// Counts one event unless the count has reached `cap`, borrowing the caller's exclusive token for the call.
    func bump(caller: inout RefusalCallerToken) {
        if raw.load(ordering: .relaxed) < refusalCap { raw.wrappingAdd(1, ordering: .relaxed) }
    }
}
