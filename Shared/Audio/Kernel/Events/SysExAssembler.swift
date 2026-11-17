// #64 E4 SysEx assembly (owner default D12): UMP SysEx7 chunks are assembled per source in preallocated staging,
// and each complete message is copied once into a consumer-acknowledged byte pool. Its ref travels on a separate
// `.sysex` SPSC ring (R8), never on telemetry. Messages are delivered whole or discarded visibly; never truncated.
// Reference model; not RT-certified.
import Synchronization

/// The UMP SysEx7 packet status nibble. Reference model; not RT-certified.
enum SysExChunkStatus: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case complete = 0, start = 1, `continue` = 2, end = 3
}

/// The six data bytes of one UMP SysEx7 packet; only the first `count` are read.
typealias SysExChunkBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) // swiftlint:disable:this large_tuple

/// A delivered message: the `sequence`th delivery, `length` bytes at monotonic pool index `offset`, from `source`.
/// `sequence` gives the message an identity and position independent of its bytes, so the consumer never infers
/// order from placement (padding can make two different messages map to the same offset). Reference model; not
/// RT-certified.
struct SysExMessageRef: Sendable, BitwiseCopyable, Equatable {
    let sequence: UInt64
    let offset: UInt64
    let length: UInt32
    let source: UInt32
}

