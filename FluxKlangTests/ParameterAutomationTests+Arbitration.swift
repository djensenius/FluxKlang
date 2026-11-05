import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ParameterAutomationTests {
    @Test
    func readModeFollowsTheCurveAndIgnoresGestures() throws {
        var arbiter = try Self.arbiter(.read)
        #expect(arbiter.owner == .automation)
        #expect(arbiter.value == nil)
        #expect(try arbiter.advance(to: 250) == .init(outcome: .applied, owner: .automation, value: 0.25))
        let ignored = ArbitrationResult(outcome: .ignored(.readMode), owner: .automation, value: 0.3)
        #expect(try arbiter.touch(Self.fader, priority: 0, at: 300) == ignored)
        #expect(try arbiter.move(Self.fader, to: 0.9, at: 300) == ignored)
        #expect(try arbiter.release(Self.knob, at: 300) == ignored)
        #expect(arbiter.touches.isEmpty)
    }

    @Test
    func touchHoldsTheValueThenMovesOwnIt() throws {
        var arbiter = try Self.arbiter(.touch)
        _ = try arbiter.advance(to: 250)
        let touched = try arbiter.touch(Self.fader, priority: 0, at: 300)
        #expect(touched == .init(outcome: .applied, owner: .gesture(Self.fader), value: 0.3))
        #expect(arbiter.touches == [GestureTouch(source: Self.fader, priority: 0)])
        #expect(try arbiter.move(Self.fader, to: 0.9, at: 400).value == 0.9)
        #expect(try arbiter.advance(to: 450) == .init(outcome: .applied, owner: .gesture(Self.fader), value: 0.9))
        #expect(try arbiter.move(Self.fader, to: 1.7, at: 460).value == 1)
        #expect(arbiter.position == 460)
    }

    @Test
    func higherPriorityTakesOverWithoutAJumpAndHandsBack() throws {
        var arbiter = try Self.arbiter(.touch)
        _ = try arbiter.touch(Self.knob, priority: 1, at: 100)
        _ = try arbiter.move(Self.knob, to: 0.4, at: 100)
        let stolen = try arbiter.touch(Self.fader, priority: 5, at: 200)
        #expect(stolen == .init(outcome: .applied, owner: .gesture(Self.fader), value: 0.4))
        let outranked = try arbiter.move(Self.knob, to: 0.6, at: 210)
        #expect(outranked == .init(outcome: .ignored(.outranked(owner: Self.fader)), owner: .gesture(Self.fader),
                                   value: 0.4))
        let late = try arbiter.touch(Self.pad, priority: 3, at: 220)
        #expect(late.outcome == .ignored(.outranked(owner: Self.fader)))
        #expect(arbiter.touches.map(\.source) == [Self.fader, Self.pad, Self.knob])
        _ = try arbiter.move(Self.fader, to: 0.7, at: 250)
        #expect(try arbiter.release(Self.fader, at: 300) == .init(outcome: .applied, owner: .gesture(Self.pad),
                                                                  value: 0.7))
        #expect(try arbiter.release(Self.pad, at: 310).owner == .gesture(Self.knob))
        #expect(try arbiter.move(Self.knob, to: 0.6, at: 320).value == 0.6)
    }

    @Test
    func equalPrioritiesBreakTiesByStableSourceID() throws {
        var knobFirst = try Self.arbiter(.touch)
        _ = try knobFirst.touch(Self.knob, priority: 2, at: 0)
        #expect(try knobFirst.touch(Self.fader, priority: 2, at: 0).outcome == .applied)
        var faderFirst = try Self.arbiter(.touch)
        _ = try faderFirst.touch(Self.fader, priority: 2, at: 0)
        #expect(try faderFirst.touch(Self.knob, priority: 2, at: 0).outcome == .ignored(.outranked(owner: Self.fader)))
        #expect(knobFirst.owner == .gesture(Self.fader))
        #expect(knobFirst.touches == faderFirst.touches)
        #expect(knobFirst.touches.map(\.source) == [Self.fader, Self.knob])
        let low = GestureTouch(source: Self.fader, priority: -1)
        #expect(GestureTouch(source: Self.pad, priority: 0).outranks(low))
        #expect(!low.outranks(low))
    }

    @Test
    func releasingANonOwnerKeepsTheOwner() throws {
        var arbiter = try Self.arbiter(.touch)
        _ = try arbiter.touch(Self.fader, priority: 5, at: 100)
        _ = try arbiter.touch(Self.knob, priority: 1, at: 100)
        _ = try arbiter.move(Self.fader, to: 0.6, at: 150)
        let released = try arbiter.release(Self.knob, at: 200)
        #expect(released == .init(outcome: .applied, owner: .gesture(Self.fader), value: 0.6))
        #expect(arbiter.touches.map(\.source) == [Self.fader])
    }

    @Test
    func movesAreValidatedBeforeRanking() throws {
        var arbiter = try Self.arbiter(.touch)
        _ = try arbiter.touch(Self.fader, priority: 1, at: 100)
        _ = try arbiter.touch(Self.knob, priority: 0, at: 100)
        let before = arbiter
        #expect(throws: AutomationRefusal.nonFinite) { _ = try arbiter.move(Self.knob, to: .nan, at: 150) }
        #expect(arbiter == before)
        #expect(try arbiter.move(Self.knob, to: 0.5, at: 150).outcome == .ignored(.outranked(owner: Self.fader)))
    }

    @Test
    func refusedEventsLeaveTheArbiterUnchanged() throws {
        var arbiter = try Self.arbiter(.touch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 100)
        let before = arbiter
        #expect(throws: AutomationRefusal.alreadyTouched(Self.fader)) {
            _ = try arbiter.touch(Self.fader, priority: 9, at: 150)
        }
        #expect(throws: AutomationRefusal.notTouched(Self.knob)) { _ = try arbiter.move(Self.knob, to: 0.5, at: 150) }
        #expect(throws: AutomationRefusal.notTouched(Self.knob)) { _ = try arbiter.release(Self.knob, at: 150) }
        #expect(throws: AutomationRefusal.nonFinite) { _ = try arbiter.move(Self.fader, to: .nan, at: 150) }
        #expect(throws: AutomationRefusal.nonFinite) { _ = try arbiter.advance(to: .infinity) }
        #expect(throws: AutomationRefusal.nonFinite) { _ = try arbiter.relocate(to: .nan) }
        #expect(throws: AutomationRefusal.timeRegressed(from: 100, to: 99)) { _ = try arbiter.advance(to: 99) }
        #expect(throws: AutomationRefusal.timeRegressed(from: 100, to: 50)) {
            _ = try arbiter.setMode(.read, at: 50)
        }
        #expect(arbiter == before)
        #expect(try arbiter.advance(to: 100).owner == .gesture(Self.fader))
    }

    @Test
    func touchesAreBounded() throws {
        var arbiter = try Self.arbiter(.touch)
        for index in 0..<ParameterArbiter.maximumTouches {
            _ = try arbiter.touch(ControlSourceID("ctl.s\(index)"), priority: index, at: 0)
        }
        let before = arbiter
        #expect(throws: AutomationRefusal.tooManyTouches) { _ = try arbiter.touch(Self.fader, priority: 99, at: 0) }
        #expect(arbiter == before)
        let top = try ControlSourceID("ctl.s15")
        #expect(arbiter.owner == .gesture(top))
    }

    @Test
    func glideDurationIsBounded() throws {
        let maximum = AutomationResume.maximumGlideTicks
        _ = try Self.arbiter(.touch, .glide(ticks: 1))
        _ = try Self.arbiter(.touch, .glide(ticks: maximum))
        for bad in [Int64(0), -5, maximum + 1] {
            #expect(throws: AutomationRefusal.invalidGlide(bad)) { _ = try Self.arbiter(.touch, .glide(ticks: bad)) }
        }
    }

    @Test
    func manualModeSuspendsAutomationAndHoldsAfterRelease() throws {
        var arbiter = try Self.arbiter(.manual)
        #expect(arbiter.owner == .manual)
        #expect(try arbiter.advance(to: 500) == .init(outcome: .applied, owner: .manual, value: nil))
        _ = try arbiter.touch(Self.fader, priority: 0, at: 500)
        _ = try arbiter.move(Self.fader, to: 0.4, at: 510)
        #expect(try arbiter.release(Self.fader, at: 520) == .init(outcome: .applied, owner: .manual, value: 0.4))
        #expect(try arbiter.advance(to: 2_500).value == 0.4)
        let resumed = try arbiter.setMode(.touch, at: 2_500)
        #expect(resumed == .init(outcome: .applied, owner: .gliding(from: 0.4, start: 2_500), value: 0.4))
    }

    @Test
    func modeChangesHandOwnershipDeterministically() throws {
        var touching = try Self.arbiter(.touch)
        _ = try touching.touch(Self.fader, priority: 0, at: 100)
        _ = try touching.move(Self.fader, to: 0.9, at: 100)
        var manual = touching
        #expect(try manual.setMode(.manual, at: 150).owner == .gesture(Self.fader))
        #expect(try manual.release(Self.fader, at: 160).owner == .manual)
        #expect(try manual.setMode(.read, at: 170).owner == .gliding(from: 0.9, start: 170))
        let read = try touching.setMode(.read, at: 200)
        #expect(read == .init(outcome: .applied, owner: .gliding(from: 0.9, start: 200), value: 0.9))
        #expect(touching.touches.isEmpty)
        #expect(touching.mode == .read)
        #expect(try touching.setMode(.read, at: 210).owner == .gliding(from: 0.9, start: 200))
        #expect(try touching.setMode(.latch, at: 220).owner == .gliding(from: 0.9, start: 200))
        let suspended = try touching.setMode(.manual, at: 250)
        #expect(suspended.owner == .manual)
        #expect(Self.close(suspended.value, 0.9 + (0.25 - 0.9) * 0.5))
        var automatic = try Self.arbiter(.read)
        #expect(try automatic.setMode(.latch, at: 0).owner == .automation)
        #expect(try automatic.setMode(.touch, at: 10).owner == .automation)
    }

    @Test
    func leavingALatchByModeChangeResumesAtOnce() throws {
        var arbiter = try Self.arbiter(.latch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 100)
        _ = try arbiter.move(Self.fader, to: 0.9, at: 100)
        #expect(try arbiter.release(Self.fader, at: 200).owner == .latched(until: 1_000))
        var toTouch = arbiter
        #expect(try toTouch.setMode(.touch, at: 300).owner == .gliding(from: 0.9, start: 300))
        var toRead = arbiter
        #expect(try toRead.setMode(.read, at: 300).owner == .gliding(from: 0.9, start: 300))
        var toManual = arbiter
        #expect(try toManual.setMode(.manual, at: 300) == .init(outcome: .applied, owner: .manual, value: 0.9))
        #expect(try toManual.setMode(.latch, at: 400).owner == .gliding(from: 0.9, start: 400))
    }
}
