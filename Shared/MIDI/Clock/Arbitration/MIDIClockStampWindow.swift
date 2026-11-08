//
//  MIDIClockStampWindow.swift
//  FluxKlang
//
//  The last host stamps of one source's clock pulses, bounded by a watch's window size. It grows by appending up to
//  the size and then overwrites its oldest stamp in place (an unverified performance claim: no test or mutant can
//  tell an in-place update from a read, modify and write back). While it grows an append may reallocate, and a
//  shared copy of the window is copied on its first write.
//

/// A bounded first-in first-out window of host stamps. Not `Equatable`: comparing the ring would compare its layout.
struct MIDIClockStampWindow: Sendable {
    private let capacity: Int
    private var ring: [HostStamp] = []
    /// The slot holding the oldest stamp; zero while the ring is still growing.
    private var oldest = 0

    init(watch: MIDIClockJitterWatch) {
        capacity = watch.windowStamps
    }

    /// The held stamps, oldest first: at most the watch's window size.
    var stamps: [HostStamp] {
        guard oldest > 0 else { return ring }
        return Array(ring[oldest...]) + Array(ring[..<oldest])
    }

    /// Adds `stamp`; once the window is full the oldest stamp is dropped.
    mutating func record(_ stamp: HostStamp) {
        guard ring.count >= capacity else {
            ring.append(stamp)
            return
        }
        ring[oldest] = stamp
        oldest = (oldest + 1) % capacity
    }
}
