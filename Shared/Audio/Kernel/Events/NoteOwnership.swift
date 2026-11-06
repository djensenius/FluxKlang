import Synchronization

// #64 note ownership and safety flags. `NoteOwnership` records which notes each scope has sounding so a scope can
// always release exactly what it owns; `SafetyFlags` carries panic and all-notes-off requests that can never be
// exhausted or lost; `KernelRetirementLoss` is what a retiring cycle dropped. Reference model; not RT-certified.

/// What `KernelCycle.retire()` dropped (round 2i, Copilot round 5): the events still pending in the retired cycle's
/// block buffer, never emitted, which no replacement sees (it starts with an empty buffer; a bounded carry-over is
/// E5c). A pending `noteOff` is not a drop: it records its tombstone instead. Each count is at most the retired
/// cycle's `blockCapacity`. A plain value; `NoteOwnership` keeps its counts as plain memory ordered by its claim
/// word, for the next claim only (see `releaseCycleClaim(_:loss:)`). Reference model; not RT-certified.
struct KernelRetirementLoss: Sendable, BitwiseCopyable, Equatable {
    /// `noteOn`s: lost notes, never stuck ones (never emitted or owned). Includes one drained from a lane still
    /// flushing (`KernelBlockEntry.flushed`), which a decide would have discarded anyway.
    private(set) var noteOns = 0
    /// `control` changes (stateful).
    private(set) var controls = 0
    /// `program` changes (stateful).
    private(set) var programs = 0
    /// `rampTo` targets (stateful).
    private(set) var ramps = 0
    /// Clock pulses: timing, not receiver or parameter state, so not stateful.
    private(set) var clockPulses = 0

    /// Stateful events dropped: `controls + programs + ramps`.
    var stateful: Int { controls &+ programs &+ ramps }

    /// A stateful event was dropped, so the receiver's program or controllers, or a parameter's ramp target, may be
    /// stale: control must reconcile them (re-send the current program, controllers and ramp targets) before
    /// relying on them.
    var receiverStateMayBeStale: Bool { stateful > 0 }

    /// Counts `payload`, dropped by a retirement; a `noteOff` is not counted (it records its tombstone instead).
    mutating func drop(_ payload: KernelEventPayload) {
        switch payload {
        case .noteOn: noteOns &+= 1
        case .noteOff: break
        case .control: controls &+= 1
        case .program: programs &+= 1
        case .rampTo: ramps &+= 1
        case .clockPulse: clockPulses &+= 1
        }
    }
}

