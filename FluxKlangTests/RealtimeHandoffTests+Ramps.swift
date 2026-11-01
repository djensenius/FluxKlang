import Testing
@testable import FluxKlang

private func ramps(_ count: Int) -> RampSlots? {
    try? RampSlots(parameterCount: count)
}

extension RealtimeHandoffTests {
    struct RampRules {
        @Test func newRampReplacesFromCurrentValue() throws {
            let slots = try #require(ramps(4))
            #expect(slots.set(parameter: 1, target: 1, durationFrames: 100, current: 0) == .ok)
            #expect(slots.advance(parameter: 1, frames: 50) == 0.5)
            // Replace mid-ramp: the new ramp starts at `current` and the old target is forgotten, not queued.
            #expect(slots.set(parameter: 1, target: 0, durationFrames: 100, current: 0.5) == .ok)
            #expect(slots.activeCount == 1)
            #expect(slots.advance(parameter: 1, frames: 0) == 0.5)
            #expect(slots.advance(parameter: 1, frames: 50) == 0.25)
            #expect(slots.advance(parameter: 1, frames: 50) == 0)
            #expect(slots.advance(parameter: 1, frames: 1) == nil)
            #expect(slots.activeCount == 0)
            // Replacing restarts the duration rather than adding to what was left.
            #expect(slots.set(parameter: 1, target: 8, durationFrames: 8, current: 0) == .ok)
            #expect(slots.advance(parameter: 1, frames: 4) == 4)
            #expect(slots.set(parameter: 1, target: 0, durationFrames: 4, current: 2) == .ok)
            #expect(slots.advance(parameter: 1, frames: 2) == 1)
            #expect(slots.advance(parameter: 1, frames: 2) == 0)
            #expect(slots.advance(parameter: 1, frames: 0) == nil)
        }

        @Test func thousandRampsOneParameterOccupyOneSlot() throws {
            let slots = try #require(ramps(3))
            for request in 0..<1_000 {
                #expect(slots.set(parameter: 2, target: Float(request), durationFrames: 10, current: 0) == .ok)
                #expect(slots.activeCount == 1)
            }
            for parameter in UInt32(0)..<3 {
                #expect(slots.set(parameter: parameter, target: 1, durationFrames: 10, current: 0) == .ok)
                #expect(slots.activeCount <= slots.parameterCount)
            }
            #expect(slots.activeCount == 3)
            #expect(slots.set(parameter: 2, target: 999, durationFrames: 10, current: 0) == .ok)
            #expect(slots.activeCount == 3)
            // Only the last request is live: one completion, then idle.
            #expect(slots.advance(parameter: 2, frames: 10) == 999)
            #expect(slots.advance(parameter: 2, frames: 10) == nil)
            #expect(slots.activeCount == 2)
        }

        @Test func rampCompletesAndFreesSlot() throws {
            let slots = try #require(ramps(1))
            #expect(slots.parameterCount == 1)
            #expect(slots.activeCount == 0)
            #expect(slots.advance(parameter: 0, frames: 1) == nil)
            #expect(slots.set(parameter: 0, target: 1, durationFrames: 4, current: 0) == .ok)
            #expect(slots.activeCount == 1)
            #expect(slots.advance(parameter: 0, frames: 1) == 0.25)
            #expect(slots.advance(parameter: 0, frames: 1) == 0.5)
            #expect(slots.activeCount == 1)
            #expect(slots.advance(parameter: 0, frames: 2) == 1)
            #expect(slots.activeCount == 0)
            #expect(slots.advance(parameter: 0, frames: 0) == nil)
            #expect(slots.advance(parameter: 0, frames: 1) == nil)
            #expect(slots.activeCount == 0)
            // Descending, and overshooting the end, still lands exactly on the target.
            #expect(slots.set(parameter: 0, target: -3, durationFrames: 4, current: 5) == .ok)
            #expect(slots.advance(parameter: 0, frames: 1) == 3)
            #expect(slots.advance(parameter: 0, frames: 1_000) == -3)
            #expect(slots.advance(parameter: 0, frames: 1_000) == nil)
            #expect(slots.activeCount == 0)
            // The final value is the target bit for bit, even where interpolation would round.
            #expect(slots.set(parameter: 0, target: 0.1, durationFrames: 3, current: 1e30) == .ok)
            #expect(slots.advance(parameter: 0, frames: 1) != nil)
            #expect(slots.advance(parameter: 0, frames: 2)?.bitPattern == Float(0.1).bitPattern)
        }

        @Test func zeroOrNegativeDurationJumpsWithoutTrap() throws {
            let slots = try #require(ramps(2))
            for duration in [Int64(0), -1, -480, .min] {
                #expect(slots.set(parameter: 1, target: 7, durationFrames: duration, current: -2) == .ok)
                #expect(slots.activeCount == 1)
                #expect(slots.advance(parameter: 1, frames: 0) == 7)
                #expect(slots.activeCount == 0)
                #expect(slots.advance(parameter: 1, frames: 0) == nil)
            }
            for frames in RealtimeHandoffTests.adversarialFrames {
                #expect(slots.set(parameter: 0, target: 3, durationFrames: 0, current: 9) == .ok)
                #expect(slots.advance(parameter: 0, frames: frames) == 3)
                #expect(slots.advance(parameter: 0, frames: frames) == nil)
            }
            #expect(slots.activeCount == 0)
        }

