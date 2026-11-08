import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #364 E5c: the bounded carry of stateful events across cycle retirement (slice a). Pure values: no clock, no
/// threads, no wiring. The record and capacity tests are in `+Capacity`, re-timing and lane budgets in `+Retiming`,
/// supersede, delivery order and refusals in `+Order`.
struct KernelRetirementCarryTests {
    /// Roomy lane budgets: every lane fits the whole carry.
    static let roomy = KernelCarryLaneCapacity(state: 256, content: 256)

    static func control(
        frame: Int64 = 0, channel: UInt8 = 0, controller: UInt8 = 1, value: UInt32 = 2, sequence: UInt64 = 0
    ) -> KernelEvent {
        KernelEvent(
            frame: frame, scope: 3, sequence: sequence,
            payload: .control(channel: channel, controller: controller, value: value)
        )
    }

    static func program(
        frame: Int64 = 0, channel: UInt8 = 0, program: UInt8 = 5, bank: UInt16 = 6, sequence: UInt64 = 0
    ) -> KernelEvent {
        KernelEvent(
            frame: frame, scope: 3, sequence: sequence,
            payload: .program(channel: channel, program: program, bank: bank)
        )
    }

    static func ramp(
        frame: Int64 = 0, parameter: UInt32 = 1, value: Float = 0.5, duration: Int64 = 10, sequence: UInt64 = 0
    ) -> KernelEvent {
        KernelEvent(
            frame: frame, scope: 3, sequence: sequence,
            payload: .rampTo(parameter: parameter, value: value, durationFrames: duration)
        )
    }

    /// `event` as another scope's.
    static func scoped(_ event: KernelEvent, _ scope: UInt32) -> KernelEvent {
        KernelEvent(frame: event.frame, scope: scope, sequence: event.sequence, payload: event.payload)
    }

    static func noteOn(frame: Int64 = 0) -> KernelEvent {
        KernelEvent(frame: frame, scope: 3, sequence: 0, payload: .noteOn(channel: 0, note: 60, velocity: 100))
    }

    static func noteOff(frame: Int64 = 0) -> KernelEvent {
        KernelEvent(frame: frame, scope: 3, sequence: 0, payload: .noteOff(channel: 0, note: 60))
    }

    static func clockPulse(frame: Int64 = 0) -> KernelEvent {
        KernelEvent(frame: frame, scope: 3, sequence: 0, payload: .clockPulse)
    }

    static func carry(_ events: [KernelEvent]) -> KernelRetirementCarry {
        var carry = KernelRetirementCarry()
        for event in events { carry.record(event) }
        return carry
    }

    /// `count` controls with distinct keys and ascending sequence, as the capacity tests need.
    static func distinctControls(_ count: Int) -> [KernelEvent] {
        (0..<count).map { index in
            control(
                frame: Int64(index), channel: UInt8(index / 128), controller: UInt8(index % 128),
                value: UInt32(index), sequence: UInt64(index)
            )
        }
    }

    static func plan(
        _ carry: KernelRetirementCarry,
        blockCapacity: Int = 64,
        firstFrame: Int64 = 0,
        lanes: KernelCarryLaneCapacity = roomy
    ) throws -> KernelCarryPlan {
        try KernelCarryRetiming.plan(
            carry: carry, replacementBlockCapacity: blockCapacity, replacementFirstFrame: firstFrame,
            replacementLaneCapacity: lanes
        )
    }

    /// The refusal `work` throws, or `nil` when it does not throw `KernelCarryRefusal`.
    static func refusal(of work: () throws -> Void) -> KernelCarryRefusal? {
        do {
            try work()
            return nil
        } catch let refusal as KernelCarryRefusal {
            return refusal
        } catch {
            return nil
        }
    }

    static func refusal(
        _ carry: KernelRetirementCarry, blockCapacity: Int = 64, firstFrame: Int64 = 0
    ) -> KernelCarryRefusal? {
        refusal { _ = try plan(carry, blockCapacity: blockCapacity, firstFrame: firstFrame) }
    }

    static func frames(_ plan: KernelCarryPlan) -> [Int64] { plan.emissions.map(\.event.frame) }

    static func sequences(_ plan: KernelCarryPlan) -> [UInt64] { plan.emissions.map(\.event.sequence) }
}
