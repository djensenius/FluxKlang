// #64 fault latch (owner default D14): a fault scope is a handoff × output/stream slot, and a raised fault
// stays latched until control acknowledges it. Raising takes no lock and has no source-level retry loop; target
// atomic lowering and progress are unqualified (see Progress). Reference model; not RT-certified.
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
    /// replace it. A hint only: recovery must cover the whole scope.
    let kind: FaultKind
    /// Raises since the scope was armed, saturating at `FaultLatch.countCap` (2^39).
    let count: UInt64
    /// The frame passed to the first raise since the scope was armed; any `Int64`, including `.min` and `.max`.
    let firstFrame: Int64
}

/// One control-side observation of a latched scope, bound to the latch that made it. Only `FaultLatch.observe`
/// creates one, and `FaultLatch.acknowledge(_:)` accepts it only while nothing has been raised or acknowledged on
/// its scope since. Holds its latch strongly. Reference model; not RT-certified.
struct FaultObservation: Sendable {
    /// The latched record; `kind` is only the first kind raised, so recovery must cover the whole scope.
    let record: FaultRecord
    /// `false` when acknowledging can never succeed (count saturated or epoch exhausted): the scope then stays
    /// latched until the latch is replaced while quiescent.
    let isAcknowledgeable: Bool
    fileprivate let owner: FaultLatch
    fileprivate let index: Int
    fileprivate let tally: UInt64
    fileprivate let claim: WordPair
    fileprivate let epoch: UInt64
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
/// `observe` and `pending` read `tally`, then `first`. If `count > 0` but `first` does not yet hold `g`, the
/// first raiser is still publishing: both skip the scope (`observe` returns `nil`), so a fault raised just now can
/// appear on the next poll rather than this one. Otherwise `first` is final for `g`. Reported counts are
/// `min(count, countCap)`. `addRaiseForTesting` and `publishRaiseForTesting` pause a real first raiser there.
///
/// Acknowledging. Control observes a scope, recovers the whole scope off-thread, then passes the observation to
/// `acknowledge`, which makes at most one compare-exchange from the exact observed `tally` to `(0, g + 1)` and
/// returns the record only if it succeeds. It refuses (`nil`, nothing changed) an observation from another latch,
/// one made before the scope's last acknowledge (per-scope `epoch`), a saturated one, or any whose `tally` has
/// moved, that is, any raise since the observation. `nil` means only that this call changed nothing and re-armed
/// nothing; it says nothing about the scope's current state, nor (for a foreign observation) about this latch. The
/// scope may already be acknowledged and unlatched (for example, the observation was acknowledged before) or may
/// still be latched (new raises, saturation). `nil` grants no authority to resume: the caller reconciles with the
/// current state (`isLatched`, `observe`) and, only while the scope is still latched, observes and recovers again;
/// an `observe` of `nil` while `isLatched` is `true` is still not "no fault" (see `observe`).
/// Proof that success means no raise since the observation went unrecovered:
/// - Owner: the observation holds its latch strongly, so no other latch can reuse that address while it exists;
///   a foreign observation is refused before its index is used.
/// - Epoch: each scope's `epoch` steps exactly when an acknowledge of it succeeds, in the same `control` critical
///   section as the compare-exchange (and when the test-only `seedForTesting` rewrites the scope), and stops at
///   `epochLimit` instead of wrapping (then the scope fails closed).
///   Equal epochs mean no acknowledge of the scope has succeeded since the observation, so its generation has not
///   stepped, even if the packed 24-bit generation has since wrapped back to the same value (ABA).
/// - Count: within a generation `count` only grows, by raises. An unchanged `tally` (same generation) therefore
///   means no raise was counted since the observation, and with `count < countCap` at the observation every raise
///   since was counted (a raise skips its add only at the cap). A saturated count cannot prove that, so a
///   saturated observation is never acknowledgeable: the scope stays latched until the latch is replaced.
/// An add after the successful compare-exchange is the first raise of a new latched record.
///
/// Serialization. `observe`, `acknowledge` and `pending`'s read of each scope run under `control`, a control-side
/// `Mutex`, which also guards the plain `epoch` words; `raise` and `isLatched` never take it. Only `acknowledge`
/// steps a generation, so a control operation never pairs an old count with a new claim. Each holds `control` for
/// one scope's reads and at most one compare-exchange call, with no source-level retry loop (target lowering
/// unqualified; see Progress). The `Mutex` is control-side only: the render paths (`raise`, `isLatched`) never
/// take it, and X1's lint must allow `Mutex` only in `FaultLatch` control paths.
///
/// Progress (source level only). `raise` and `isLatched` take no lock and have no source-level retry loop: one
/// load, at most one wrapping add and at most one 128-bit release store, each one `Synchronization.Atomic`
/// operation. That fixed operation count is not target-level wait-freedom. The protocol relies on `Atomic`'s
/// documented semantics (single-copy atomicity of `UInt64` and `WordPair` at the stated orderings); whether a
/// target lowers each operation to a bounded, non-spuriously-failing sequence is not proved here, so target atomic
/// lowering and progress are unqualified. The no-allocation/no-lock and call-graph checks hold only for the
/// targets and configurations they ran on. This slice does not accept or waive #64's final-target hot-path
/// qualification. `observe`, `acknowledge` and `pending` run on control, where the lock is acceptable;
/// under a continuous stream of raises an acknowledge may keep being refused, which fails safe (still latched).
///
/// Saturation. Raisers that pass the cap check concurrently can overshoot `countCap` by at most the number of
/// concurrent raisers, far below the 2^39 of headroom, so `count` never carries into `generation`. Reads clamp to
/// `countCap`, and a saturated scope stays latched and fails closed. `admitRaiseForTesting` forces that race.
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
    // Computed constants (from `Bits`), not lazy `static let` globals: render paths must never reach a lazy
    // global's one-time initialisation (`swift_once`), which `-Onone` emits for a `static let` (round 11).
    // `maximumScopes` stays a `static let`: only `init` reads it.
    static var countBits: UInt64 { Bits.countBits }
    static var countMask: UInt64 { Bits.countMask }
    /// Saturation point for a record's count; the 2^39 above it absorb concurrent overshoot.
    static var countCap: UInt64 { Bits.countCap }
    static var generationMask: UInt64 { Bits.generationMask }
    /// Saturation point for `unknownScopeFaults`; reads clamp to it.
    static var unknownCap: UInt64 { Bits.unknownCap }

