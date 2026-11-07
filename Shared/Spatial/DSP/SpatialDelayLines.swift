//
//  SpatialDelayLines.swift
//  FluxKlang
//
//  Preallocated delay rings for the offline spatial block mixer (#115 SM2).
//

/// One ring of `capacity + 1` Floats per slot, all sharing one write index.
///
/// The ring is one slot longer than the longest delay so that delay 0 reads the
/// sample just written and delay `capacity` reads the oldest retained sample.
/// All storage is allocated in `init`; every other operation works in place.
struct SpatialDelayLines {
    let ringCount: Int
    let ringLength: Int
    private(set) var writeIndex = 0
    private var samples: [Float]

    init(ringCount: Int, capacity: Int) {
        self.ringCount = ringCount
        ringLength = capacity + 1
        samples = [Float](repeating: 0, count: ringCount * (capacity + 1))
    }

    /// Zeroes one ring's whole history.
    mutating func clear(ring: Int) {
        let base = ring * ringLength
        for index in base..<(base + ringLength) { samples[index] = 0 }
    }

    /// Stores `value` at the current write position of `ring`.
    mutating func write(_ value: Float, ring: Int) {
        samples[ring * ringLength + writeIndex] = value
    }

    /// The sample written `delay` frames before the current write position (`0...capacity`).
    func read(ring: Int, delay: Int) -> Float {
        var index = writeIndex - delay
        if index < 0 { index += ringLength }
        return samples[ring * ringLength + index]
    }

    /// Moves the shared write position on by one frame.
    mutating func advance() {
        writeIndex += 1
        if writeIndex == ringLength { writeIndex = 0 }
    }
}
