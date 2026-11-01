// #64 E4 SysEx byte pool: a preallocated byte ring whose space is reclaimed only when the consumer explicitly
// acknowledges a message, never when a ref leaves the output ring. Reference model; not RT-certified.
import Synchronization

/// A single-producer single-consumer byte ring for completed SysEx messages, owned by `SysExAssembler`.
/// Reference model; not RT-certified.
///
/// Cursors. `written` (producer-owned, plain) and `released` (consumer-stored atomic) are monotonically
/// increasing `UInt64` byte indices that wrap with `&+`; `written &- released` is the number of bytes the
/// consumer has not yet acknowledged, at most `capacity`. `capacity` is a power of two, so `index & mask` stays
/// continuous where an index wraps past `UInt64.max`. Messages are contiguous: one that would straddle the
/// physical end starts at the next lap instead, and its padding is reclaimed together with it. The placement
/// (`place`) is a pure function of the previous message's end and the length, so the consumer recomputes
/// where the next message must start. Placement alone does not identify the message: with padding, a later
/// message can start exactly where the next one would after a skipped acknowledgement, and an empty message
/// does not move the cursor. `SysExAssembler` therefore checks the ref's `sequence` first and uses `isNext` only
/// to pin that message's offset. Offsets are compared at full `UInt64` width, so a ref from an earlier lap can
/// never pass for the current one (no ABA before 2^64 bytes).
///
/// Protocol and ordering.
/// - Producer → consumer: the producer copies bytes into free space and only then pushes the ref on the output
///   `SPSCRing`, whose `tail` store is releasing; the consumer acquires `tail` when it pops the ref, so the bytes
///   happen before its read. This pool adds no edge in that direction.
/// - Consumer → producer: the ring's `head` is not a reclamation signal, because `SPSCRing.popAll` publishes
///   `head` before calling `body`. Instead the consumer reads the bytes, then stores `released` *releasing*; the
///   producer loads `released` *acquiring* before choosing space. The consumer's reads therefore happen before
///   any producer write that reuses those bytes. With relaxed ordering on either side, nothing orders the
///   consumer's byte loads before the producer's later stores to the same bytes: the hardware may perform the
///   `released` store before the loads complete, the producer may overwrite a message mid-read, and the overlap
///   is a data race (undefined behaviour) in the Swift memory model.
///
/// Progress: wait-free. Every method is a constant number of atomic operations plus one bounded copy.
///
/// `@unchecked Sendable`: `reserve`, `write` and `commit` must be called only from the single producer context
/// and `isNext`, `bytes` and `release` only from the single consumer context; `SysExAssembler` documents and
/// exposes that split.
final class SysExPool: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<UInt8>
    private let mask: UInt64
    private let size: UInt64
    /// End of the last acknowledged message. Stored only by the consumer (releasing); the producer acquires it.
    private let released: Atomic<UInt64>
    /// Producer only: end of the last delivered message.
    private var written: UInt64

    /// Control-side. `capacity` must be a power of two; `SysExAssembler` validates it.
    init(capacity: Int, startingCursor: UInt64) {
        self.capacity = capacity
        size = UInt64(truncatingIfNeeded: capacity)
        mask = size &- 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        released = Atomic(startingCursor)
        written = startingCursor
    }

    deinit {
        storage.deallocate()
    }

    /// Where a message of `length` bytes goes when the previous one ended at `cursor`: at `cursor`, or at the
    /// start of the next lap when it would otherwise straddle the physical end. Requires `length <= capacity`.
    private func place(after cursor: UInt64, length: Int) -> UInt64 {
        let room = size &- (cursor & mask)
        return room >= UInt64(truncatingIfNeeded: length) ? cursor : cursor &+ room
    }

    /// Producer. The start index for `length` contiguous bytes (`length <= capacity`), or `nil` when the
    /// unacknowledged bytes leave too little room. Never overwrites unacknowledged bytes.
    func reserve(length: Int) -> UInt64? {
        let used = written &- released.load(ordering: .acquiring)
        // `used > size` only if a consumer released a ref it never received; refuse rather than overwrite.
        guard used <= size else { return nil }
        let start = place(after: written, length: length)
        guard (start &- written) &+ UInt64(truncatingIfNeeded: length) <= size &- used else { return nil }
        return start
    }

    /// Producer. Copies `count` bytes to the space `reserve` returned for `start`. A plain byte loop rather than
    /// `update(from:count:)`/`copyMemory`: ThreadSanitizer does not observe those bulk copies in Swift builds
    /// (verified: an unsynchronised write/read pair went unreported), so it could not check reclamation.
    func write(_ bytes: UnsafePointer<UInt8>, count: Int, at start: UInt64) {
        let target = storage + Int(truncatingIfNeeded: start & mask)
        var index = 0
        while index < count {
            target[index] = bytes[index]
            index &+= 1
        }
    }

    /// Producer. Records that the message ending at `end` was delivered on the output ring.
    func commit(end: UInt64) {
        written = end
    }

    /// Consumer. `true` when `offset` is where the oldest unacknowledged message of `length` bytes must start. Only
    /// meaningful once the caller has established, by `sequence`, that the ref is that message.
    func isNext(offset: UInt64, length: Int) -> Bool {
        offset == place(after: released.load(ordering: .relaxed), length: length)
    }

    /// Consumer. The bytes of a message `isNext` accepted; valid only until `release`.
    func bytes(at offset: UInt64, count: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: storage + Int(truncatingIfNeeded: offset & mask), count: count)
    }

    /// Consumer. Hands every byte before `end` back to the producer, after the caller has finished reading them.
    func release(end: UInt64) {
        released.store(end, ordering: .releasing)
    }
}