    private let scopeCount: Int
    /// Sorted packed scope keys (`handoff << 32 | target`).
    private let keys: UnsafeMutablePointer<UInt64>
    private let tallies: UnsafeMutablePointer<Atomic<UInt64>>
    private let firsts: UnsafeMutablePointer<Atomic<WordPair>>
    /// Successful acknowledges per scope; read and written only under `control`.
    private let epochs: UnsafeMutablePointer<UInt64>
    private let epochLimit: UInt64
    private let unknown = Atomic<UInt64>(0)
    /// Serializes control operations and guards `epochs` (see Serialization above).
    private let control = Mutex(())

    /// Control-side preparation only. `epochLimit` caps each scope's successful acknowledges, after which it
    /// fails closed; lowering it only makes that happen sooner, so tests use it to reach the limit.
    init(scopes: [FaultScope], epochLimit: UInt64 = .max) throws(PreparationError) {
        guard !scopes.isEmpty else { throw .emptyScopeTable }
        guard scopes.count <= Self.maximumScopes else { throw .tooManyScopes(scopes.count) }
        let sorted = scopes.map(Bits.key).sorted()
        for index in sorted.indices.dropFirst() where sorted[index] == sorted[index &- 1] {
            throw .duplicateScope(Bits.scope(forKey: sorted[index]))
        }
        scopeCount = sorted.count
        keys = .allocate(capacity: sorted.count)
        tallies = .allocate(capacity: sorted.count)
        firsts = .allocate(capacity: sorted.count)
        epochs = .allocate(capacity: sorted.count)
        epochs.initialize(repeating: 0, count: sorted.count)
        self.epochLimit = epochLimit
        let unclaimed = WordPair(first: 0, second: UInt(truncatingIfNeeded: Bits.generationMask << 8))
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
        epochs.deinitialize(count: scopeCount)
        epochs.deallocate()
        keys.deinitialize(count: scopeCount)
        keys.deallocate()
    }