/// Render-owned record of sounding notes: a fixed bitset of 16 channels × 128 notes for each scope.
/// Reference model; not RT-certified.
///
/// Storage is one allocation of `scopes × 32` `UInt64` words made in `init` (word `channel * 2 + note / 64` of
/// the scope's 32, bit `note % 64`). A single thread (render) owns the instance, so the words are plain memory,
/// not atomics. Every hot-path method range-checks `scope`, `channel` and `note` and never traps.
///
/// It also owns the scopes' `ReleaseTombstones` (allocated in `init`, same scopes and key space), so every
/// `KernelCycle` sharing this ownership shares its release history too, exactly when it shares the notes, and the
/// two can never be passed apart (round 2g). Its cycle claim, and the retirement loss each release leaves for the
/// next claim, are the only cross-thread state: `KernelCycle.init` (control) claims it and `KernelCycle.retire()`
/// (render) hands it back; see `claimForCycle(fresh:from:)` and `releaseCycleClaim(_:loss:)`.
///
/// Retirement loss (rounds 2i and 2j). The loss is five plain `Int` fields, one per count (so an optimized TSan build
/// sees a race on any of them; TSan does not race-check a `__tsan_memcpy` copy, such as a whole struct's), ordered by
/// the claim word and never read or written outside a claim. `releaseCycleClaim` writes them only while its claim is
/// still held (an odd word only its holder can move), then hands the claim back with a releasing compare-exchange.
/// `claimForCycle` reads them only after its acquiring compare-exchange has succeeded, reading the even word that
/// release wrote (only a release writes an even nonzero word). So the writes happen-before the reads. The next write
/// needs the next claim, whose holder's read happens-before its own retire (the host hands the prepared cycle to render
/// through its own release/acquire, which any render use of the cycle needs), so writes and reads alternate with no
/// data race. A never-claimed word (0) reads the initial, empty loss. A claim inherits only its immediate predecessor's
/// loss, never a sum over earlier retirements, so control checks `KernelCycle.inheritedRetirementLoss` on every
/// replacement. The `== claim.held` guard is defense in depth behind `KernelCycle.retire()`'s `retired` flag (which
/// already releases each claim once): a stale direct release neither frees a later claim nor overwrites the loss its
/// holder left.
///
/// Teardown (round 2h). Render must `retire()` the last cycle over this ownership before that cycle is released;
/// a cycle dropped without it keeps the claim forever, so no cycle can be prepared over this ownership again
/// (fail-closed: nothing sounds twice, but nothing new sounds through it either). If retiring is impossible, the
/// recovery is a full panic (all notes off) and a new `NoteOwnership`, accepting the loss of the old tombstones.
/// A control-side forced release is a follow-up, not modelled.
final class NoteOwnership: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        /// `scopes` is outside `1...maximumScopes`.
        case scopeCountOutOfRange(Int)
    }

    /// Largest scope count (inclusive): 256 scopes use 256 × 32 × 8 bytes = 64 KiB.
    static let maximumScopes = 256
    static let channels = 16
    static let notesPerChannel = 128
    /// Most notes one scope can own, and so the most `releaseAll` can emit: 16 × 128 = 2,048.
    static let maximumNotesPerScope = channels * notesPerChannel
    static let wordsPerScope = maximumNotesPerScope / UInt64.bitWidth

    /// Why `claimForCycle(_:fresh:)` refused; nothing changed.
    enum CycleClaimRefusal: Error, Equatable, Sendable {
        /// A `.freshFanIn` cycle, but a cycle was already built over this ownership.
        case alreadyUsed
        /// The cycle last built over this ownership has not `retire()`d.
        case predecessorNotRetired
    }

    /// The claim word's state when `claimForCycle(fresh:from:)` began: what it compare-exchanges from, so the
    /// freshness check and the claim are one atomic step. Only `cycleClaimState()` makes one.
    struct CycleClaimState: Equatable, Sendable {
        fileprivate let word: UInt64
    }

    /// A held claim; `releaseCycleClaim` hands it back. Only `claimForCycle(fresh:from:)` makes one.
    struct CycleClaim: Equatable, Sendable {
        fileprivate let held: UInt64
        /// What the claim's immediate predecessor dropped at retirement (its `releaseCycleClaim` loss; not
        /// cumulative), read after this claim's acquire; empty when no cycle retired over the ownership before.
        let inherited: KernelRetirementLoss
    }

    let scopeCount: Int
    /// The latest release frame per note key, shared by every cycle over this ownership; render only after init.
    let tombstones: ReleaseTombstones
    private let words: UnsafeMutablePointer<UInt64>
    /// The cycle claim, one word (round 2h, Copilot round 4): 0 never claimed; odd held; even and nonzero free
    /// after a retire. Each claim adds 1 and each release adds 1, so "ever claimed" lives in the same word as the
    /// claim and a `.freshFanIn` claim can compare-exchange only from 0.
    private let liveCycle = Atomic<UInt64>(0)
    /// The latest retirement's loss, one plain field per count (round 2j): written by the claim's holder before its
    /// release, read by the next claim after its acquire (see the type's Retirement loss).
    private var lostNoteOns = 0
    private var lostControls = 0
    private var lostPrograms = 0
    private var lostRamps = 0
    private var lostClockPulses = 0

    init(scopes: Int) throws(PreparationError) {
        guard scopes >= 1, scopes <= Self.maximumScopes else { throw .scopeCountOutOfRange(scopes) }
        scopeCount = scopes
        tombstones = ReleaseTombstones(scopes: scopes)
        let count = scopes * Self.wordsPerScope
        words = UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        words.initialize(repeating: 0, count: count)
    }

    /// Control only, from `KernelCycle.init`, before it makes anything: the claim word now. Acquire pairs with
    /// `releaseCycleClaim`'s release, so a claim seen handed back follows the retiring cycle's tombstone writes.
    func cycleClaimState() -> CycleClaimState {
        CycleClaimState(word: liveCycle.load(ordering: .acquiring))
    }

    /// Why a cycle could not claim from `state` (`fresh`: a `.freshFanIn` start), or `nil`.
    static func cycleClaimRefusal(_ state: CycleClaimState, fresh: Bool) -> CycleClaimRefusal? {
        refusal(state.word, fresh: fresh)
    }

    /// Control only, last in `KernelCycle.init`: claims this ownership from exactly `state` with one
    /// compare-exchange, or refuses (changing nothing) when `state` refuses or the word moved since: another
    /// preparation raced this one. A `.freshFanIn` claim succeeds only from the never-claimed word, so a cycle that
    /// claimed, ran and retired after `state` was read makes it `.alreadyUsed`, never a fresh start over used
    /// ownership. A word worn out by 2^63 claims refuses every claim (`.alreadyUsed`) rather than wrap. The claim
    /// carries the predecessor's retirement loss, read only after the compare-exchange succeeded (acquire).
    func claimForCycle(fresh: Bool, from state: CycleClaimState) throws(CycleClaimRefusal) -> CycleClaim {
        if let refusal = Self.refusal(state.word, fresh: fresh) { throw refusal }
        let (claimed, current) = liveCycle.compareExchange(expected: state.word, desired: state.word &+ 1,
                                                           successOrdering: .acquiring, failureOrdering: .acquiring)
        guard claimed else { throw Self.refusal(current, fresh: fresh) ?? .predecessorNotRetired }
        let inherited = KernelRetirementLoss(noteOns: lostNoteOns, controls: lostControls, programs: lostPrograms,
                                             ramps: lostRamps, clockPulses: lostClockPulses)
        return CycleClaim(held: state.word &+ 1, inherited: inherited)
    }

    /// Render only, from `KernelCycle.retire()`, after its tombstone writes: while `claim` is still held, records
    /// `loss` for the next claim, then hands `claim` back (a stale or repeated release changes neither the claim
    /// nor the recorded loss). Release publishes those writes and `loss` to the next claim.
    func releaseCycleClaim(_ claim: CycleClaim, loss: KernelRetirementLoss) {
        // Only the holder can move an odd word, so a held claim stays held until the compare-exchange below.
        if liveCycle.load(ordering: .relaxed) == claim.held {
            lostNoteOns = loss.noteOns
            lostControls = loss.controls
            lostPrograms = loss.programs
            lostRamps = loss.ramps
            lostClockPulses = loss.clockPulses
        }
        _ = liveCycle.compareExchange(expected: claim.held, desired: claim.held &+ 1, successOrdering: .releasing,
                                      failureOrdering: .relaxed)
    }

    private static func refusal(_ word: UInt64, fresh: Bool) -> CycleClaimRefusal? {
        if word == 0 { return nil }
        if fresh { return .alreadyUsed }
        if word & 1 != 0 { return .predecessorNotRetired }
        return word >= UInt64.max &- 1 ? .alreadyUsed : nil
    }

    /// Control-side teardown only.
    deinit {
        words.deinitialize(count: scopeCount &* Self.wordsPerScope)
        words.deallocate()
    }

    /// Marks the note owned. A duplicate `noteOn` for an owned note is idempotent and returns `.ok`.
    /// Returns `.refused(.slotOutOfRange)` when `scope`, `channel` or `note` is out of range.
    func noteOn(scope: UInt32, channel: UInt8, note: UInt8) -> KernelStatus {
        guard let index = wordIndex(scope: scope, channel: channel, note: note) else {
            return .refused(.slotOutOfRange)
        }
        words[index] |= Self.bit(note)
        return .ok
    }

    /// Clears ownership and returns `true` if the note was owned. An unowned or out-of-range note is a harmless
    /// no-op that returns `false` and leaves ownership unchanged.
    func noteOff(scope: UInt32, channel: UInt8, note: UInt8) -> Bool {
        guard let index = wordIndex(scope: scope, channel: channel, note: note) else { return false }
        let bit = Self.bit(note)
        guard words[index] & bit != 0 else { return false }
        words[index] &= ~bit
        return true
    }

    /// Calls `emit(channel, note)` once for each owned note in `scope`, clears them and returns the count.
    /// Visits exactly 32 words, in order, and emits at most 2,048 notes; an out-of-range scope returns 0.
    ///
    /// Re-entrancy: each word is cleared before its notes are emitted. A `noteOn` from inside `emit` into the
    /// word being emitted or an earlier word stays owned after `releaseAll` returns. A `noteOn` into a word not
    /// yet visited is released (emitted and counted) by the same call. A re-entrant `noteOff` for a note in the
    /// word being emitted (already in the local copy) or an earlier word returns `false`, and a note still in the
    /// local copy is emitted anyway; for a note in a word not yet visited it returns `true` and that note is not
    /// emitted.
    func releaseAll(scope: UInt32, _ emit: (UInt8, UInt8) -> Void) -> Int {
        guard let base = scopeBase(scope) else { return 0 }
        var released = 0
        for offset in 0..<Self.wordsPerScope {
            var bits = words[base &+ offset]
            words[base &+ offset] = 0
            let channel = UInt8(truncatingIfNeeded: offset &>> 1)
            let high = UInt8(truncatingIfNeeded: (offset & 1) &<< 6)
            while bits != 0 {
                let low = UInt8(truncatingIfNeeded: bits.trailingZeroBitCount)
                bits &= bits &- 1
                emit(channel, high | low)
                released &+= 1
            }
        }
        return released
    }

    /// Like `releaseAll`, but releases at most `limit` owned notes of `scope`, the first in (channel, note) order,
    /// clearing each note's bit before its `emit`; the rest stay owned. Visits at most 32 words; returns the count
    /// (0 for `limit <= 0` or an out-of-range scope). `emit` must not call back.
    func releaseFirst(scope: UInt32, limit: Int, _ emit: (UInt8, UInt8) -> Void) -> Int {
        guard limit > 0, let base = scopeBase(scope) else { return 0 }
        var released = 0
        for offset in 0..<Self.wordsPerScope {
            let channel = UInt8(truncatingIfNeeded: offset &>> 1)
            let high = UInt8(truncatingIfNeeded: (offset & 1) &<< 6)
            while words[base &+ offset] != 0 {
                guard released < limit else { return released }
                let bits = words[base &+ offset]
                words[base &+ offset] = bits & (bits &- 1)
                emit(channel, high | UInt8(truncatingIfNeeded: bits.trailingZeroBitCount))
                released &+= 1
            }
        }
        return released
    }

    /// `false` for an unowned or out-of-range note.
    func isOwned(scope: UInt32, channel: UInt8, note: UInt8) -> Bool {
        guard let index = wordIndex(scope: scope, channel: channel, note: note) else { return false }
        return words[index] & Self.bit(note) != 0
    }

    /// Number of notes `scope` owns; 0 for an out-of-range scope.
    func ownedCount(scope: UInt32) -> Int {
        guard let base = scopeBase(scope) else { return 0 }
        var count = 0
        for offset in 0..<Self.wordsPerScope {
            count &+= words[base &+ offset].nonzeroBitCount
        }
        return count
    }

    private func scopeBase(_ scope: UInt32) -> Int? {
        guard scope < UInt32(truncatingIfNeeded: scopeCount) else { return nil }
        return Int(scope) &* Self.wordsPerScope
    }

    private func wordIndex(scope: UInt32, channel: UInt8, note: UInt8) -> Int? {
        guard let base = scopeBase(scope), Int(channel) < Self.channels, Int(note) < Self.notesPerChannel else {
            return nil
        }
        return base &+ Int(channel) &* 2 &+ Int(note &>> 6)
    }

    private static func bit(_ note: UInt8) -> UInt64 {
        1 &<< UInt64(note & 63)
    }
}

