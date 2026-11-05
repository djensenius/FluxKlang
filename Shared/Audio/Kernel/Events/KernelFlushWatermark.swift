// #64 E5b kernel cycle component: the flush watermark and the fair drain into the block buffer, split by
// composition from `KernelCycle.swift`. Storage is private. Reference model; not RT-certified.

/// One flush bit per fan-in lane (see `KernelCycle`'s Flush watermark) and the drain that clears them. All
/// storage is allocated in `init`. Render only after init; owned privately by one `KernelCycle`.
/// Reference model; not RT-certified.
final class KernelFlushWatermark {
    let laneCount: Int
    private let lanes: UnsafeMutablePointer<Bool>
    /// The number of set bits.
    private let flushing: UnsafeMutablePointer<Int>
    /// Drained events `block.append` refused, saturating.
    private let refusedAppends: UnsafeMutablePointer<UInt64>

    /// `armed` starts with every lane's bit set, as after `arm()`: a replacement cycle's fail-safe start (see
    /// `KernelCycleStart`). Each bit then clears only once its lane is proved empty.
    init(laneCount: Int, armed: Bool) {
        self.laneCount = laneCount
        lanes = .allocate(capacity: laneCount)
        lanes.initialize(repeating: armed, count: laneCount)
        flushing = .allocate(capacity: 1)
        flushing.initialize(to: armed ? laneCount : 0)
        refusedAppends = .allocate(capacity: 1)
        refusedAppends.initialize(to: 0)
    }

    deinit {
        lanes.deallocate()
        flushing.deallocate()
        refusedAppends.deallocate()
    }

    /// Drained events the block buffer refused so far, saturating at `UInt64.max`.
    var appendRefused: UInt64 { refusedAppends.pointee }

    /// Any lane's bit is set.
    var isFlushing: Bool { flushing.pointee > 0 }

    /// Sets every lane's bit; called on every latched cycle, so a loss during the latch re-arms too.
    func arm() {
        lanes.update(repeating: true, count: laneCount)
        flushing.pointee = laneCount
    }

    /// Step 3: drains at most `min(limit, block.room)` events from `events` (fair, `perLaneQuota`) into `block`,
    /// marks entries from flushing lanes, clears the bit of each lane proved empty and orders the new run. Returns
    /// the drained count. The clamp means nothing is popped that `block` cannot hold: the excess stays queued, in
    /// order, for a later drain. `appendRefused` is a defensive tripwire for a fan-in that over-delivers.
    func drain(_ events: FanInHandoff<KernelEvent>, perLaneQuota: Int, limit: Int,
               into block: KernelBlockBuffer) -> Int {
        let first = block.count
        let total = min(limit, block.room)
        guard total > 0 else { return 0 }
        let drained = events.drain(perLaneQuota: perLaneQuota, total: total, emptied: { lane in
            guard lanes[Int(lane)] else { return }
            lanes[Int(lane)] = false
            flushing.pointee &-= 1
        }, { lane, event in
            if !block.append(KernelBlockEntry(event: event, producer: lane, flushed: lanes[Int(lane)])),
               refusedAppends.pointee != .max {
                refusedAppends.pointee &+= 1
            }
        })
        block.order(from: first)
        return drained
    }
}