    /// Any context; no lock or source-level retry loop (target progress unqualified; see Progress). `.ok` when
    /// counted against a prepared scope; an unprepared scope is counted in `unknownScopeFaults` and refused with
    /// `.slotOutOfRange`.
    func raise(_ scope: FaultScope, _ kind: FaultKind, frame: Int64) -> KernelStatus {
        guard let index = index(of: scope) else {
            if unknown.load(ordering: .relaxed) < Bits.unknownCap {
                unknown.wrappingAdd(1, ordering: .relaxed)
            }
            return .refused(.slotOutOfRange)
        }
        if admits(index) { count(index, kind, frame) }
        return .ok
    }

    /// `raise`'s cap check: one acquire load. A raise admitted here may be preempted before `count`, so raisers
    /// admitted together just below the cap all add (see Saturation).
    private func admits(_ index: Int) -> Bool {
        Bits.count((tallies + index).pointee.load(ordering: .acquiring)) < Bits.countCap
    }

    /// `raise`'s transition: one wrapping add, then the first raiser of the generation publishes `first`.
    private func count(_ index: Int, _ kind: FaultKind, _ frame: Int64) {
        publish(index, increment(index), kind, frame)
    }

    /// `raise`'s add; returns the old tally.
    private func increment(_ index: Int) -> UInt64 {
        (tallies + index).pointee.wrappingAdd(1, ordering: .acquiringAndReleasing).oldValue
    }

    /// `raise`'s publication: only the raise whose add saw count 0 (the generation's unique first raiser) stores
    /// `first`, for the generation of `old`.
    private func publish(_ index: Int, _ old: UInt64, _ kind: FaultKind, _ frame: Int64) {
        guard Bits.count(old) == 0 else { return }
        let meta = Bits.generation(old) &<< 8 | UInt64(kind.rawValue)
        (firsts + index).pointee.store(
            WordPair(first: UInt(truncatingIfNeeded: frame), second: UInt(truncatingIfNeeded: meta)),
            ordering: .releasing)
    }

    /// Test-only: one `raise` stopped between its cap check and its add, as a raiser preempted there. It is
    /// noncopyable, so it adds at most once, and it holds its latch strongly.
    struct AdmittedRaiseForTesting: ~Copyable {
        fileprivate let owner: FaultLatch
        fileprivate let index: Int
        fileprivate let kind: FaultKind
        fileprivate let frame: Int64
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): runs `raise`'s own cap check and stops before the
    /// add; `nil` when the scope is unprepared or the check refuses (count at the cap). Every admission held
    /// open is one stalled raiser, so hold only a few (each may overshoot the cap by one).
    func admitRaiseForTesting(_ scope: FaultScope, _ kind: FaultKind, frame: Int64) -> AdmittedRaiseForTesting? {
        guard let index = index(of: scope), admits(index) else { return nil }
        return AdmittedRaiseForTesting(owner: self, index: index, kind: kind, frame: frame)
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): completes an admitted raise with `raise`'s own
    /// transition, without re-checking the cap; `false` (nothing changes) for another latch's admission.
    func finishRaiseForTesting(_ admitted: consuming AdmittedRaiseForTesting) -> Bool {
        guard admitted.owner === self else { return false }
        count(admitted.index, admitted.kind, admitted.frame)
        return true
    }

    /// Test-only: one `raise` stopped after its add and before its publication, as a raiser preempted there.
    /// Noncopyable, so it publishes at most once; holds its latch strongly.
    struct UnpublishedRaiseForTesting: ~Copyable {
        fileprivate let owner: FaultLatch
        fileprivate let index: Int
        fileprivate let kind: FaultKind
        fileprivate let frame: Int64
        fileprivate let old: UInt64
        /// `true` when this raise's add saw count 0, so it alone publishes the generation's `first`.
        var isFirstRaiser: Bool { Bits.count(old) == 0 }
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): runs `raise`'s own add for an admitted raise and
    /// stops before its publication; `nil` (nothing changes) for another latch's admission.
    func addRaiseForTesting(_ admitted: consuming AdmittedRaiseForTesting) -> UnpublishedRaiseForTesting? {
        guard admitted.owner === self else { return nil }
        return UnpublishedRaiseForTesting(owner: self, index: admitted.index, kind: admitted.kind,
                                          frame: admitted.frame, old: increment(admitted.index))
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): resumes a paused raise with `raise`'s own
    /// publication; `false` (nothing changes) for another latch's raise.
    func publishRaiseForTesting(_ added: consuming UnpublishedRaiseForTesting) -> Bool {
        guard added.owner === self else { return false }
        publish(added.index, added.old, added.kind, added.frame)
        return true
    }

