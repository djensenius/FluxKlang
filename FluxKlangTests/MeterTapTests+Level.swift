import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MeterTapTests {
    @Test func meterTapLevelTableMatchesTheGoldens() {
        #expect(MeterTapLevel.dBFS(fromLinearPeak: 0) == -.infinity)
        #expect(MeterTapLevel.dBFS(fromLinearPeak: -0.0) == -.infinity)
        #expect(MeterTapLevel.dBFS(fromLinearPeak: 1) == 0)
        #expect(Self.close(MeterTapLevel.dBFS(fromLinearPeak: 0.5), Self.halfDBFS))
        #expect(Self.close(MeterTapLevel.dBFS(fromLinearPeak: -0.5), Self.halfDBFS))
        #expect(Self.close(MeterTapLevel.dBFS(fromLinearPeak: 0.25), Self.quarterDBFS))
        #expect(Self.close(MeterTapLevel.dBFS(fromLinearPeak: 2), 6.020599913279624))
        #expect(MeterTapLevel.dBFS(fromLinearPeak: Float.leastNonzeroMagnitude) == -200)
    }

    @Test func meterTapLevelOfNaNAndInfinitiesIsNaN() {
        #expect(MeterTapLevel.dBFS(fromLinearPeak: .nan).isNaN)
        #expect(MeterTapLevel.dBFS(fromLinearPeak: .infinity).isNaN)
        #expect(MeterTapLevel.dBFS(fromLinearPeak: -.infinity).isNaN)
    }

    @Test func meterTapLevelHasNoUpperClamp() {
        let huge = MeterTapLevel.dBFS(fromLinearPeak: .greatestFiniteMagnitude)
        #expect(huge.isFinite)
        #expect(huge > 24)
        #expect(Self.close(MeterTapLevel.dBFS(fromLinearPeak: 1_000), 60))
    }

    @Test func meterTapLevelIsMonotonicOverAFixedAscendingTable() throws {
        let table: [Float] = [.leastNonzeroMagnitude, 1e-30, 1e-20, 1e-10, 1e-6, 1e-3, 0.01, 0.1, 0.5, 1, 2, 1_000]
        let levels = table.map { MeterTapLevel.dBFS(fromLinearPeak: $0) }
        try #require(levels.count == 12)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(zip(levels[4...], levels[5...]).allSatisfy { $0 < $1 })
        #expect(levels[0] == -200)
        #expect(levels[1] == -200)
    }

    @Test func meterTapLevelFloorHoldsAtNAndNPlusOne() {
        let aboveFloor = Float(1e-10)
        let belowFloor = aboveFloor.nextDown
        let kept = MeterTapLevel.dBFS(fromLinearPeak: aboveFloor)
        #expect(kept > -200)
        #expect(Self.close(kept, 20 * log10(Double(aboveFloor))))
        #expect(MeterTapLevel.dBFS(fromLinearPeak: belowFloor) == -200)
    }

    @Test func meterTapLevelNeverFallsBelowTheFloorForAPositiveFiniteInput() {
        let inputs: [Float] = [.leastNonzeroMagnitude, .leastNormalMagnitude / 2, .leastNormalMagnitude, 1e-38, 1e-20,
                               1e-12, 1e-11, 1e-9, 0.1, 1, .greatestFiniteMagnitude]
        for peak in inputs {
            let value = MeterTapLevel.dBFS(fromLinearPeak: peak)
            #expect(value >= -200, "peak \(peak)")
            #expect(!value.isNaN && value.isFinite, "peak \(peak)")
        }
    }

    @Test func meterTapDenormalsKeepTheirPeakAndPublishMinus200() throws {
        let denormals: [Float] = [.leastNonzeroMagnitude, .leastNormalMagnitude / 2, .leastNormalMagnitude]
        for peak in denormals {
            let tap = try Self.accumulator(1)
            let slots = try Self.slots(1)
            Self.feed(tap, 0, [peak])
            #expect(tap.reading(channel: 0) == .peak(peak))
            #expect(tap.reading(channel: 0) != .peak(0))
            #expect(Self.publish(tap, slots) == .ok)
            #expect(Self.level(slots, 0) == -200)
        }
    }

    @Test func meterTapADenormalBesideAQuarterKeepsTheQuarter() throws {
        let tap = try Self.accumulator(1)
        let slots = try Self.slots(1)
        Self.feed(tap, 0, [.leastNonzeroMagnitude, 0.25, .leastNormalMagnitude / 2])
        #expect(tap.reading(channel: 0) == .peak(0.25))
        Self.publish(tap, slots)
        #expect(Self.close(Self.level(slots, 0), Self.quarterDBFS))
    }

    @Test func meterTapTheLeastNormalBoundaryGoldenClampsToTheFloor() {
        let raw = 20 * log10(1.17549435e-38)
        #expect(raw < -200)
        #expect(max(-200, raw) == -200)
        #expect(MeterTapLevel.dBFS(fromLinearPeak: .leastNormalMagnitude) == max(-200, raw))
    }
}
