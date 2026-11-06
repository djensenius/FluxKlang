// #64 E5b kernel cycle component: the preallocated block buffer and its (original frame, lane, producer lane,
// sequence) order, split by composition from `KernelCycle.swift`. Storage is private; the narrow API keeps the
// buffer ordered. Reference model; not RT-certified.

/// One drained event in the block buffer. Reference model; not RT-certified.
struct KernelBlockEntry: Sendable, BitwiseCopyable {
    let event: KernelEvent
    let producer: UInt8
    /// Drained from a lane still flushing: a `noteOn` is discarded whenever it is decided.
    let flushed: Bool

    /// Strict (original frame, lane, producer lane, sequence) order.
    static func precedes(_ lhs: KernelBlockEntry, _ rhs: KernelBlockEntry) -> Bool {
        if lhs.event.frame != rhs.event.frame { return lhs.event.frame < rhs.event.frame }
        if lhs.event.lane != rhs.event.lane { return lhs.event.lane < rhs.event.lane }
        if lhs.producer != rhs.producer { return lhs.producer < rhs.producer }
        return lhs.event.sequence < rhs.event.sequence
    }
}

/// A `KernelCycle`'s block buffer: `capacity` entries kept in `KernelBlockEntry.precedes` order, plus the merge
/// scratch, all allocated in `init`. Render only after init; owned privately by one `KernelCycle`.
/// Reference model; not RT-certified.
final class KernelBlockBuffer {
    let capacity: Int
    private let entries: UnsafeMutablePointer<KernelBlockEntry>
    /// Where a newly appended run is merge-sorted; `capacity` slots.
    private let scratch: UnsafeMutablePointer<KernelBlockEntry>
    private let used: UnsafeMutablePointer<Int>

    /// `capacity` must be at least 1 (`KernelCycle.init` checks its range).
    init(capacity: Int) {
        self.capacity = capacity
        entries = .allocate(capacity: capacity)
        scratch = .allocate(capacity: capacity)
        used = .allocate(capacity: 1)
        used.initialize(to: 0)
    }

    deinit {
        entries.deallocate()
        scratch.deallocate()
        used.deallocate()
    }

    /// Entries held, in order once `order(from:)` has run for the latest appends.
    var count: Int { used.pointee }

    /// Free entries.
    var room: Int { capacity &- used.pointee }

    subscript(index: Int) -> KernelBlockEntry { entries[index] }

    /// Appends `entry` when there is room; `false` (nothing stored) when full.
    func append(_ entry: KernelBlockEntry) -> Bool {
        guard used.pointee < capacity else { return false }
        (entries + used.pointee).initialize(to: entry)
        used.pointee &+= 1
        return true
    }

    /// Orders the run appended since `count` was `first` by a stable bottom-up merge sort that ping-pongs between
    /// the run and the scratch, then merges it stably behind the already ordered prefix `[0..<first]`. Equal keys
    /// keep their drain order and prefix entries precede run entries with equal keys.
    func order(from first: Int) {
        let total = used.pointee
        guard first >= 0, first < total else { return }
        let count = total &- first
        var source = entries + first
        var target = scratch
        var width = 1
        while width < count {
            var low = 0
            while low < count {
                let mid = min(low &+ width, count)
                let high = min(mid &+ width, count)
                Self.merge(source, low, mid, high, into: target)
                low = high
            }
            swap(&source, &target)
            width &*= 2
        }
        if source != scratch { scratch.initialize(from: source, count: count) }
        mergeBehindPrefix(first, count)
    }

    /// Removes the first `prefix` entries, moving the rest to the front.
    func removeFirst(_ prefix: Int) {
        guard prefix > 0 else { return }
        let total = used.pointee
        let removed = min(prefix, total)
        var index = removed
        while index < total {
            entries[index &- removed] = entries[index]
            index &+= 1
        }
        used.pointee = total &- removed
    }

    /// Keeps, in order, only the entries `keep` returns `true` for; visits each entry once, in order.
    func retain(_ keep: (KernelBlockEntry) -> Bool) {
        var kept = 0
        var index = 0
        let total = used.pointee
        while index < total {
            let entry = entries[index]
            index &+= 1
            guard keep(entry) else { continue }
            entries[kept] = entry
            kept &+= 1
        }
        used.pointee = kept
    }

    /// Merges the sorted run in `scratch[0..<count]` behind `entries[0..<prefix]`, from the back; on equal keys
    /// the run element takes the later slot.
    private func mergeBehindPrefix(_ prefix: Int, _ count: Int) {
        var left = prefix &- 1
        var right = count &- 1
        var out = prefix &+ count &- 1
        while right >= 0 {
            if left >= 0, KernelBlockEntry.precedes(scratch[right], entries[left]) {
                entries[out] = entries[left]
                left &-= 1
            } else {
                entries[out] = scratch[right]
                right &-= 1
            }
            out &-= 1
        }
    }

    /// Stably merges `source[low..<mid]` and `source[mid..<high]` into `target[low..<high]`.
    private static func merge(_ source: UnsafeMutablePointer<KernelBlockEntry>, _ low: Int, _ mid: Int, _ high: Int,
                              into target: UnsafeMutablePointer<KernelBlockEntry>) {
        var left = low
        var right = mid
        var out = low
        while out < high {
            if right < high, left == mid || KernelBlockEntry.precedes(source[right], source[left]) {
                (target + out).initialize(to: source[right])
                right &+= 1
            } else {
                (target + out).initialize(to: source[left])
                left &+= 1
            }
            out &+= 1
        }
    }
}
