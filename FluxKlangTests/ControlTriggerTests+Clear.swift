import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #363: the host clear for toggles, and the incremental owed-release count.
@Suite(.productionAccessAudit)
struct ControlTriggerClearTests {
    typealias Fixture = ControlTriggerTests
    static let id = BindingID(validated: "bnd.trigger")

    /// Releases owed by the public state: held momentary bindings with `emitsRelease`. This is the count the
    /// detector recomputed on every command before #363.
    static func publicOwed(_ detector: ControlTriggerDetector) -> Int {
        detector.bindings.filter { binding in
            binding.emitsRelease == true && detector.state(of: binding.id)?.held == true
        }.count
    }

    static func expectOwed(_ detector: ControlTriggerDetector, _ expected: Int,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(detector.owedCount == expected, sourceLocation: sourceLocation)
        #expect(detector.recountOwedReleases() == expected, sourceLocation: sourceLocation)
        #expect(publicOwed(detector) == expected, sourceLocation: sourceLocation)
    }

    @Test
    func clearingAToggleWhoseTargetIsGoneOrNonLiveSwitchesItOff() throws {
        var truths = [try Fixture.truth(targets: [Fixture.fire: .live])]
        for controlClass in ControlClass.allCases where controlClass != .live {
            truths.append(try Fixture.truth(targets: [Fixture.next: controlClass]))
        }
        for truth in truths {
            var detector = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .toggle)])
            #expect(try Fixture.feed(&detector, 1)?.action == .switchedOn)
            #expect(try Fixture.feed(&detector, 0) == nil)
            let stuck = detector
            // The switch-off press is refused while the target is gone or not live, so the toggle would stay on.
            #expect(throws: ControlTriggerRefusal.self) {
                try detector.handle(.absolute(normalized: 1), from: Fixture.pedal, binding: Self.id, truth: truth)
            }
            #expect(detector == stuck)
            let cleared = try detector.clear(Self.id)
            #expect(cleared?.binding == Self.id)
            #expect(cleared?.target == Fixture.next)
            #expect(cleared?.source == Fixture.pedal)
            #expect(cleared?.action == .switchedOff)
            #expect(cleared?.cause == .clear)
            #expect(cleared?.sequence == 2)
            #expect(detector.state(of: Self.id)?.isOn == false)
            #expect(detector.state(of: Self.id)?.held == false)
            #expect(detector.lastSequence == 2)
            // The next press goes through the target checks as before.
            #expect(throws: ControlTriggerRefusal.self) {
                try detector.handle(.absolute(normalized: 1), from: Fixture.pedal, binding: Self.id, truth: truth)
            }
            #expect(try Fixture.feed(&detector, 1)?.action == .switchedOn)
            #expect(detector.lastSequence == 3)
        }
    }

    @Test
    func clearingAnOffToggleReturnsNilAndConsumesNoSequence() throws {
        var detector = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .toggle)], after: 7)
        let fresh = detector
        #expect(try detector.clear(Self.id) == nil)
        #expect(detector == fresh)
        #expect(detector.lastSequence == 7)
        #expect(try Fixture.feed(&detector, 1)?.sequence == 8)
        #expect(try Fixture.feed(&detector, 0) == nil)
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOff)
        let off = detector
        #expect(try detector.clear(Self.id) == nil)
        #expect(detector == off)
        #expect(detector.lastSequence == 9)
        // An off toggle at the exhaustion boundary is still nil, not a refusal.
        var full = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .toggle)], after: .max)
        #expect(try full.clear(Self.id) == nil)
        #expect(full.lastSequence == .max)
    }

    @Test
    func clearingAHeldToggleKeepsTheHold() throws {
        let toggle = try Fixture.binding(mode: .toggle)
        let momentary = try Fixture.binding("bnd.m", source: Fixture.button, target: Fixture.fire, emitsRelease: true)
        var detector = try ControlTriggerDetector(bindings: [toggle, momentary])
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOn)
        #expect(try Fixture.feed(&detector, 1, "bnd.m", source: Fixture.button)?.action == .press)
        Self.expectOwed(detector, 1)
        #expect(try detector.clear(Self.id)?.sequence == 3)
        #expect(detector.state(of: Self.id)?.held == true)
        #expect(detector.state(of: Self.id)?.isOn == false)
        #expect(detector.state(of: momentary.id)?.held == true)
        Self.expectOwed(detector, 1)
        // Still held, so repeated input is no edge and the toggle stays off.
        #expect(try Fixture.feed(&detector, 1) == nil)
        #expect(detector.state(of: Self.id)?.isOn == false)
        // The owed release is still emitted on disconnect.
        let released = try detector.forgetHeld(on: [Fixture.button])
        #expect(released.map(\.binding) == [momentary.id])
        #expect(released.map(\.sequence) == [4])
        Self.expectOwed(detector, 0)
        #expect(try Fixture.feed(&detector, 0) == nil)
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOn)
        #expect(detector.lastSequence == 5)
    }

    @Test
    func toggleClearReservesEveryOwedReleaseAtTheExhaustionBoundary() throws {
        let held = try Fixture.binding("bnd.m", emitsRelease: true)
        let toggle = try Fixture.binding("bnd.o", source: Fixture.button, target: Fixture.fire, mode: .toggle)
        // N: one sequence left after the toggle and the press, and it is reserved for the release.
        var detector = try ControlTriggerDetector(bindings: [held, toggle], after: .max - 3)
        #expect(try Fixture.feed(&detector, 1, "bnd.o", source: Fixture.button)?.sequence == .max - 2)
        #expect(try Fixture.feed(&detector, 1, "bnd.m")?.sequence == .max - 1)
        let before = detector
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try detector.clear(toggle.id) }
        #expect(detector == before)
        #expect(detector.state(of: toggle.id)?.isOn == true)
        #expect(detector.state(of: toggle.id)?.held == true)
        Self.expectOwed(detector, 1)
        #expect(try Fixture.feed(&detector, 0, "bnd.m")?.sequence == .max)
        Self.expectOwed(detector, 0)

        // N + 1: one more sequence lets the clear through and still leaves the release its sequence.
        var roomy = try ControlTriggerDetector(bindings: [held, toggle], after: .max - 4)
        #expect(try Fixture.feed(&roomy, 1, "bnd.o", source: Fixture.button)?.sequence == .max - 3)
        #expect(try Fixture.feed(&roomy, 1, "bnd.m")?.sequence == .max - 2)
        #expect(try roomy.clear(toggle.id)?.sequence == .max - 1)
        #expect(roomy.state(of: toggle.id)?.isOn == false)
        Self.expectOwed(roomy, 1)
        #expect(try roomy.forgetHeld(on: [Fixture.pedal]).map(\.sequence) == [.max])

        // With nothing owed, the clear may take the very last sequence, and with none left it is refused.
        var last = try ControlTriggerDetector(bindings: [held, toggle], after: .max - 1)
        #expect(try Fixture.feed(&last, 1, "bnd.o", source: Fixture.button)?.sequence == .max)
        let exhausted = last
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try last.clear(toggle.id) }
        #expect(last == exhausted)
        var lastFree = try ControlTriggerDetector(bindings: [held, toggle], after: .max - 2)
        #expect(try Fixture.feed(&lastFree, 1, "bnd.o", source: Fixture.button)?.sequence == .max - 1)
        #expect(try lastFree.clear(toggle.id)?.sequence == .max)
    }

    @Test
    func refusedClearsChangeNothing() throws {
        let bindings = [
            try Fixture.binding(emitsRelease: true),
            try Fixture.binding("bnd.plain", source: Fixture.button),
            try Fixture.binding("bnd.t", target: Fixture.fire, mode: .toggle),
            try Fixture.binding("bnd.l", source: Fixture.button, mode: .latch)
        ]
        var detector = try ControlTriggerDetector(bindings: bindings, after: .max - 5)
        #expect(try Fixture.feed(&detector, 1, "bnd.t")?.sequence == .max - 4)
        #expect(try Fixture.feed(&detector, 1, "bnd.l", source: Fixture.button)?.sequence == .max - 3)
        #expect(try Fixture.feed(&detector, 1)?.sequence == .max - 2)
        #expect(try Fixture.feed(&detector, 1, "bnd.plain", source: Fixture.button)?.sequence == .max - 1)
        let before = detector
        #expect(throws: ControlTriggerRefusal.notClearable(.momentary)) { try detector.clear(Self.id) }
        #expect(throws: ControlTriggerRefusal.notClearable(.momentary)) { try detector.clear(BindingID("bnd.plain")) }
        #expect(throws: ControlTriggerRefusal.unknownBinding(try BindingID("bnd.other"))) {
            try detector.clear(BindingID("bnd.other"))
        }
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try detector.clear(BindingID("bnd.t")) }
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try detector.clear(BindingID("bnd.l")) }
        #expect(detector == before)
        Self.expectOwed(detector, 1)
        for binding in bindings {
            #expect(detector.state(of: binding.id)?.held == true)
            #expect(detector.state(of: binding.id)?.isOn == (binding.mode != .momentary))
        }
        #expect(try Fixture.feed(&detector, 0)?.sequence == .max)
    }

    @Test
    func clearingAMomentaryBindingIsRefusedAsBefore() throws {
        for emits in [nil, true] as [Bool?] {
            var detector = try ControlTriggerDetector(bindings: [Fixture.binding(emitsRelease: emits)])
            let released = detector
            #expect(throws: ControlTriggerRefusal.notClearable(.momentary)) { try detector.clear(Self.id) }
            #expect(detector == released)
            #expect(try Fixture.feed(&detector, 1)?.action == .press)
            let held = detector
            #expect(throws: ControlTriggerRefusal.notClearable(.momentary)) { try detector.clear(Self.id) }
            #expect(detector == held)
            Self.expectOwed(detector, emits == true ? 1 : 0)
            #expect(try Fixture.feed(&detector, 0)?.action == (emits == true ? .release : nil))
        }
    }

    @Test
    func owedCountFollowsEveryHeldChange() throws {
        let bindings = [
            try Fixture.binding("bnd.a", emitsRelease: true), try Fixture.binding("bnd.b", emitsRelease: true),
            try Fixture.binding("bnd.c", source: Fixture.button, emitsRelease: true),
            try Fixture.binding("bnd.p"), try Fixture.binding("bnd.t", mode: .toggle),
            try Fixture.binding("bnd.l", mode: .latch)
        ]
        var detector = try ControlTriggerDetector(bindings: bindings)
        Self.expectOwed(detector, 0)
        _ = try Fixture.feed(&detector, 1, "bnd.a")
        Self.expectOwed(detector, 1)
        _ = try Fixture.feed(&detector, 1, "bnd.a")
        Self.expectOwed(detector, 1)
        _ = try Fixture.feed(&detector, 1, "bnd.b")
        _ = try Fixture.feed(&detector, 1, "bnd.c", source: Fixture.button)
        for name in ["bnd.p", "bnd.t", "bnd.l"] { _ = try Fixture.feed(&detector, 1, name) }
        Self.expectOwed(detector, 3)
        _ = try Fixture.feed(&detector, 0, "bnd.p")
        _ = try detector.clear(BindingID("bnd.l"))
        _ = try detector.clear(BindingID("bnd.t"))
        Self.expectOwed(detector, 3)
        #expect(try Fixture.feed(&detector, 0, "bnd.b")?.action == .release)
        Self.expectOwed(detector, 2)
        #expect(try detector.forgetHeld(on: [Fixture.pedal]).map(\.binding.rawValue) == ["bnd.a"])
        Self.expectOwed(detector, 1)
        #expect(try detector.forgetHeld(on: [Fixture.pedal]) == [])
        Self.expectOwed(detector, 1)
        #expect(try detector.forgetHeld(on: [Fixture.button]).count == 1)
        Self.expectOwed(detector, 0)
        // A rebuilt detector starts with nothing owed.
        _ = try Fixture.feed(&detector, 1, "bnd.a")
        Self.expectOwed(detector, 1)
        detector = try ControlTriggerDetector(bindings: bindings, after: detector.lastSequence)
        Self.expectOwed(detector, 0)
    }

    /// 10,000 seeded operations (inputs under live, missing-target, non-live and stale truth; clears; disconnects;
    /// rebuilds near and far from exhaustion). After every one, `owedCount` equals the full recount and the public
    /// count, a refusal changed nothing, and releases were never refused.
    @Test
    func seededOwedCountMatchesTheFullRecount() throws {
        var random = ClearSeededGenerator(seed: 0x363B_4C1E_A40E_D000)
        let sources = [Fixture.pedal, Fixture.button, try ControlSourceID("ctl.knee-3")]
        let targets = [Fixture.next, Fixture.fire]
        var bindings: [ControlTriggerBinding] = []
        for index in 0..<12 {
            let mode = ControlTriggerMode.allCases[index % 3]
            let emits: Bool? = mode == .momentary && index != 3 ? true : nil
            bindings.append(try Fixture.binding("bnd.r\(index)", source: sources[index % 3],
                                                target: targets[index % 2], mode: mode, emitsRelease: emits))
        }
        let truths = [
            try Fixture.truth(sources: Set(sources)),
            try Fixture.truth(sources: Set(sources), targets: [Fixture.next: .live]),
            try Fixture.truth(sources: Set(sources), targets: [Fixture.next: .live, Fixture.fire: .hazardous]),
            try Fixture.truth(sources: [Fixture.pedal, Fixture.button])
        ]
        let positions: [Double] = [0, 0.1, 0.25, 0.3, 0.5, 0.8, 1, -0.1, .nan]
        let starts: [UInt64] = [0, .max - 2, .max - 4, .max - 8, .max - 16]
        var detector = try ControlTriggerDetector(bindings: bindings)
        var counts = (refused: 0, exhausted: 0, emitted: 0, owedMax: 0)
        for _ in 0..<10_000 {
            let before = detector
            let roll = random.next(below: 100)
            do {
                if roll < 70 {
                    let binding = bindings[random.next(below: bindings.count)]
                    let position = positions[random.next(below: positions.count)]
                    let releasing = before.state(of: binding.id)?.held == true && binding.emitsRelease == true
                        && position >= 0 && position <= binding.releaseAt
                    do {
                        let command = try detector.handle(.absolute(normalized: position), from: binding.source,
                                                          binding: binding.id,
                                                          truth: truths[random.next(below: truths.count)])
                        if command != nil { counts.emitted += 1 }
                    } catch {
                        #expect(!(releasing && error == .sequenceExhausted))
                        throw error
                    }
                } else if roll < 85 {
                    if try detector.clear(bindings[random.next(below: bindings.count)].id) != nil {
                        counts.emitted += 1
                    }
                } else if roll < 95 {
                    let forgotten = Set(sources.filter { _ in random.next(below: 2) == 0 })
                    let released = try detector.forgetHeld(on: forgotten)
                    #expect(released.count == before.owedCount - detector.owedCount)
                    counts.emitted += released.count
                } else {
                    detector = try ControlTriggerDetector(bindings: bindings,
                                                          after: starts[random.next(below: starts.count)])
                }
            } catch let refusal as ControlTriggerRefusal {
                #expect(detector == before)
                counts.refused += 1
                if refusal == .sequenceExhausted { counts.exhausted += 1 }
            }
            let owed = detector.recountOwedReleases()
            #expect(detector.owedCount == owed)
            #expect(Self.publicOwed(detector) == owed)
            counts.owedMax = max(counts.owedMax, owed)
        }
        // The sequence exercised every path, not just the easy ones.
        #expect(counts.refused > 500)
        #expect(counts.exhausted > 20)
        #expect(counts.emitted > 1000)
        #expect(counts.owedMax >= 3)
    }
}

/// SplitMix64, private to this suite so its name cannot collide in the shared test module.
private struct ClearSeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Int(value % UInt64(bound))
    }
}