/// Assembles SysEx7 chunks from up to `sources` sources into complete messages. Reference model; not RT-certified.
///
/// Contexts. `accept` is the producer side and must be called from exactly one context at a time (the MIDI receive
/// path; #81 must verify or serialise it, which is why the output ring's policy must declare one producer).
/// `accept` holds this assembler's fault-chain token for the whole call, so a concurrent `accept` does not race:
/// it finds the token taken, changes no state, latches the authority's contended fault and returns
/// `.refused(.notOwner)` (counted in `contendedChunkCount`). `withMessage`, `release` and `receive` are the consumer
/// side and must be called only from the output ring's single consumer. The counters are readable from any context.
///
/// Exclusive production. `output` must be fresh (never pushed, so empty) and this assembler must be its only
/// producer for its whole life. `init` claims the ring's producer endpoint, but that only excludes other
/// `makeProducer()` claims: it cannot see refs already in the ring or stop code calling `output.tryPush` directly,
/// and such a foreign ref that happened to carry the next `sequence` and offset would be accepted. Validation
/// (`sequence`, offset, source and length bound) catches misordered, repeated and most stray refs, not forgeries.
///
/// Per source, a chunk moves a small state machine; the fault scope is `(handoff: scopeBase, target: source)`,
/// and the caller must prepare those scopes in `faults` (an unprepared scope is still counted by
/// `FaultChainAuthority.unknownScopeFaults`). Every fault is raised through the one chain `init` mints from
/// `faults`, never through `FaultLatch.raise` directly; observers read the authority's `isLatched` (which includes
/// the contended fault) and `hasContendedFault`. The authority never hands out its latch, so these faults
/// cannot share a latch with the kernel cycle's: give the assembler its own authority (#190 FLP4).
///
/// | Chunk | idle | open | discarding (after an overflow) |
/// |---|---|---|---|
/// | `complete` | deliver | `.sysexAborted`, deliver | deliver |
/// | `start` | open | `.sysexAborted`, open anew | open anew |
/// | `continue` | `.sysexAborted`, `.refused(.notOwner)` | append | `.refused(.invalidLength)` |
/// | `end` | `.sysexAborted`, `.refused(.notOwner)` | append, deliver | idle, `.refused(.invalidLength)` |
///
/// - An abort discards the open message and accepts the new chunk (UMP: a new start implies the old one ended).
/// - Appending past `maximumMessageBytes` discards the message, raises `.sysexOverflow` and returns
///   `.refused(.invalidLength)`; the rest of that message is swallowed without further faults.
/// - Delivery copies the staged bytes into the pool and pushes the ref. When the pool lacks acknowledged room or
///   the ring is full, the message is discarded, `.sysexOverflow` is raised and `.refused(.full)` returned; the
///   pool cursor does not move, so a refused message takes no space.
/// - `count > 6` returns `.refused(.invalidLength)` and an unknown source `.refused(.slotOutOfRange)`; neither
///   changes any state or raises a fault. Both are checked before the token is taken, so neither contends.
///
/// Every discarded message is counted in `discardedCount`. See `SysExPool` for the byte-ring ordering protocol.
///
/// Progress: `accept` is wait-free (no loops beyond a copy of at most `maximumMessageBytes`); it never blocks,
/// retries or allocates. Taking the token is one exchange, putting it back one store; a failed take is not
/// retried. The consumer methods are wait-free too.
///
/// Producer borrows. `accept` reaches the pool, the fault authority, the fault chain and the output ring only
/// through immutable `Unmanaged` aliases made in `init`, each used inside a synchronous `_withUnsafeGuaranteedRef`
/// that never escapes, so it adds no retain or release even unoptimised. `pool`, `authority`, `chain`, `output` and
/// the claimed producer endpoint stay the strong owners; the borrows rely only on the caller keeping the assembler
/// alive across each call and tearing it down from a quiescent control context. The push calls `SPSCRing.tryPush`
/// on `output` directly (which SPSCRing permits for composed handoffs) instead of the endpoint's forwarder, whose
/// stored strong `ring` would be retained; the endpoint is still claimed and held, so "Exclusive production" is
/// unchanged. The consumer methods still use the strong owners.
///
/// `@unchecked Sendable`: staging and per-source state are producer-only, and the pool is split as documented.
final class SysExAssembler: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        /// The output ring's purpose is not `.sysex` (R8).
        case policy(HandoffPolicyError)
        /// The output ring's producer endpoint was already claimed.
        case outputAlreadyClaimed
        /// `sources` is outside `1...maximumSources`.
        case sourcesOutOfRange(Int)
        /// `maximumMessageBytes` is outside `1...poolBytes / 2`, which guarantees a message always fits in an
        /// acknowledged-empty pool wherever the previous one ended.
        case maximumMessageBytesOutOfRange(Int)
        /// `poolBytes` is not a power of two in `2...maximumPoolBytes`.
        case poolBytesOutOfRange(Int)
        /// `faults` has minted its whole chain budget. Checked last, after the output's producer endpoint is
        /// claimed, so no other refusal consumes a budget unit; this one leaves `output` claimed (it had to be
        /// fresh and exclusive anyway).
        case chainBudgetExhausted
    }

    private enum Assembly: UInt8 {
        case idle, open, discarding
    }

    static let maximumSources = 256
    static let maximumPoolBytes = 1 << 20
    /// D12 defaults.
    static let defaultSources = 16
    static let defaultMaximumMessageBytes = 4_096
    static let defaultPoolBytes = 65_536
    /// Data bytes in one UMP SysEx7 packet.
    static let maximumChunkBytes = 6

    let sources: Int
    let maximumMessageBytes: Int
    let scopeBase: UInt16
    let output: SPSCRing<SysExMessageRef>

    /// The claimed producer endpoint, held for life so no other `makeProducer()` claim succeeds; pushes go through
    /// `outputRef` (see "Producer borrows").
    private let producer: SPSCRing<SysExMessageRef>.Producer
    private let authority: FaultChainAuthority
    /// This assembler's only fault chain, minted in `init`; `accept` holds its token for the whole call.
    private let chain: FaultChain
    private let pool: SysExPool
    /// Producer borrows of `output`, `authority`, `chain` and `pool`; never retained or released.
    private let outputRef: Unmanaged<SPSCRing<SysExMessageRef>>
    private let authorityRef: Unmanaged<FaultChainAuthority>
    private let chainRef: Unmanaged<FaultChain>
    private let poolRef: Unmanaged<SysExPool>
    /// `sources × maximumMessageBytes`; source `s` stages at `s * maximumMessageBytes`.
    private let staging: UnsafeMutablePointer<UInt8>
    private let lengths: UnsafeMutablePointer<Int>
    private let states: UnsafeMutablePointer<Assembly>
    /// Producer only: the `sequence` of the next delivered message.
    private var nextDelivery: UInt64
    /// Consumer only: the `sequence` of the oldest unacknowledged message.
    private var nextAcknowledgement: UInt64
    /// Consumer only: a ref `receive` popped but could not deliver yet, because earlier messages were popped
    /// directly and are still unacknowledged. Delivered by a later `receive`; never dropped.
    private var pending: SysExMessageRef?
    /// Consumer only: `true` while a `withMessage` or `receive` body runs.
    private var inBody = false
    private let emitted = Atomic<UInt64>(0)
    private let discarded = Atomic<UInt64>(0)
    private let contended = Atomic<UInt64>(0)

    /// Control-side preparation; allocates all staging and pool storage and mints one chain from `faults`.
    /// `output` must be fresh and exclusively this assembler's (see "Exclusive production"). `startingCursor` is a
    /// test seam that starts the pool cursors and the message `sequence` near the `UInt64` wrap.
    init(sources: Int = defaultSources, maximumMessageBytes: Int = defaultMaximumMessageBytes,
         poolBytes: Int = defaultPoolBytes, output: SPSCRing<SysExMessageRef>, faults: FaultChainAuthority,
         scopeBase: UInt16, startingCursor: UInt64 = 0) throws(PreparationError) {
        guard output.policy.purpose == .sysex else { throw .policy(.violates(.r8SysExSeparate)) }
        guard sources >= 1, sources <= Self.maximumSources else { throw .sourcesOutOfRange(sources) }
        guard poolBytes >= 2, poolBytes <= Self.maximumPoolBytes, poolBytes & (poolBytes &- 1) == 0 else {
            throw .poolBytesOutOfRange(poolBytes)
        }
        guard maximumMessageBytes >= 1, maximumMessageBytes <= poolBytes / 2 else {
            throw .maximumMessageBytesOutOfRange(maximumMessageBytes)
        }
        guard let producer = output.makeProducer() else { throw .outputAlreadyClaimed }
        guard let chain = faults.mintChain() else { throw .chainBudgetExhausted }
        self.producer = producer
        self.sources = sources
        self.maximumMessageBytes = maximumMessageBytes
        self.scopeBase = scopeBase
        self.output = output
        authority = faults
        self.chain = chain
        let pool = SysExPool(capacity: poolBytes, startingCursor: startingCursor)
        self.pool = pool
        outputRef = .passUnretained(output)
        authorityRef = .passUnretained(faults)
        chainRef = .passUnretained(chain)
        poolRef = .passUnretained(pool)
        nextDelivery = startingCursor
        nextAcknowledgement = startingCursor
        staging = .allocate(capacity: sources * maximumMessageBytes)
        staging.initialize(repeating: 0, count: sources * maximumMessageBytes)
        lengths = .allocate(capacity: sources)
        lengths.initialize(repeating: 0, count: sources)
        states = .allocate(capacity: sources)
        states.initialize(repeating: .idle, count: sources)
    }

    deinit {
        staging.deallocate()
        lengths.deallocate()
        states.deallocate()
    }

    /// Producer only. Accepts one UMP SysEx7 chunk of `count` data bytes; see the type's state table. `frame`
    /// stamps any fault raised. Holds the chain token from after the pure guards until return; a failed take (a
    /// concurrent `accept`) changes no assembler state and returns `.refused(.notOwner)`.
    func accept(source: UInt32, status: SysExChunkStatus, bytes: SysExChunkBytes, count: UInt8,
                frame: Int64 = 0) -> KernelStatus {
        guard Int(count) <= Self.maximumChunkBytes else { return .refused(.invalidLength) }
        guard source < UInt32(truncatingIfNeeded: sources) else { return .refused(.slotOutOfRange) }
        // `_withUnsafeGuaranteedRef` cannot return a noncopyable value or consume a captured one, so the token
        // crosses the borrow through this optional.
        var held: FaultChainToken?
        chainRef._withUnsafeGuaranteedRef { held = $0.take() }
        guard var token = held.take() else {
            authorityRef._withUnsafeGuaranteedRef { $0.raiseContended() }
            contended.wrappingAdd(1, ordering: .relaxed)
            return .refused(.notOwner)
        }
        let index = Int(source)
        let result: KernelStatus = switch status {
        case .complete: begin(index, bytes, count, frame, single: true, &token)
        case .start: begin(index, bytes, count, frame, single: false, &token)
        case .continue: extend(index, bytes, count, frame, final: false, &token)
        case .end: extend(index, bytes, count, frame, final: true, &token)
        }
        held = consume token
        chainRef._withUnsafeGuaranteedRef { chain in
            if let token = held.take() { _ = chain.put(token) }
        }
        return result
    }

    /// Consumer only. Calls `body` with the bytes of `ref` when it is the oldest unacknowledged message, without
    /// acknowledging it; otherwise returns `nil`. The buffer is valid only inside `body`. Consumer calls made from
    /// inside `body` are refused (`nil` or `.refused(.notOwner)`): a nested `release` would let the producer reuse
    /// the bytes `body` is still reading.
    /// Pass only unmodified refs popped from this assembler's `output`. Order and bounds checks do not authenticate
    /// the payload extent; altered or forged refs are outside the memory-safety contract.
    func withMessage<Result>(_ ref: SysExMessageRef, _ body: (UnsafeRawBufferPointer) -> Result) -> Result? {
        guard !inBody, isNext(ref) else { return nil }
        inBody = true
        defer { inBody = false }
        return body(pool.bytes(at: ref.offset, count: Int(ref.length)))
    }

    /// Consumer only. Acknowledges `ref`, the oldest unacknowledged message, after its bytes have been read, so
    /// the producer may reuse them. `.refused(.notOwner)` for any other ref (stale, repeated, out of order, from
    /// another lap or out of range) and inside a `withMessage` or `receive` body. Pass only unmodified refs popped
    /// from this assembler's `output`: an altered length within the bound is not detected. Altered or forged
    /// refs are outside the memory-safety contract, not guaranteed to fail closed.
    func release(_ ref: SysExMessageRef) -> KernelStatus {
        guard !inBody, isNext(ref) else { return .refused(.notOwner) }
        acknowledge(ref)
        return .ok
    }

    /// Consumer only. Delivers the next message to `body` and then acknowledges it. `.empty` when none is waiting.
    /// `.refused(.notOwner)` inside a body, or when refs popped directly from `output` are still unacknowledged:
    /// then the ref `receive` popped is kept (never lost) and no further ref is dequeued until it can be
    /// delivered. A ref that is neither next nor later (already acknowledged, or foreign) is dropped.
    @discardableResult
    func receive(_ body: (SysExMessageRef, UnsafeRawBufferPointer) -> Void) -> KernelStatus {
        guard !inBody else { return .refused(.notOwner) }
        let candidate = pending ?? output.tryPop()
        pending = nil
        guard let ref = candidate else { return .empty }
        guard isNext(ref) else {
            let ahead = ref.sequence &- nextAcknowledgement
            if ahead != 0, ahead < 1 << 63 { pending = ref }
            return .refused(.notOwner)
        }
        inBody = true
        body(ref, pool.bytes(at: ref.offset, count: Int(ref.length)))
        inBody = false
        acknowledge(ref)
        return .ok
    }

    /// Messages delivered on `output`; wraps only after 2^64.
    var emittedCount: UInt64 { emitted.load(ordering: .relaxed) }

    /// Messages discarded by overflow, abort, pool exhaustion or a full output ring; wraps only after 2^64.
    var discardedCount: UInt64 { discarded.load(ordering: .relaxed) }

    /// Chunks refused because another context held the chain token (each also latched the contended fault);
    /// wraps only after 2^64.
    var contendedChunkCount: UInt64 { contended.load(ordering: .relaxed) }

    /// Test seam, never on a producer path: runs `body` while holding this assembler's chain token, as a
    /// concurrent `accept` would, then puts it back. `false` without calling `body` when the token is not in its
    /// slot (held by an `accept` in progress, or lost). Never call it while a producer may run: every chunk in
    /// that window is refused as contended and latches the contended fault.
    func withChainTokenHeld(_ body: () -> Void) -> Bool {
        guard let token = chain.take() else { return false }
        body()
        return chain.put(token) == .ok
    }

    /// Consumer. `sequence` fixes which message is next; the offset check then pins it to where that message
    /// must start. Placement alone is ambiguous (a padded message can start where its successor would after a
    /// skipped acknowledgement), and an empty message leaves the byte cursor unchanged.
    private func isNext(_ ref: SysExMessageRef) -> Bool {
        ref.sequence == nextAcknowledgement && ref.source < UInt32(truncatingIfNeeded: sources)
            && Int(ref.length) <= maximumMessageBytes && pool.isNext(offset: ref.offset, length: Int(ref.length))
    }

    /// Consumer. Hands `ref`'s bytes back to the producer (release ordering, in `SysExPool`) and moves on.
    private func acknowledge(_ ref: SysExMessageRef) {
        pool.release(end: ref.offset &+ UInt64(ref.length))
        nextAcknowledgement &+= 1
    }

    /// `complete` or `start`: aborts an open message, then opens a new one; `complete` also delivers it.
    private func begin( // swiftlint:disable:this function_parameter_count
        _ index: Int, _ bytes: SysExChunkBytes, _ count: UInt8, _ frame: Int64, single: Bool,
        _ token: inout FaultChainToken
    ) -> KernelStatus {
        if states[index] == .open { discard(index, .sysexAborted, frame, &token) }
        states[index] = .open
        lengths[index] = 0
        guard append(index, bytes, count) else {
            return overflow(index, frame, next: single ? .idle : .discarding, &token)
        }
        return single ? deliver(index, frame, &token) : .ok
    }

    /// `continue` or `end`: appends to the open message; `end` also delivers it.
    private func extend( // swiftlint:disable:this function_parameter_count
        _ index: Int, _ bytes: SysExChunkBytes, _ count: UInt8, _ frame: Int64, final: Bool,
        _ token: inout FaultChainToken
    ) -> KernelStatus {
        switch states[index] {
        case .idle:
            raise(index, .sysexAborted, frame, &token)
            return .refused(.notOwner)
        case .discarding:
            if final { states[index] = .idle }
            return .refused(.invalidLength)
        case .open:
            guard append(index, bytes, count) else {
                return overflow(index, frame, next: final ? .idle : .discarding, &token)
            }
            return final ? deliver(index, frame, &token) : .ok
        }
    }

    /// Appends `count` (≤ 6) bytes to `index`'s staging, or returns `false` without writing when they would exceed
    /// `maximumMessageBytes`. Six count-guarded scalar stores, not a closure over the tuple, which would capture
    /// `self` and, unoptimised, instantiate the tuple's metadata.
    private func append(_ index: Int, _ bytes: SysExChunkBytes, _ count: UInt8) -> Bool {
        let length = lengths[index]
        let added = Int(count)
        guard added <= maximumMessageBytes &- length else { return false }
        let target = staging + (index &* maximumMessageBytes &+ length)
        if added > 0 { target[0] = bytes.0 }
        if added > 1 { target[1] = bytes.1 }
        if added > 2 { target[2] = bytes.2 }
        if added > 3 { target[3] = bytes.3 }
        if added > 4 { target[4] = bytes.4 }
        if added > 5 { target[5] = bytes.5 }
        lengths[index] = length &+ added
        return true
    }

    private func overflow(_ index: Int, _ frame: Int64, next: Assembly,
                          _ token: inout FaultChainToken) -> KernelStatus {
        discard(index, .sysexOverflow, frame, &token)
        states[index] = next
        return .refused(.invalidLength)
    }

    /// Copies the staged message into the pool and pushes its ref; the source returns to idle either way. Order:
    /// reserve, write, push, then commit and advance; a refusal moves neither the pool cursor nor `sequence`. The
    /// borrow closures capture only precomputed values, never `self`.
    private func deliver(_ index: Int, _ frame: Int64, _ token: inout FaultChainToken) -> KernelStatus {
        let length = lengths[index]
        states[index] = .idle
        lengths[index] = 0
        guard let start = poolRef._withUnsafeGuaranteedRef({ $0.reserve(length: length) }) else {
            discard(index, .sysexOverflow, frame, &token)
            return .refused(.full)
        }
        let staged = UnsafePointer(staging + index &* maximumMessageBytes)
        poolRef._withUnsafeGuaranteedRef { $0.write(staged, count: length, at: start) }
        let ref = SysExMessageRef(sequence: nextDelivery, offset: start, length: UInt32(truncatingIfNeeded: length),
                                  source: UInt32(truncatingIfNeeded: index))
        guard outputRef._withUnsafeGuaranteedRef({ $0.tryPush(ref) }) == .ok else {
            discard(index, .sysexOverflow, frame, &token)
            return .refused(.full)
        }
        let end = start &+ UInt64(truncatingIfNeeded: length)
        poolRef._withUnsafeGuaranteedRef { $0.commit(end: end) }
        nextDelivery &+= 1
        emitted.wrappingAdd(1, ordering: .relaxed)
        return .ok
    }

    private func discard(_ index: Int, _ kind: FaultKind, _ frame: Int64, _ token: inout FaultChainToken) {
        lengths[index] = 0
        discarded.wrappingAdd(1, ordering: .relaxed)
        raise(index, kind, frame, &token)
    }

    /// The only raise: on the authority, with the token `accept` holds. The closure captures the token and
    /// precomputed values, never `self`.
    private func raise(_ index: Int, _ kind: FaultKind, _ frame: Int64, _ token: inout FaultChainToken) {
        let scope = FaultScope(handoff: scopeBase, target: UInt32(truncatingIfNeeded: index))
        _ = authorityRef._withUnsafeGuaranteedRef { $0.raise(&token, scope, kind, frame: frame) }
    }
}
