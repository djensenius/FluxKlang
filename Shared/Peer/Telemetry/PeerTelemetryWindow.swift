//
//  PeerTelemetryWindow.swift
//  FluxKlang
//
//  A fixed-capacity window of integer samples for peer telemetry (#97, R3), for
//  example control latency in caller-chosen units. It reads no clock: the caller
//  records the numbers. When full, the oldest sample is replaced and counted in
//  `droppedSamples`. The snapshot is computed from the retained samples, oldest
//  to newest, so the same record sequence always gives the same snapshot.
//

/// The statistics of the samples a window holds. Output only: made by the window; nothing takes one as input.
struct PeerTelemetrySnapshot: Hashable, Sendable {
    let capacity: Int
    let count: Int
    /// Nil when the window is empty.
    let min: Int?
    /// Nil when the window is empty.
    let max: Int?
    /// Saturating: each step, oldest to newest, clamps to `Int.min`/`Int.max`. Inexact when `sumOverflowed`.
    let sum: Int
    /// True when any step of the sum had to clamp.
    let sumOverflowed: Bool
    /// Samples replaced because the window was full, since it was made.
    let droppedSamples: UInt64
}

struct PeerTelemetryWindow: Hashable, Sendable {
    static let capacityBounds = 1...1_024

    let capacity: Int
    private(set) var droppedSamples: UInt64 = 0
    private var samples: [Int] = []

    private init(capacity: Int) { self.capacity = capacity }

    static func make(capacity: Int) throws(PeerBackpressureRefusal) -> PeerTelemetryWindow {
        guard capacityBounds.contains(capacity) else { throw .invalidLimit(.capacity) }
        return PeerTelemetryWindow(capacity: capacity)
    }

    var count: Int { samples.count }

    /// Appends `sample`; a full window first drops its oldest sample and counts it.
    mutating func record(_ sample: Int) {
        if samples.count >= capacity {
            samples.removeFirst()
            droppedSamples = droppedSamples == UInt64.max ? UInt64.max : droppedSamples + 1
        }
        samples.append(sample)
    }

    func snapshot() -> PeerTelemetrySnapshot {
        var sum = 0
        var overflowed = false
        for sample in samples {
            let (next, didOverflow) = sum.addingReportingOverflow(sample)
            if didOverflow {
                overflowed = true
                sum = sample < 0 ? Int.min : Int.max
            } else {
                sum = next
            }
        }
        return PeerTelemetrySnapshot(capacity: capacity, count: samples.count, min: samples.min(),
                                     max: samples.max(), sum: sum, sumOverflowed: overflowed,
                                     droppedSamples: droppedSamples)
    }
}
