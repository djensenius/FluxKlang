import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ParameterAutomationTests {
    @Test
    func stopEndsATouchingLatchGestureAndStartGlidesBack() throws {
        var arbiter = try Self.arbiter(.latch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 300)
        _ = try arbiter.move(Self.fader, to: 0.9, at: 400)
        #expect(try arbiter.transportStopped(at: 500) == .init(outcome: .applied, owner: .awaitingPlayback, value: 0.9))
        #expect(arbiter.touches.isEmpty && !arbiter.isPlaying)
        #expect(try arbiter.advance(to: 1_500) == .init(outcome: .applied, owner: .awaitingPlayback, value: 0.9))
        let started = try arbiter.transportStarted(at: 1_500)
        #expect(started == .init(outcome: .applied, owner: .gliding(from: 0.9, start: 1_500), value: 0.9))
        #expect(arbiter.isPlaying)
        #expect(Self.close(try arbiter.advance(to: 1_550).value, 0.95))
        #expect(try arbiter.advance(to: 1_600) == .init(outcome: .applied, owner: .automation, value: 1))
    }

    @Test
    func stopEndsALatchAndStartCatchesBackAfterALocate() throws {
        var arbiter = try Self.arbiter(.latch, .catch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 300)
        _ = try arbiter.release(Self.fader, at: 400)
        #expect(arbiter.owner == .latched(until: 1_000))
        #expect(try arbiter.transportStopped(at: 500) == .init(outcome: .applied, owner: .awaitingPlayback, value: 0.3))
        #expect(try arbiter.relocate(to: 0) == .init(outcome: .applied, owner: .awaitingPlayback, value: 0.3))
        #expect(try arbiter.transportStarted(at: 0) == .init(outcome: .applied, owner: .catching, value: 0.3))
        #expect(try arbiter.advance(to: 299) == .init(outcome: .applied, owner: .catching, value: 0.3))
        #expect(try arbiter.advance(to: 300) == .init(outcome: .applied, owner: .automation, value: 0.3))
    }

    @Test
    func stopHoldsATouchReleaseOrGlideWithoutAJump() throws {
        var touching = try Self.arbiter(.touch)
        _ = try touching.touch(Self.fader, priority: 0, at: 300)
        let held = ArbitrationResult(outcome: .applied, owner: .awaitingPlayback, value: 0.3)
        #expect(try touching.transportStopped(at: 400) == held)
        var gliding = try Self.arbiter(.touch)
        _ = try gliding.touch(Self.fader, priority: 0, at: 300)
        _ = try gliding.release(Self.fader, at: 400)
        let stopped = try gliding.transportStopped(at: 450)
        #expect(stopped.owner == .awaitingPlayback && Self.close(stopped.value, 0.375))
        #expect(try gliding.transportStarted(at: 450).owner == .gliding(from: try #require(stopped.value), start: 450))
        var catching = try Self.arbiter(.touch, .catch)
        _ = try catching.touch(Self.fader, priority: 0, at: 300)
        _ = try catching.move(Self.fader, to: 0.9, at: 300)
        _ = try catching.release(Self.fader, at: 400)
        let caught = try catching.transportStopped(at: 800)
        #expect(caught == .init(outcome: .applied, owner: .awaitingPlayback, value: 0.9))
    }

    @Test
    func gesturesWhileStoppedHoldUntilPlaybackStarts() throws {
        for mode in [AutomationMode.touch, .latch] {
            var arbiter = try Self.arbiter(mode, playing: false)
            _ = try arbiter.touch(Self.fader, priority: 0, at: 100)
            _ = try arbiter.move(Self.fader, to: 0.7, at: 100)
            #expect(try arbiter.release(Self.fader, at: 200).owner == .awaitingPlayback)
            #expect(try arbiter.transportStarted(at: 200).owner == .gliding(from: 0.7, start: 200))
        }
    }

    @Test
    func stopLeavesReadAndManualOwnershipUnchanged() throws {
        var read = try Self.arbiter(.read)
        #expect(try read.transportStopped(at: 500) == .init(outcome: .applied, owner: .automation, value: 0.5))
        let ignored = ArbitrationResult(outcome: .ignored(.readMode), owner: .automation, value: 0.5)
        #expect(try read.touch(Self.fader, priority: 0, at: 500) == ignored)
        #expect(try read.transportStarted(at: 600) == .init(outcome: .applied, owner: .automation, value: 0.6))
        var manual = try Self.arbiter(.manual)
        _ = try manual.touch(Self.fader, priority: 0, at: 300)
        _ = try manual.move(Self.fader, to: 0.4, at: 300)
        let touched = ArbitrationResult(outcome: .applied, owner: .gesture(Self.fader), value: 0.4)
        #expect(try manual.transportStopped(at: 400) == touched)
        #expect(manual.touches.count == 1)
        #expect(try manual.release(Self.fader, at: 500) == .init(outcome: .applied, owner: .manual, value: 0.4))
        #expect(try manual.transportStarted(at: 600) == .init(outcome: .applied, owner: .manual, value: 0.4))
        #expect(try manual.transportStopped(at: 700) == .init(outcome: .applied, owner: .manual, value: 0.4))
    }

    @Test
    func readModeTransitionsFreezeOnStopAndResumeFromTheHeldValue() throws {
        var gliding = try Self.arbiter(.touch)
        _ = try gliding.touch(Self.fader, priority: 0, at: 300)
        _ = try gliding.release(Self.fader, at: 400)
        #expect(try gliding.setMode(.read, at: 420).owner == .gliding(from: 0.3, start: 400))
        let frozen = try gliding.transportStopped(at: 450)
        #expect(frozen.owner == .awaitingPlayback && Self.close(frozen.value, 0.375))
        #expect(try gliding.advance(to: 600) == frozen)
        let held = try #require(frozen.value)
        #expect(try gliding.transportStarted(at: 600) == .init(
            outcome: .applied, owner: .gliding(from: held, start: 600), value: held))
        #expect(Self.close(try gliding.advance(to: 650).value, 0.5125))
        #expect(try gliding.advance(to: 700) == .init(outcome: .applied, owner: .automation, value: 0.7))
        var catching = try Self.arbiter(.touch, .catch)
        _ = try catching.touch(Self.fader, priority: 0, at: 300)
        _ = try catching.move(Self.fader, to: 0.9, at: 300)
        _ = try catching.release(Self.fader, at: 400)
        #expect(try catching.setMode(.read, at: 500).owner == .catching)
        let caught = try catching.transportStopped(at: 600)
        #expect(caught == .init(outcome: .applied, owner: .awaitingPlayback, value: 0.9))
        #expect(try catching.transportStarted(at: 600) == .init(outcome: .applied, owner: .catching, value: 0.9))
        #expect(try catching.advance(to: 899) == .init(outcome: .applied, owner: .catching, value: 0.9))
        #expect(try catching.advance(to: 900) == .init(outcome: .applied, owner: .automation, value: 0.9))
    }

    @Test
    func liftsAfterAStopAreIgnoredUntilTheSourceTouchesAgain() throws {
        var arbiter = try Self.arbiter(.latch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 300)
        _ = try arbiter.transportStopped(at: 400)
        #expect(arbiter.endedTouches == [.init(source: Self.fader, reason: .endedByTransport)])
        let ignored = ArbitrationResult(outcome: .ignored(.endedByTransport), owner: .awaitingPlayback, value: 0.3)
        #expect(try arbiter.release(Self.fader, at: 410) == ignored)
        #expect(try arbiter.move(Self.fader, to: 0.8, at: 420) == ignored)
        #expect(try arbiter.release(Self.fader, at: 430) == ignored)
        #expect(throws: AutomationRefusal.notTouched(Self.knob)) { _ = try arbiter.release(Self.knob, at: 440) }
        #expect(throws: AutomationRefusal.notTouched(Self.knob)) { _ = try arbiter.move(Self.knob, to: 0.5, at: 440) }
        #expect(throws: AutomationRefusal.nonFinite) { _ = try arbiter.move(Self.knob, to: .nan, at: 440) }
        #expect(throws: AutomationRefusal.nonFinite) { _ = try arbiter.move(Self.fader, to: .nan, at: 440) }
        #expect(try arbiter.touch(Self.fader, priority: 0, at: 500).owner == .gesture(Self.fader))
        #expect(arbiter.endedTouches.isEmpty)
        #expect(try arbiter.release(Self.fader, at: 510).owner == .awaitingPlayback)
        #expect(throws: AutomationRefusal.notTouched(Self.fader)) { _ = try arbiter.release(Self.fader, at: 520) }
    }

    @Test
    func liftsAfterASwitchToReadAreIgnoredUntilTheSourceTouchesAgain() throws {
        var arbiter = try Self.arbiter(.touch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 100)
        _ = try arbiter.touch(Self.knob, priority: 1, at: 100)
        _ = try arbiter.setMode(.read, at: 200)
        #expect(arbiter.touches.isEmpty)
        #expect(arbiter.endedTouches == [.init(source: Self.knob, reason: .endedByModeChange),
                                         .init(source: Self.fader, reason: .endedByModeChange)])
        #expect(try arbiter.release(Self.fader, at: 210).outcome == .ignored(.readMode))
        _ = try arbiter.setMode(.touch, at: 300)
        let lifted = try arbiter.release(Self.fader, at: 310)
        #expect(lifted.outcome == .ignored(.endedByModeChange) && lifted.owner == .automation)
        #expect(Self.close(lifted.value, 0.31))
        #expect(try arbiter.move(Self.knob, to: 0.9, at: 320).outcome == .ignored(.endedByModeChange))
        #expect(throws: AutomationRefusal.notTouched(Self.pad)) { _ = try arbiter.release(Self.pad, at: 330) }
        _ = try arbiter.touch(Self.knob, priority: 1, at: 340)
        #expect(arbiter.endedTouches == [.init(source: Self.fader, reason: .endedByModeChange)])
        #expect(try arbiter.release(Self.knob, at: 350).outcome == .applied)
        _ = try arbiter.touch(Self.pad, priority: 0, at: 360)
        _ = try arbiter.transportStopped(at: 370)
        #expect(try arbiter.release(Self.pad, at: 380).outcome == .ignored(.endedByTransport))
        #expect(try arbiter.release(Self.fader, at: 380).outcome == .ignored(.endedByModeChange))
    }

    @Test
    func sourcesEndedByStopAreBoundedOldestFirst() throws {
        let sources = try (0..<20).map { index throws(ContractIDError) in
            try ControlSourceID(String(format: "ctl.s%02d", index))
        }
        var arbiter = try Self.arbiter(.touch)
        for source in sources[..<16] { _ = try arbiter.touch(source, priority: 0, at: 100) }
        _ = try arbiter.transportStopped(at: 200)
        #expect(arbiter.endedTouches.map(\.source) == Array(sources[..<16]))
        _ = try arbiter.transportStarted(at: 300)
        for source in sources[16...] { _ = try arbiter.touch(source, priority: 0, at: 300) }
        _ = try arbiter.transportStopped(at: 400)
        #expect(arbiter.endedTouches.map(\.source) == Array(sources[4...]))
        #expect(throws: AutomationRefusal.notTouched(sources[3])) { _ = try arbiter.release(sources[3], at: 500) }
        #expect(try arbiter.release(sources[4], at: 500).outcome == .ignored(.endedByTransport))
        var manual = try Self.arbiter(.manual)
        _ = try manual.touch(Self.fader, priority: 0, at: 100)
        _ = try manual.transportStopped(at: 200)
        #expect(manual.endedTouches.isEmpty)
        #expect(try manual.release(Self.fader, at: 300).owner == .manual)
    }

    @Test
    func locateWhilePlayingKeepsALatchAndMovesItsEnd() throws {
        var arbiter = try Self.arbiter(.latch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 3_500)
        _ = try arbiter.move(Self.fader, to: 0.3, at: 3_500)
        #expect(try arbiter.release(Self.fader, at: 3_600).owner == .latched(until: nil))
        #expect(try arbiter.advance(to: 1e9) == .init(outcome: .applied, owner: .latched(until: nil), value: 0.3))
        #expect(try arbiter.relocate(to: 0) == .init(outcome: .applied, owner: .latched(until: 1_000), value: 0.3))
        #expect(try arbiter.advance(to: 999) == .init(outcome: .applied, owner: .latched(until: 1_000), value: 0.3))
        #expect(Self.close(try arbiter.advance(to: 1_050).value, 0.65))
        #expect(try arbiter.advance(to: 1_100) == .init(outcome: .applied, owner: .automation, value: 1))
    }

    @Test
    func locateReevaluatesTheCurveWithoutJumpingHeldValues() throws {
        var automatic = try Self.arbiter(.latch)
        _ = try automatic.advance(to: 100)
        let curve = try automatic.relocate(to: 2_500)
        #expect(curve.owner == .automation && Self.close(curve.value, 0.5))
        var gliding = try Self.arbiter(.touch)
        _ = try gliding.touch(Self.fader, priority: 0, at: 300)
        _ = try gliding.release(Self.fader, at: 400)
        let located = try gliding.relocate(to: 2_500)
        #expect(located == .init(outcome: .applied, owner: .gliding(from: 0.3, start: 2_500), value: 0.3))
        #expect(Self.close(try gliding.advance(to: 2_550).value, 0.415))
        #expect(Self.close(try gliding.advance(to: 2_600).value, 0.56))
        #expect(gliding.owner == .automation)
        var catching = try Self.arbiter(.touch, .catch)
        _ = try catching.touch(Self.fader, priority: 0, at: 300)
        _ = try catching.move(Self.fader, to: 0.9, at: 300)
        _ = try catching.release(Self.fader, at: 400)
        #expect(try catching.relocate(to: 950) == .init(outcome: .applied, owner: .catching, value: 0.9))
        #expect(try catching.advance(to: 1_999) == .init(outcome: .applied, owner: .catching, value: 0.9))
        #expect(try catching.advance(to: 2_000) == .init(outcome: .applied, owner: .automation, value: 0.2))
    }

    @Test
    func locateKeepsTouchingGesturesAndManualHolds() throws {
        var touching = try Self.arbiter(.touch)
        _ = try touching.touch(Self.fader, priority: 0, at: 300)
        _ = try touching.move(Self.fader, to: 0.3, at: 400)
        #expect(try touching.relocate(to: 0) == .init(outcome: .applied, owner: .gesture(Self.fader), value: 0.3))
        #expect(touching.position == 0)
        #expect(throws: AutomationRefusal.timeRegressed(from: 0, to: -1)) { _ = try touching.advance(to: -1) }
        var manual = try Self.arbiter(.manual)
        _ = try manual.advance(to: 10)
        #expect(try manual.relocate(to: 500) == .init(outcome: .applied, owner: .manual, value: nil))
    }

    /// The same tick gives the same value whatever the sample rate, block size or tempo that reach it.
    @Test
    func tickResultsDoNotDependOnSampleRateBlockSizeOrTempo() throws {
        let lane = try Self.lane([
            .init(ticks: 0, value: 0.1), .init(ticks: 15_360, value: 0.9, interpolation: .power(2)),
            .init(ticks: 30_720, value: 0.3, interpolation: .step), .init(ticks: 40_000, value: 0.6)
        ])
        let checkpoints: [Int64] = [0, 7_680, 15_360, 23_040, 30_720, 38_400, 46_080]
        let reference = try Self.transportRun(lane, checkpoints, rate: nil)
        #expect(reference.count == checkpoints.count)
        for bpm in [90.0, 120, 150] {
            let ticksPerSecond = bpm / 60 * Double(MusicalTime.ticksPerQuarter)
            for sampleRate in [44_100.0, 48_000, 96_000] {
                for block in [64, 256, 1_000] {
                    let rate = TransportRate(ticksPerSecond: ticksPerSecond, sampleRate: sampleRate, block: block)
                    #expect(try Self.transportRun(lane, checkpoints, rate: rate) == reference)
                }
            }
        }
    }

    /// Plays `lane` with a fader latch over `checkpoints`, advancing at every block start when `rate`
    /// is given; returns the lane value and arbiter result at each checkpoint.
    static func transportRun(
        _ lane: AutomationLane, _ checkpoints: [Int64],
        rate: TransportRate?
    ) throws -> [TransportProbe] {
        var arbiter = try ParameterArbiter(lane: lane, mode: .latch, resume: .glide(ticks: 7_680))
        var probes: [TransportProbe] = []
        var blockStart = 0
        for (index, checkpoint) in checkpoints.enumerated() {
            let ticks = Double(checkpoint)
            if let rate {
                let frame = ticks * rate.sampleRate / rate.ticksPerSecond
                try #require(frame == frame.rounded())
                while blockStart + rate.block <= Int(frame) {
                    blockStart += rate.block
                    _ = try arbiter.advance(to: Double(blockStart) * rate.ticksPerSecond / rate.sampleRate)
                }
                #expect(Double(Int(frame)) * rate.ticksPerSecond / rate.sampleRate == ticks)
            }
            switch index {
            case 1: _ = try arbiter.touch(Self.fader, priority: 0, at: ticks)
            case 2: _ = try arbiter.move(Self.fader, to: 0.25, at: ticks)
            case 3: _ = try arbiter.release(Self.fader, at: ticks)
            default: break
            }
            probes.append(TransportProbe(curve: try lane.value(at: ticks), result: try arbiter.advance(to: ticks)))
        }
        return probes
    }

    struct TransportRate {
        let ticksPerSecond: Double
        let sampleRate: Double
        let block: Int
    }

    struct TransportProbe: Equatable {
        let curve: Double?
        let result: ArbitrationResult
    }
}
