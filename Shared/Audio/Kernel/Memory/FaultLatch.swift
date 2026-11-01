// #64 fault latch (owner default D14): a fault scope is a handoff × output/stream slot, and a raised fault
// stays latched until control acknowledges it. Raising is wait-free and allocation-free from any context.
// Reference model; not RT-certified.
import Synchronization

#if !_pointerBitWidth(_64)
#error("FaultLatch packs 64-bit counts and frames into machine words and requires a 64-bit platform.")
#endif

/// Why a scope latched. Reference model; not RT-certified.
enum FaultKind: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case criticalExhausted, producerSlotsExhausted, retireBacklog, scratchExhausted, sysexOverflow, sysexAborted,
         noPlan, staleClock
}

/// One handoff × one output/stream slot. Reference model; not RT-certified.
struct FaultScope: Hashable, Sendable, BitwiseCopyable {
    let handoff: UInt16
    let target: UInt32
}

/// A latched fault since the scope was last armed. Reference model; not RT-certified.
struct FaultRecord: Sendable, BitwiseCopyable, Equatable {
    let scope: FaultScope
    /// The first kind raised since the scope was armed; later raises of other kinds are counted but do not
    /// replace it.
    let kind: FaultKind
    /// Raises since the scope was armed, saturating at `FaultLatch.countCap` (2^39).
    let count: UInt64
    /// The frame passed to the first raise since the scope was armed; any `Int64`, including `.min` and `.max`.
    let firstFrame: Int64
}

