/// Pure Float32 reference kernels. They are the golden model for the later real-time executor: ordered `Float`
/// sums (never widened, reordered or fused), a single multiply for gain, and a mute that stores `+0.0`.
/// Callers (the evaluator) guarantee that every `term + frame` index is inside `scratch`.
enum ReferenceKernels {
    /// One output sample of a plan row. A bit-copy row returns the source bit pattern unchanged (including `-0.0`
    /// and subnormals); any other row is the ordered `mix`. `nil` means a non-finite intermediate sum.
    static func mapRow(_ row: RoutingRow, scratch: [Float], frame: Int) -> Float? {
        if row.isBitCopy, let term = row.terms.first {
            return scratch[term + frame]
        }
        return mix(terms: row.terms, scratch: scratch, frame: frame)
    }

    /// Ordered fan-in: starts at `+0.0` and adds each term in the given order, duplicates preserved. `nil` as soon
    /// as any intermediate sum is non-finite, even if a later term would bring the total back into range.
    static func mix(terms: [Int], scratch: [Float], frame: Int) -> Float? {
        var sum = Float.zero
        for term in terms {
            sum += scratch[term + frame]
            guard sum.isFinite else { return nil }
        }
        return sum
    }

    /// `sample * gain` in Float32; `nil` when the product is not finite. A gain of 1 is bit exact for finite input.
    static func gain(_ sample: Float, by gain: Float) -> Float? {
        let product = sample * gain
        return product.isFinite ? product : nil
    }

    /// The mute primitive: always `+0.0`, whatever the input.
    static func mute(_ sample: Float) -> Float {
        Float.zero
    }
}
