// #66 MET1 meter tap: linear peak to dBFS. Reference model; not RT-certified.

import Foundation  // `log10` only; no other file of the tap imports Foundation.

/// Converts a linear peak to dBFS. A pure function that runs once per channel at publish time, never in
/// `MeterTapAccumulator.accumulate`. Whether libm `log10` is real-time safe is UNVERIFIED.
enum MeterTapLevel {
    /// NaN and infinite input give NaN; 0 (either sign) is digital silence, -infinity; any other magnitude gives
    /// `20 * log10(magnitude)` raised to `MeterTapLimits.floorDBFS` (so denormals report exactly the floor). There
    /// is no upper clamp: the display clamps and latches clip itself.
    static func dBFS(fromLinearPeak peak: Float) -> Double {
        guard peak.isFinite else { return .nan }
        let magnitude = Double(peak.magnitude)
        if magnitude == 0 { return -.infinity }
        return max(MeterTapLimits.floorDBFS, 20 * log10(magnitude))
    }
}