/// A fixed table of fault scopes, prepared up front, each latching until acknowledged.
/// Reference model; not RT-certified.
///
/// Protocol. Each scope owns two atomics:
/// - `tally: UInt64 = generation:24 | count:40`. Only `raise` changes `count` (one wrapping add); only
///   `acknowledge` changes `generation` (compare-exchange `(c, g)` → `(0, g + 1)`, generations modulo 2^24).
/// - `first: WordPair = (frame bits, generation << 8 | kind)`: the first raise of a generation. It starts at
///   generation 2^24 − 1, that is −1.
///
/// `raise` loads `tally`; if `count >= countCap` it returns (saturated, still latched). Otherwise it adds 1 and,
/// when the old count was 0, it is the unique first raiser of `g = generation(old)` and publishes `first` for
/// `g` with one release store. `count` returns to 0 only together with a generation step, so exactly one raise
/// per generation sees an old count of 0. The scope is latched exactly when `count > 0`.
///
/// Invariant: while `tally` is at generation `g`, `first` holds generation `g − 1` or `g` (modulo 2^24). Its
/// store never races another writer: `acknowledge` moves `tally` to `g + 1` only after it has read `first`
/// holding `g`, and the `g + 1` writer's add reads that compare-exchange (or a later add in its release
/// sequence), so the `g` store happens before the `g + 1` store and there is one writer per generation.
/// Equality modulo 2^24 is enough because `first` is never more than one generation behind, so a wrap cannot
/// stop a scope from latching.
///
/// `acknowledge` and `pending` read `tally`, then `first`. If `count > 0` but `first` does not yet hold `g`,
/// the first raiser is still publishing: `pending` skips the scope and `acknowledge` returns `nil`, so a fault
/// raised just now can appear on the next poll rather than this one. Otherwise `first` is final for `g`.
/// `acknowledge` then swaps `(c, g)` for `(0, g + 1)`. An add lands before that compare-exchange (in the returned
/// record, which retries with the larger count) or after it (the first raise of a new latched record), so no
/// raise is lost and no record is returned twice; a concurrent second `acknowledge` loses the compare-exchange,
/// sees the generation move and returns `nil` (without that check it would reset the next generation's count
/// and report it under this generation's first raise). Reported counts are `min(count, countCap)`.
///
/// Progress. `raise` and `isLatched` have no retry loops: one load, at most one wrapping add and at most one
/// 128-bit release store (`stp` on arm64 macOS; on arm64 iOS and x86_64 a value-comparing compare-exchange loop
/// that ends within two iterations, because every concurrent access to `first` is a value-preserving read).
/// `acknowledge` loops only while raises grow the count, so it is lock-free; it runs on control.
///
/// Saturation. Raisers that pass the cap check concurrently can overshoot `countCap` by at most the number of
/// concurrent raisers, far below the 2^39 of headroom, so `count` never carries into `generation`.
///
/// Ordering: acquire/release. Each successful write to `tally` reads the one before it (RMW), and readers
/// acquire `tally` before `first`, which is enough for every argument above. Relaxed is unsound because it
/// breaks the happens-before from the `g` store of `first` to the `g + 1` store (see the invariant above): the
/// `g` store could then land last, and the scope would look "still publishing" forever.
/// Sequential consistency is not used; it would only add a total order with external SC clients.
///
/// Scope lookup is a binary search over a sorted key table, at most 13 probes for `maximumScopes`.
final class FaultLatch: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        case emptyScopeTable
        case duplicateScope(FaultScope)
        case tooManyScopes(Int)
    }

    /// Test-only view and seed of one scope's raw state.
    struct TestState: Equatable {
        let generation: UInt64
        let count: UInt64
        let claimGeneration: UInt64
    }

    /// Largest number of scopes one latch may prepare (inclusive): 4,096 covers 16 handoffs × 256 slots.
    static let maximumScopes = 4_096
    static let countBits: UInt64 = 40
    static let countMask: UInt64 = (1 << countBits) &- 1
    /// Saturation point for a record's count; the 2^39 above it absorb concurrent overshoot.
    static let countCap: UInt64 = 1 << 39
    static let generationMask: UInt64 = (1 << 24) &- 1
    /// Saturation point for `unknownScopeFaults`; reads clamp to it.
    static let unknownCap: UInt64 = .max / 2

    private let scopeCount: Int
    /// Sorted packed scope keys (`handoff << 32 | target`).
    private let keys: UnsafeMutablePointer<UInt64>
    private let tallies: UnsafeMutablePointer<Atomic<UInt64>>
    private let firsts: UnsafeMutablePointer<Atomic<WordPair>>
    private let unknown = Atomic<UInt64>(0)

    /// Control-side preparation only.
    init(scopes: [FaultScope]) throws(PreparationError) {
        guard !scopes.isEmpty else { throw .emptyScopeTable }
        guard scopes.count <= Self.maximumScopes else { throw .tooManyScopes(scopes.count) }
        let sorted = scopes.map(Self.key).sorted()
        for index in sorted.indices.dropFirst() where sorted[index] == sorted[index &- 1] {
            throw .duplicateScope(Self.scope(forKey: sorted[index]))
        }
        scopeCount = sorted.count
        keys = .allocate(capacity: sorted.count)
        tallies = .allocate(capacity: sorted.count)
        firsts = .allocate(capacity: sorted.count)
        let unclaimed = WordPair(first: 0, second: UInt(truncatingIfNeeded: Self.generationMask << 8))
        for (index, key) in sorted.enumerated() {
            (keys + index).initialize(to: key)
            (tallies + index).initialize(to: Atomic(0))
            (firsts + index).initialize(to: Atomic(unclaimed))
        }
    }

    /// Control-side teardown.
    deinit {
        tallies.deinitialize(count: scopeCount)
        tallies.deallocate()
        firsts.deinitialize(count: scopeCount)
        firsts.deallocate()
        keys.deinitialize(count: scopeCount)
        keys.deallocate()
    }

    /// Any context; wait-free. `.ok` when counted against a prepared scope; an unprepared scope is counted in
    /// `unknownScopeFaults` and refused with `.slotOutOfRange`.
    func raise(_ scope: FaultScope, _ kind: FaultKind, frame: Int64) -> KernelStatus {
        guard let index = index(of: scope) else {
            if unknown.load(ordering: .relaxed) < Self.unknownCap {
                unknown.wrappingAdd(1, ordering: .relaxed)
            }
            return .refused(.slotOutOfRange)
        }
        let tally = tallies + index
        guard Self.count(tally.pointee.load(ordering: .acquiring)) < Self.countCap else { return .ok }
        let old = tally.pointee.wrappingAdd(1, ordering: .acquiringAndReleasing).oldValue
        if Self.count(old) == 0 {
            let meta = Self.generation(old) << 8 | UInt64(kind.rawValue)
            (firsts + index).pointee.store(
                WordPair(first: UInt(truncatingIfNeeded: frame), second: UInt(truncatingIfNeeded: meta)),
                ordering: .releasing)
        }
        return .ok
    }

    /// Render; one 64-bit load. `true` while the scope holds an unacknowledged fault.
    func isLatched(_ scope: FaultScope) -> Bool {
        guard let index = index(of: scope) else { return false }
        return Self.count((tallies + index).pointee.load(ordering: .acquiring)) > 0
    }

    /// Control/UI. Visits each published latched record once, without clearing it, and returns how many it
    /// visited. A record whose first raise is still publishing is skipped until the next poll. Records of
    /// different scopes are read one after another, not as one snapshot. A first raiser stalled between its add
    /// and its store keeps the scope skipped while `isLatched` is already `true`; callers must not read that skip
    /// as "no fault".
    func pending(_ body: (FaultRecord) -> Void) -> Int {
        var visited = 0
        for index in 0..<scopeCount {
            let observed = tallies[index].load(ordering: .acquiring)
            guard Self.count(observed) > 0 else { continue }
            let claim = firsts[index].load(ordering: .acquiring)
            guard Self.claimGeneration(claim) == Self.generation(observed) else { continue }
            body(record(index, observed, claim))
            visited &+= 1
        }
        return visited
    }

    /// Control. Returns the latched record and re-arms the scope, or `nil` when nothing is latched or the first
    /// raise is still publishing (retry on the next control tick). Run off-thread recovery before acknowledging.
    /// A first raiser stalled between its add and its store yields `nil` while `isLatched` is already `true`;
    /// callers must not read that `nil` as "no fault".
    func acknowledge(_ scope: FaultScope) -> FaultRecord? {
        guard let index = index(of: scope) else { return nil }
        let tally = tallies + index
        var observed = tally.pointee.load(ordering: .acquiring)
        guard Self.count(observed) > 0 else { return nil }
        let claim = firsts[index].load(ordering: .acquiring)
        let generation = Self.generation(observed)
        guard Self.claimGeneration(claim) == generation else { return nil }
        let rearmed = ((generation &+ 1) & Self.generationMask) << Self.countBits
        while true {
            let (exchanged, original) = tally.pointee.compareExchange(
                expected: observed, desired: rearmed, ordering: .acquiringAndReleasing)
            if exchanged { return record(index, observed, claim) }
            // Another acknowledge re-armed this generation first.
            guard Self.generation(original) == generation else { return nil }
            observed = original
        }
    }

    /// Raises against scopes that were never prepared, saturating at `unknownCap`.
    var unknownScopeFaults: UInt64 { min(unknown.load(ordering: .relaxed), Self.unknownCap) }

    /// Test-only (X1 denies `ForTesting(` outside test targets): overwrites a scope's raw state while no other
    /// thread uses the latch. `false` for an unprepared scope.
    func seedForTesting(_ scope: FaultScope, _ state: TestState, kind: FaultKind, frame: Int64) -> Bool {
        guard let index = index(of: scope) else { return false }
        let generation = state.generation & Self.generationMask
        tallies[index].store(generation << Self.countBits | state.count & Self.countMask, ordering: .releasing)
        let meta = (state.claimGeneration & Self.generationMask) << 8 | UInt64(kind.rawValue)
        firsts[index].store(WordPair(first: UInt(truncatingIfNeeded: frame), second: UInt(truncatingIfNeeded: meta)),
                            ordering: .releasing)
        return true
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): a scope's raw generation, unclamped count and
    /// claim generation, or `nil` for an unprepared scope.
    func stateForTesting(_ scope: FaultScope) -> TestState? {
        guard let index = index(of: scope) else { return nil }
        let observed = tallies[index].load(ordering: .acquiring)
        return TestState(generation: Self.generation(observed), count: Self.count(observed),
                         claimGeneration: Self.claimGeneration(firsts[index].load(ordering: .acquiring)))
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): sets the raw unknown-scope counter.
    func seedUnknownScopeFaultsForTesting(_ count: UInt64) {
        unknown.store(count, ordering: .relaxed)
    }

    private func record(_ index: Int, _ observed: UInt64, _ claim: WordPair) -> FaultRecord {
        // Only `FaultKind` raw values are stored, so the fallback is unreachable.
        let kind = FaultKind(rawValue: UInt8(truncatingIfNeeded: claim.second)) ?? .criticalExhausted
        return FaultRecord(scope: Self.scope(forKey: keys[index]), kind: kind,
                           count: min(Self.count(observed), Self.countCap),
                           firstFrame: Int64(truncatingIfNeeded: claim.first))
    }

    /// Bounded binary search; allocation-free.
    private func index(of scope: FaultScope) -> Int? {
        let key = Self.key(scope)
        var low = 0
        var high = scopeCount
        while low < high {
            let middle = low &+ (high &- low) >> 1
            let probe = keys[middle]
            if probe == key { return middle }
            if probe < key { low = middle &+ 1 } else { high = middle }
        }
        return nil
    }

    private static func count(_ tally: UInt64) -> UInt64 { tally & countMask }

    private static func generation(_ tally: UInt64) -> UInt64 { (tally >> countBits) & generationMask }

    private static func claimGeneration(_ claim: WordPair) -> UInt64 {
        (UInt64(truncatingIfNeeded: claim.second) >> 8) & generationMask
    }

    private static func key(_ scope: FaultScope) -> UInt64 {
        UInt64(scope.handoff) << 32 | UInt64(scope.target)
    }

    private static func scope(forKey key: UInt64) -> FaultScope {
        FaultScope(handoff: UInt16(truncatingIfNeeded: key >> 32), target: UInt32(truncatingIfNeeded: key))
    }
}