    /// Render; one 64-bit load. `true` while the scope holds an unacknowledged fault.
    func isLatched(_ scope: FaultScope) -> Bool {
        guard let index = index(of: scope) else { return false }
        return Bits.count((tallies + index).pointee.load(ordering: .acquiring)) > 0
    }

    /// Control/UI, diagnostic only; takes the control lock, so never call from render. Visits each published
    /// latched record once, without clearing it, and returns how many it visited. A record whose first raise is
    /// still publishing is skipped until the next poll. Records of different scopes are read one after another,
    /// not as one snapshot. A first raiser stalled between its add and its store keeps the scope skipped while
    /// `isLatched` is already `true`; callers must not read that skip as "no fault". To clear a scope, use
    /// `observe` and `acknowledge(_:)`.
    func pending(_ body: (FaultRecord) -> Void) -> Int {
        var visited = 0
        for index in 0..<scopeCount {
            // `body` runs outside the lock, so it may call back into the latch.
            guard let (tally, claim) = control.withLock({ _ in snapshot(index) }) else { continue }
            body(record(index, tally, claim))
            visited &+= 1
        }
        return visited
    }

    /// Control; takes the control lock, so never call from render. The scope's latched record, bound to this
    /// latch and the scope's current epoch, for `acknowledge(_:)` after recovery; `nil` when the scope is
    /// unprepared, not latched, or its first raise is still publishing (retry on the next control tick).
    /// A first raiser stalled between its add and its store yields `nil` while `isLatched` is already `true`;
    /// callers must not read that `nil` as "no fault".
    func observe(_ scope: FaultScope) -> FaultObservation? {
        guard let index = index(of: scope) else { return nil }
        return control.withLock { _ in
            guard let (tally, claim) = snapshot(index) else { return nil }
            let epoch = epochs[index]
            return FaultObservation(
                record: record(index, tally, claim),
                isAcknowledgeable: Bits.count(tally) < Bits.countCap && epoch < epochLimit,
                owner: self, index: index, tally: tally, claim: claim, epoch: epoch)
        }
    }

    /// Control; takes the control lock, so never call from render. Run off-thread recovery of the whole scope
    /// first. Re-arms the scope and returns `observation.record` only if nothing was raised or acknowledged on
    /// the scope since `observe`; otherwise `nil`: this call changed nothing, and the scope may already be unlatched
    /// or may still be latched. Reconcile with the current state and, only if it is still latched, observe and
    /// recover again. At most one compare-exchange (see Acknowledging).
    func acknowledge(_ observation: FaultObservation) -> FaultRecord? {
        guard observation.owner === self, observation.isAcknowledgeable else { return nil }
        let index = observation.index
        return control.withLock { _ in
            // Equal epochs: no acknowledge of this scope since `observe`, so `first` still holds the claim
            // read then; comparing it is defensive.
            guard epochs[index] == observation.epoch,
                  firsts[index].load(ordering: .acquiring) == observation.claim else { return nil }
            let rearmed = ((Bits.generation(observation.tally) &+ 1) & Bits.generationMask) << Bits.countBits
            guard tallies[index].compareExchange(
                expected: observation.tally, desired: rearmed, ordering: .acquiringAndReleasing).exchanged
            else { return nil }
            // `isAcknowledgeable` implies `epoch < epochLimit <= UInt64.max`, so this never wraps.
            epochs[index] = observation.epoch &+ 1
            return observation.record
        }
    }

    /// Reads `tally`, then `first`; `nil` when nothing is latched or the first raise is still publishing.
    /// Callers hold `control`.
    private func snapshot(_ index: Int) -> (UInt64, WordPair)? {
        let tally = tallies[index].load(ordering: .acquiring)
        guard Bits.count(tally) > 0 else { return nil }
        let claim = firsts[index].load(ordering: .acquiring)
        guard Bits.claimGeneration(claim) == Bits.generation(tally) else { return nil }
        return (tally, claim)
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): runs `body` while holding the control lock, to
    /// show that `acknowledge` and `pending` wait for it. `body` must not call `observe`, `acknowledge`,
    /// `pending` or `seedForTesting`.
    func withControlLockForTesting(_ body: () -> Void) {
        control.withLock { _ in body() }
    }

    /// Raises against scopes that were never prepared, saturating at `unknownCap`.
    var unknownScopeFaults: UInt64 { min(unknown.load(ordering: .relaxed), Bits.unknownCap) }