        @Test func outOfRangeParameterRefused() throws {
            let slots = try #require(ramps(4))
            #expect(slots.set(parameter: 3, target: 1, durationFrames: 10, current: 0) == .ok)
            for parameter: UInt32 in [4, 5, 1 << 16, .max] {
                #expect(slots.set(parameter: parameter, target: 9, durationFrames: 10, current: 0)
                    == .refused(.slotOutOfRange))
                #expect(slots.advance(parameter: parameter, frames: 10) == nil)
            }
            #expect(slots.activeCount == 1)
            for parameter in UInt32(0)..<3 {
                #expect(slots.advance(parameter: parameter, frames: 1) == nil)
            }
            #expect(slots.advance(parameter: 3, frames: 10) == 1)
            #expect(slots.activeCount == 0)
        }

        @Test func parametersAreIndependent() throws {
            let slots = try #require(ramps(3))
            #expect(slots.set(parameter: 0, target: 10, durationFrames: 10, current: 0) == .ok)
            #expect(slots.set(parameter: 2, target: -10, durationFrames: 20, current: 0) == .ok)
            #expect(slots.advance(parameter: 0, frames: 5) == 5)
            #expect(slots.advance(parameter: 1, frames: 5) == nil)
            #expect(slots.advance(parameter: 2, frames: 5) == -2.5)
            #expect(slots.advance(parameter: 0, frames: 5) == 10)
            #expect(slots.activeCount == 1)
            #expect(slots.advance(parameter: 2, frames: 0) == -2.5)
            #expect(slots.advance(parameter: 2, frames: 15) == -10)
            #expect(slots.activeCount == 0)
        }

        @Test func extremeFramesDoNotTrap() throws {
            let slots = try #require(ramps(1))
            #expect(slots.set(parameter: 0, target: 1, durationFrames: .max, current: 0) == .ok)
            let first = try #require(slots.advance(parameter: 0, frames: 1))
            #expect(first > 0 && first < 1e-18)
            // Negative frames never move a ramp backwards or forwards.
            for frames in [Int64(-1), .min] {
                #expect(slots.advance(parameter: 0, frames: frames) == first)
            }
            #expect(slots.advance(parameter: 0, frames: .max / 2) == 0.5)
            #expect(slots.advance(parameter: 0, frames: .max) == 1)
            #expect(slots.activeCount == 0)
            #expect(slots.set(parameter: 0, target: 2, durationFrames: 1, current: 0) == .ok)
            #expect(slots.advance(parameter: 0, frames: .max) == 2)
            #expect(slots.set(parameter: 0, target: 2, durationFrames: .max, current: 0) == .ok)
            #expect(slots.advance(parameter: 0, frames: .max - 1) == 2)
            #expect(slots.advance(parameter: 0, frames: 1) == 2)
            #expect(slots.advance(parameter: 0, frames: 1) == nil)
        }

        @Test func extremeValuesInterpolateWithoutOverflow() throws {
            let slots = try #require(ramps(1))
            let top = Float.greatestFiniteMagnitude
            #expect(slots.set(parameter: 0, target: top, durationFrames: 2, current: -top) == .ok)
            #expect(slots.advance(parameter: 0, frames: 0) == -top)
            #expect(slots.advance(parameter: 0, frames: 1) == 0)
            #expect(slots.advance(parameter: 0, frames: 1) == top)
        }

        @Test func nonFiniteValuesRefused() throws {
            let slots = try #require(ramps(2))
            #expect(slots.set(parameter: 0, target: 4, durationFrames: 4, current: 0) == .ok)
            let hostile: [Float] = [.nan, .signalingNaN, .infinity, -.infinity]
            for value in hostile {
                #expect(slots.set(parameter: 0, target: value, durationFrames: 4, current: 0)
                    == .refused(.invalidLength))
                #expect(slots.set(parameter: 0, target: 0, durationFrames: 4, current: value)
                    == .refused(.invalidLength))
                #expect(slots.set(parameter: 1, target: value, durationFrames: 0, current: value)
                    == .refused(.invalidLength))
            }
            // Refusals leave the existing ramp and the count untouched.
            #expect(slots.activeCount == 1)
            #expect(slots.advance(parameter: 0, frames: 1) == 1)
            #expect(slots.advance(parameter: 1, frames: 1) == nil)
            #expect(slots.advance(parameter: 0, frames: 3) == 4)
        }

        @Test func initRejectsOutOfRangeParameterCounts() {
            let maximum = RampSlots.maximumParameters
            #expect(maximum == KernelLimits.maximumCapacity)
            for count in RealtimeHandoffTests.adversarialInts + [maximum + 1] where count < 1 || count > maximum {
                #expect(throws: RampSlots.PreparationError.parameterCountOutOfRange(count)) {
                    try RampSlots(parameterCount: count)
                }
            }
            for count in [1, 2, maximum] {
                #expect(ramps(count)?.parameterCount == count)
                #expect(ramps(count)?.activeCount == 0)
            }
            let largest = ramps(maximum)
            let last = UInt32(maximum - 1)
            #expect(largest?.set(parameter: last, target: 1, durationFrames: 0, current: 0) == .ok)
            #expect(largest?.set(parameter: last + 1, target: 1, durationFrames: 0, current: 0)
                == .refused(.slotOutOfRange))
            #expect(largest?.advance(parameter: last, frames: 0) == 1)
        }
    }
}
