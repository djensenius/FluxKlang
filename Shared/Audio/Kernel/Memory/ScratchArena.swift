// #64 M7 scratch arena: raw bytes allocated once when a plan is prepared, handed out by a bump cursor during a
// render cycle and reused every cycle. Storage is allocated in `init` and released only in `deinit`. Reference
// model; not RT-certified.

/// Per-cycle scratch memory for one prepared plan. Reference model; not RT-certified.
///
/// Control prepares the arena (`init` allocates `byteCapacity` bytes once, aligned to `alignment`) and hands it
/// to its single owner, which for a `PreparedPlanSlot` is render. The owner calls `resetCycle()` at each cycle
/// boundary and `take(_:count:)` during the cycle. `take` bumps one cursor and `resetCycle` rewinds it, so every
/// cycle reuses the same bytes.
///
/// `take` either returns a whole buffer of `count` elements or `nil`; never a partial buffer. A buffer starts on
/// a multiple of `max(alignment, MemoryLayout<T>.alignment)` of its absolute address, and the padding needed to
/// get there is consumed. Requests that cannot fit are refused, counted in `exhaustedCount` and leave the cursor
/// where it was: negative counts, counts whose `count * stride` overflows (checked with overflow-reporting
/// multiplication) and anything larger than the room left after padding.
///
/// Pointer lifetime:
/// - A buffer is valid from `take` until the next `resetCycle()` (for a slot, the next `beginCycle`) or until
///   the arena is released, whichever comes first. `resetCycle` invalidates every buffer taken before it,
///   although the address may be handed out again.
/// - Buffers belong to the cycle that took them. They must not be stored, returned from the cycle or shared
///   with another thread, and must not be read after `resetCycle`.
/// - Contents are unspecified when taken, so initialise before reading. Each `take` binds the memory to `T`;
///   a later cycle may bind the same bytes to another type, which is why older buffers must not be used.
/// - Within one cycle buffers never overlap.
///
/// `highWater` (the largest cursor any cycle reached, padding included) and `exhaustedCount` (refused takes,
/// saturating at `UInt64.max`) persist across cycles and are owner-only reads.
///
/// Progress (source level only). `take` is one bounded claim: overflow-reporting arithmetic, comparisons and at
/// most two plain stores, with no loop, atomic, lock, allocation, release or trapping operator in this source.
/// `resetCycle` is one plain store. Generated code is not proved here. In the inspected scratch configurations
/// unspecialised `take` (all `-Onone` code) still calls out-of-line stdlib generics (`max`, and
/// `UnsafeMutableBufferPointer.init(start:count:)`, whose debug preconditions the guards above already exclude)
/// and `-Onone` exclusivity checks (`swift_beginAccess`). A caller passing an element type whose metadata is not
/// static (a generic type such as `SIMD4<Float>`) from unspecialised code instantiates that metadata itself; a
/// first request may lock and allocate in the runtime. The allocation, lock, metadata and trap checks cover only
/// those configurations and known element types. Not an RT certification; this slice does not accept or waive
/// #64's final-target hot-path qualification.
///
/// Lifetime (documented, not enforced). Construct and destroy an arena on control only: `init` allocates and
/// `deinit` frees. Release the last reference only once the owner is quiescent, with no `take`, `resetCycle` or
/// buffer use in flight or still to come; a slot ensures that through M6 retirement or render detachment (D10).
/// Render must never release the last reference. Each caller keeps the arena strongly alive for its calls and
/// for every use of a buffer it took.
///
/// `@unchecked Sendable`: `byteCapacity` and `alignment` are immutable. The cursor and counters are plain
/// stored properties owned by one context at a time; the arena is handed from control to render only through
/// a publication that orders `init` before render's first access (the M6 exchange inside `PreparedPlanSlot`),
/// and it is released on control only after render retired it (M6) or detached (teardown, D10).
final class ScratchArena: @unchecked Sendable {
    /// Why `init` refused to prepare an arena.
    enum PreparationError: Error, Equatable, Sendable {
        /// `byteCapacity` is not in `1...maximumByteCapacity`.
        case byteCapacity(Int)
        /// `alignment` is not a power of two in `1...maximumAlignment`.
        case alignment(Int)
    }

