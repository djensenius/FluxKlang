/// MIDI 2.0 Min-Center-Max bit scaling, as media-contract §9.3 requires for "survives" checks.
///
/// Implements the "Min-Center-Max" upscale (bit shift up to and including the source centre, then an expanded
/// bit-repeat of the bits below the source MSB) and the matching downscale (plain right shift) from MMA/AMEI
/// M2-115-U "MIDI 2.0 Bit Scaling and Resolution" and M2-104-UM "Universal MIDI Packet (UMP) Format and MIDI 2.0
/// Protocol". Minimum maps to minimum, centre to centre, maximum to maximum, and
/// `scaleDown(scaleUp(x))` returns `x` for every source value. Contract vectors: `scaleUp(100, 7→16) = 0xC924`,
/// `scaleUp(64, 7→32) = 0x80000000`.
enum UMPScaling {
    /// Scales `value` (which must fit in `fromBits`) up to `toBits`, with 1 ≤ `fromBits` ≤ `toBits` ≤ 32.
    static func scaleUp(_ value: UInt32, fromBits: Int, toBits: Int) throws(UMPRefusal) -> UInt32 {
        guard fromBits >= 1, fromBits <= toBits, toBits <= 32 else {
            throw .invalidScale(fromBits: fromBits, toBits: toBits)
        }
        try checkFits(value, bits: fromBits)
        let scaleBits = UInt32(toBits - fromBits)
        var result = value << scaleBits
        let centre: UInt32 = 1 << UInt32(fromBits - 1)
        guard value > centre else { return result }
        let repeatBits = UInt32(fromBits - 1)
        var repeatValue = value & ((1 << repeatBits) - 1)
        if scaleBits > repeatBits {
            repeatValue <<= scaleBits - repeatBits
        } else {
            repeatValue >>= repeatBits - scaleBits
        }
        while repeatValue != 0 {
            result |= repeatValue
            repeatValue >>= repeatBits
        }
        return result
    }

    /// Scales `value` (which must fit in `fromBits`) down to `toBits` by right shift, with
    /// 1 ≤ `toBits` ≤ `fromBits` ≤ 32.
    static func scaleDown(_ value: UInt32, fromBits: Int, toBits: Int) throws(UMPRefusal) -> UInt32 {
        guard toBits >= 1, toBits <= fromBits, fromBits <= 32 else {
            throw .invalidScale(fromBits: fromBits, toBits: toBits)
        }
        try checkFits(value, bits: fromBits)
        return value >> UInt32(fromBits - toBits)
    }

    private static func checkFits(_ value: UInt32, bits: Int) throws(UMPRefusal) {
        // Swift's smart shift yields 0 for a 32-bit shift, so a 32-bit source always fits.
        guard value >> UInt32(bits) == 0 else {
            throw .valueOutOfRange(field: .scaledValue, value: Int(value))
        }
    }
}
