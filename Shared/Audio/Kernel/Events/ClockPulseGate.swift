// #64 E2 clock pulse gate: render-owned rules that keep stale clock pulses from bursting out after a stall. Stale
// pulses are skipped and counted, emission is rate-limited per block, and any skip leaves a single resync request
// rather than a burst. Arithmetic never traps. Reference model; not RT-certified.

/// What render does with one clock pulse. Reference model; not RT-certified.
enum ClockPulseDecision: Sendable, Equatable, BitwiseCopyable {
    /// Emit the pulse.
    case emit
    /// The pulse is later than `staleTolerance` behind `blockStart`: skip it (counted in `skippedStale`).
    case skipStale
    /// The block already emitted `maximumPulsesPerBlock` pulses: skip it (counted in `rateLimited`).
    case rateLimited
}

/// Render-owned clock pulse gate. A value type mutated only by its render owner; nothing is shared, nothing is
/// allocated, and every method is bounded and non-throwing after `init`.
///
/// - Frames: pass the pulse's original `event.frame` as `pulseFrame`, never the frame `DeadlinePolicy` decided
///   (`dispatchLate` moves a late pulse to `blockStart`, which would make every stale pulse look fresh).
/// - Blocks: a block is identified by its `blockStart`. The first `admit` with a `blockStart` different from the
///   previous call's (forward, backward or after a relocation) starts a new block and resets the per-block count;
///   repeated calls with the same `blockStart` share one block's budget. No separate `beginBlock` call exists to
///   be forgotten. The caller (E5) gives each render cycle a distinct, advancing `blockStart` (monotonic render
///   sample time). Empty cycles: when `frames <= 0`, E5 drains no timed events and calls neither
///   `ClockPulseGate.admit` nor `DeadlinePolicy.decide` (safety and fault handling still run; producer-side
///   `DeadlinePolicy.admit` is unaffected), so an empty cycle is never a block here and two
///   cycles never share a budget.
/// - Staleness: a pulse is stale when `pulseFrame < blockStart` and `blockStart − pulseFrame > staleTolerance`,
///   using the exact unsigned distance, so `Int64.min` and `Int64.max` frames never trap. Stale is checked before
///   the rate limit, and a stale pulse does not spend the block's budget. Future pulses are not judged here:
///   `DeadlinePolicy` keeps them queued as `notYet`.
/// - Resync, once per stall: every skipped pulse (stale or rate-limited) means downstream lost pulses. The first
///   skip of a stall sets `resyncPending`; further skips in the same or following blocks do not set it again. The
///   gate re-arms only after it has seen a clean block (at least one `admit`, no skips): the first `admit` of the
///   next block re-arms it. So a continuous stall or sustained rate limiting across any number of blocks yields
///   exactly one marker until a clean block occurs. `resyncPending` survives emits and block changes until
///   `takeResync()` returns `true` once and clears it. A block the gate never sees (no pulses) is neither clean
///   nor skipped.
/// - Counters saturate at `UInt64.max`; `takeResync()` never changes them.
///
/// Reference model; not RT-certified.
struct ClockPulseGate: Sendable, Equatable, BitwiseCopyable {
    /// Why a gate could not be prepared.
    enum PreparationError: Error, Equatable, Sendable {
        /// Outside `1...maximumPulsesPerBlockLimit`.
        case maximumPulsesPerBlockOutOfRange(Int)
        /// Outside `0...KernelLimits.maximumHorizonFrames`.
        case staleToleranceOutOfRange(Int64)
    }

    /// Largest per-block pulse budget (inclusive): no more than one handoff's capacity.
    static let maximumPulsesPerBlockLimit = KernelLimits.maximumCapacity

    let maximumPulsesPerBlock: Int
    /// Largest lateness, in frames, at which a pulse is still emitted (inclusive).
    let staleTolerance: Int64
    /// Pulses skipped as stale; saturates.
    private(set) var skippedStale: UInt64
    /// Pulses skipped by the per-block limit; saturates.
    private(set) var rateLimited: UInt64
    /// The current continuous stall's first marker is waiting to be taken. One marker per stall: set by the stall's
    /// first skip, cleared only by `takeResync()`, and set again only after a genuinely clean block re-arms the gate.
    private(set) var resyncPending = false
    private var currentBlockStart: Int64?
    private var emittedInBlock = 0
    /// The current block has skipped a pulse.
    private var skippedInBlock = false
    /// The next skip may set `resyncPending` (no stall in progress).
    private var resyncArmed = true

    /// Control-side preparation. `startingSkippedStale` and `startingRateLimited` are test seams for saturation.
    init(maximumPulsesPerBlock: Int, staleTolerance: Int64, startingSkippedStale: UInt64 = 0,
         startingRateLimited: UInt64 = 0) throws(PreparationError) {
        guard maximumPulsesPerBlock >= 1, maximumPulsesPerBlock <= Self.maximumPulsesPerBlockLimit else {
            throw .maximumPulsesPerBlockOutOfRange(maximumPulsesPerBlock)
        }
        guard staleTolerance >= 0, staleTolerance <= KernelLimits.maximumHorizonFrames else {
            throw .staleToleranceOutOfRange(staleTolerance)
        }
        self.maximumPulsesPerBlock = maximumPulsesPerBlock
        self.staleTolerance = staleTolerance
        skippedStale = startingSkippedStale
        rateLimited = startingRateLimited
    }

    /// Render only. Decides one pulse in the block starting at `blockStart`.
    mutating func admit(pulseFrame: Int64, blockStart: Int64) -> ClockPulseDecision {
        if currentBlockStart != blockStart {
            if currentBlockStart != nil, !skippedInBlock { resyncArmed = true }  // The previous block was clean.
            currentBlockStart = blockStart
            emittedInBlock = 0
            skippedInBlock = false
        }
        if pulseFrame < blockStart,
           DeadlinePolicy.distance(from: pulseFrame, to: blockStart) > UInt64(bitPattern: staleTolerance) {
            skippedStale = Self.saturatingIncrement(skippedStale)
            noteSkip()
            return .skipStale
        }
        guard emittedInBlock < maximumPulsesPerBlock else {
            rateLimited = Self.saturatingIncrement(rateLimited)
            noteSkip()
            return .rateLimited
        }
        emittedInBlock &+= 1  // Bounded by `maximumPulsesPerBlock`.
        return .emit
    }

    /// Marks the block as skipped; the first skip of a stall raises the single resync.
    private mutating func noteSkip() {
        skippedInBlock = true
        if resyncArmed {
            resyncArmed = false
            resyncPending = true
        }
    }

    /// Render only. Returns `true` once per pending resync and clears it. It does not re-arm: only a clean block
    /// does, so taking every block during a stall still yields one marker per stall.
    mutating func takeResync() -> Bool {
        let pending = resyncPending
        resyncPending = false
        return pending
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? value : value &+ 1
    }
}