/// A safety request a scope can raise from any context. Reference model; not RT-certified.
enum SafetyFlag: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case panic, allNotesOff
}

/// The set of pending safety requests; bit `n` is the `SafetyFlag` whose raw value is `n`.
/// Reference model; not RT-certified.
struct SafetyFlagSet: OptionSet, Sendable, BitwiseCopyable {
    let rawValue: UInt8

    static let panic = SafetyFlagSet(rawValue: 1 &<< SafetyFlag.panic.rawValue)
    static let allNotesOff = SafetyFlagSet(rawValue: 1 &<< SafetyFlag.allNotesOff.rawValue)
}

/// Per-scope pending safety requests. Requests are idempotent bits, not a queue, so they cannot be exhausted or
/// overflow, and a request is never lost: it stays set until render takes it. Reference model; not RT-certified.
///
/// Storage is one `UnsafeMutablePointer<Atomic<UInt8>>` with one atomic byte per scope, allocated and
/// initialised in `init` and deinitialised in `deinit` (`Atomic` is `~Copyable`, so it cannot live in an
/// `Array`). One byte per scope keeps scopes independent: no scope's request contends with another's.
/// `request` is a releasing fetch-or and `take` an acquiring exchange with 0, so writes made before a request
/// happen-before the reads of the render cycle whose `take` returns it.
final class SafetyFlags: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        /// `scopes` is outside `1...maximumScopes`.
        case scopeCountOutOfRange(Int)
    }

    /// Largest scope count (inclusive); matches `NoteOwnership.maximumScopes`.
    static let maximumScopes = NoteOwnership.maximumScopes

    let scopeCount: Int
    private let flags: UnsafeMutablePointer<Atomic<UInt8>>

    init(scopes: Int) throws(PreparationError) {
        guard scopes >= 1, scopes <= Self.maximumScopes else { throw .scopeCountOutOfRange(scopes) }
        scopeCount = scopes
        flags = UnsafeMutablePointer<Atomic<UInt8>>.allocate(capacity: scopes)
        for offset in 0..<scopes {
            (flags + offset).initialize(to: Atomic(0))
        }
    }

    /// Control-side teardown only.
    deinit {
        flags.deinitialize(count: scopeCount)
        flags.deallocate()
    }

    /// Sets `flag` for `scope`. Safe from any context and idempotent. Returns `.ok`, or
    /// `.refused(.slotOutOfRange)` for an out-of-range scope.
    func request(_ flag: SafetyFlag, scope: UInt32) -> KernelStatus {
        guard scope < UInt32(truncatingIfNeeded: scopeCount) else { return .refused(.slotOutOfRange) }
        flags[Int(scope)].bitwiseOr(1 &<< flag.rawValue, ordering: .releasing)
        return .ok
    }

    /// Render: atomically takes and clears every pending request for `scope`; empty for an out-of-range scope.
    func take(scope: UInt32) -> SafetyFlagSet {
        guard scope < UInt32(truncatingIfNeeded: scopeCount) else { return [] }
        return SafetyFlagSet(rawValue: flags[Int(scope)].exchange(0, ordering: .acquiring))
    }
}