    /// The largest arena `init` prepares (16 MiB).
    static let maximumByteCapacity = 1 << 24
    /// The largest alignment `init` accepts, one 4 KiB page.
    static let maximumAlignment = 4_096

    let byteCapacity: Int
    let alignment: Int

    private let storage: UnsafeMutableRawPointer
    /// Owner-only; bytes consumed this cycle, padding included. Always in `0...byteCapacity`.
    private var used = 0
    private var maximumUsed = 0
    private var refusals: UInt64 = 0

    /// Control-side preparation: validates the geometry, then allocates the storage once. Capacity is checked
    /// before alignment.
    init(byteCapacity: Int, alignment: Int) throws(PreparationError) {
        guard byteCapacity >= 1, byteCapacity <= Self.maximumByteCapacity else {
            throw .byteCapacity(byteCapacity)
        }
        // `>= 1` first: `Int.min & (Int.min - 1)` would pass the power-of-two test.
        guard alignment >= 1, alignment <= Self.maximumAlignment, alignment & (alignment &- 1) == 0 else {
            throw .alignment(alignment)
        }
        self.byteCapacity = byteCapacity
        self.alignment = alignment
        storage = UnsafeMutableRawPointer.allocate(byteCount: byteCapacity, alignment: alignment)
    }

    /// Control-side; runs only when the last reference is released, which a slot does on control.
    deinit {
        storage.deallocate()
    }

    /// Owner (render). Starts a new cycle on the same storage: rewinds the cursor and invalidates every buffer
    /// taken so far. Keeps `highWater` and `exhaustedCount`; never allocates.
    func resetCycle() {
        used = 0
    }

    /// Owner (render). A buffer of exactly `count` elements of `T`, aligned to `max(alignment, T's alignment)`
    /// and valid until the next `resetCycle()`; or `nil` (counted in `exhaustedCount`, cursor unchanged) when
    /// `count` is negative, `count * stride` overflows or the rest of this cycle's bytes cannot hold it. A zero
    /// `count` returns an empty buffer with a `nil` base address, consumes nothing and is not counted.
    func take<T: BitwiseCopyable>(_ type: T.Type, count: Int) -> UnsafeMutableBufferPointer<T>? {
        if count == 0 { return UnsafeMutableBufferPointer(start: nil, count: 0) }
        let layout = MemoryLayout<T>.self
        guard let start = claim(count: count, stride: layout.stride, alignment: layout.alignment) else {
            return nil
        }
        return UnsafeMutableBufferPointer(start: start.bindMemory(to: type, capacity: count), count: count)
    }

    /// Largest number of bytes any cycle has consumed, padding included. Owner-only read.
    var highWater: Int { maximumUsed }

    /// Refused `take`s since `init`; saturates at `UInt64.max`. Owner-only read.
    var exhaustedCount: UInt64 { refusals }

    /// Test seam: the storage address, which never changes after `init`.
    var storageBaseAddress: UnsafeRawPointer { UnsafeRawPointer(storage) }

    /// Moves the cursor past `count * stride` bytes at the next address aligned to `max(alignment, typeAlignment)`
    /// and returns where they start, or counts a refusal and returns `nil`. `stride >= 1` and `typeAlignment` is a
    /// power of two (both from `MemoryLayout`). The wrapping operators below never wrap: `used <= byteCapacity`,
    /// `padding` is less than the effective alignment and every sum stays within `byteCapacity`. Past the first
    /// two conditions `bytes >= 1`, so padding that alone overruns (`room - padding < 0`) refuses too.
    private func claim(count: Int, stride: Int, alignment typeAlignment: Int) -> UnsafeMutableRawPointer? {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: stride)
        let mask = UInt(bitPattern: max(alignment, typeAlignment) &- 1)
        let misalignment = (UInt(bitPattern: storage) &+ UInt(bitPattern: used)) & mask
        let padding = Int(bitPattern: (mask &+ 1 &- misalignment) & mask)
        let room = byteCapacity &- used
        guard count > 0, !overflow, bytes <= room &- padding else {
            if refusals != .max { refusals &+= 1 }
            return nil
        }
        let start = storage.advanced(by: used &+ padding)
        used = used &+ padding &+ bytes
        if used > maximumUsed { maximumUsed = used }
        return start
    }
}