    /// Test-only (X1 denies `ForTesting(` outside test targets): overwrites a scope's raw state while no other
    /// thread raises against it. Under the control lock it first steps the scope's epoch, as an acknowledge
    /// would, so every earlier observation of the scope is refused even if the seed restores the exact `tally`
    /// and `first` it saw. At `epochLimit` it fails closed: `false`, nothing changes. `false` for an unprepared
    /// scope. There is no way to rewind an epoch.
    func seedForTesting(_ scope: FaultScope, _ state: TestState, kind: FaultKind, frame: Int64) -> Bool {
        guard let index = index(of: scope) else { return false }
        return control.withLock { _ in
            guard epochs[index] < epochLimit else { return false }
            epochs[index] &+= 1
            let generation = state.generation & Bits.generationMask
            tallies[index].store(generation << Bits.countBits | state.count & Bits.countMask, ordering: .releasing)
            let meta = (state.claimGeneration & Bits.generationMask) << 8 | UInt64(kind.rawValue)
            firsts[index].store(
                WordPair(first: UInt(truncatingIfNeeded: frame), second: UInt(truncatingIfNeeded: meta)),
                ordering: .releasing)
            return true
        }
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): a scope's raw generation, unclamped count and
    /// claim generation, or `nil` for an unprepared scope.
    func stateForTesting(_ scope: FaultScope) -> TestState? {
        guard let index = index(of: scope) else { return nil }
        let observed = tallies[index].load(ordering: .acquiring)
        return TestState(generation: Bits.generation(observed), count: Bits.count(observed),
                         claimGeneration: Bits.claimGeneration(firsts[index].load(ordering: .acquiring)))
    }

    /// Test-only (X1 denies `ForTesting(` outside test targets): sets the raw unknown-scope counter.
    func seedUnknownScopeFaultsForTesting(_ count: UInt64) {
        unknown.store(count, ordering: .relaxed)
    }

    private func record(_ index: Int, _ observed: UInt64, _ claim: WordPair) -> FaultRecord {
        // Only `FaultKind` raw values are stored, so the fallback is unreachable.
        let kind = FaultKind(rawValue: UInt8(truncatingIfNeeded: claim.second)) ?? .criticalExhausted
        return FaultRecord(scope: Bits.scope(forKey: keys[index]), kind: kind,
                           count: min(Bits.count(observed), Bits.countCap),
                           firstFrame: Int64(truncatingIfNeeded: claim.first))
    }

    /// Bounded binary search; allocation-free.
    private func index(of scope: FaultScope) -> Int? {
        let key = Bits.key(scope)
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

    /// Packing helpers and constants. Keep these nested rather than as class static methods: calling a class's
    /// static method requires its metatype, which the `@_noAllocation`/`@_noLocks` checker rejects on the render
    /// path as possible metadata allocation or locks. Render-path class methods must not call class static
    /// methods. The constants are computed properties, so no render path can reach a lazy global's `swift_once`.
    private enum Bits {
        // Literal values and masking shifts (`&<<`, `&>>`) only: at `-Onone` a smart shift or a division keeps a
        // trap path (`_assertionFailure`) that render paths must not reach.
        static var countBits: UInt64 { 40 }
        /// 2^40 − 1.
        static var countMask: UInt64 { 0xFF_FFFF_FFFF }
        /// 2^39.
        static var countCap: UInt64 { 0x80_0000_0000 }
        /// 2^24 − 1.
        static var generationMask: UInt64 { 0xFF_FFFF }
        /// `UInt64.max / 2`.
        static var unknownCap: UInt64 { 0x7FFF_FFFF_FFFF_FFFF }

        static func count(_ tally: UInt64) -> UInt64 { tally & countMask }

        static func generation(_ tally: UInt64) -> UInt64 { (tally &>> countBits) & generationMask }

        static func claimGeneration(_ claim: WordPair) -> UInt64 {
            (UInt64(truncatingIfNeeded: claim.second) &>> 8) & generationMask
        }

        static func key(_ scope: FaultScope) -> UInt64 {
            UInt64(scope.handoff) &<< 32 | UInt64(scope.target)
        }

        static func scope(forKey key: UInt64) -> FaultScope {
            FaultScope(handoff: UInt16(truncatingIfNeeded: key &>> 32), target: UInt32(truncatingIfNeeded: key))
        }
    }
}
