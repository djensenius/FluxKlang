import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ControlTriggerDetectorTests {
    typealias Fixture = ControlTriggerTests
    static let id = BindingID(validated: "bnd.trigger")

    @Test
    func commandsCarryBindingTargetSourceAndAction() throws {
        let pedal = try Fixture.binding()
        let button = try Fixture.binding("bnd.button", source: Fixture.button, target: Fixture.fire, mode: .toggle)
        var detector = try ControlTriggerDetector(bindings: [button, pedal])
        #expect(detector.bindings == [button, pedal])
        let first = try Fixture.feed(&detector, 0.9, "bnd.button", source: Fixture.button)
        #expect(first?.binding == button.id)
        #expect(first?.target == Fixture.fire)
        #expect(first?.source == Fixture.button)
        #expect(first?.action == .switchedOn)
        #expect(first?.sequence == 1)
        let second = try Fixture.feed(&detector, 0.9)
        #expect(second?.binding == pedal.id)
        #expect(second?.target == Fixture.next)
        #expect(second?.source == Fixture.pedal)
        #expect(second?.action == .press)
        #expect(second?.sequence == 2)
    }

    @Test
    func sequenceNeverGoesBackwardsAcrossBindings() throws {
        let toggle = try Fixture.binding("bnd.toggle", source: Fixture.button, target: Fixture.fire, mode: .toggle)
        var detector = try ControlTriggerDetector(bindings: [Fixture.binding(emitsRelease: true), toggle], after: 41)
        var sequences: [UInt64] = []
        for step in 0..<40 {
            let position = step % 3 == 0 ? 0.0 : 1.0
            if let command = try Fixture.feed(&detector, position) { sequences.append(command.sequence) }
            if let command = try Fixture.feed(&detector, 1 - position, "bnd.toggle", source: Fixture.button) {
                sequences.append(command.sequence)
            }
        }
        #expect(sequences.first == 42)
        #expect(sequences == Array(42..<UInt64(42 + sequences.count)))
        #expect(detector.lastSequence == sequences.last)
    }

    @Test
    func sequenceSaturatesAtMaximumWithoutWrapping() throws {
        var detector = try ControlTriggerDetector(bindings: [Fixture.binding()], after: .max - 1)
        #expect(try Fixture.feed(&detector, 1)?.sequence == .max)
        #expect(try Fixture.feed(&detector, 0) == nil)
        let before = detector
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try Fixture.feed(&detector, 1) }
        #expect(detector == before)
        #expect(detector.state(of: Self.id)?.held == false)
        #expect(detector.lastSequence == .max)
        #expect(try Fixture.feed(&detector, 0.3) == nil)

        var latch = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .latch)], after: .max - 1)
        #expect(try Fixture.feed(&latch, 1)?.sequence == .max)
        let latched = latch
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try latch.clear(Self.id, truth: Fixture.truth()) }
        #expect(latch == latched)
        #expect(latch.state(of: Self.id)?.isOn == true)
    }

    @Test
    func staleControllerIsRefusedWithoutStateChange() throws {
        var detector = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .toggle)])
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOn)
        let before = detector
        let stale = try Fixture.truth(sources: [Fixture.button])
        for position in [0.0, 1.0] {
            #expect(throws: ControlTriggerRefusal.controllerStale(Fixture.pedal)) {
                try detector.handle(.absolute(normalized: position), from: Fixture.pedal, binding: Self.id,
                                    truth: stale)
            }
        }
        #expect(detector == before)
        #expect(detector.state(of: Self.id)?.held == true)
        detector.forgetHeld(on: Fixture.button)
        #expect(detector == before)
        detector.forgetHeld(on: Fixture.pedal)
        #expect(detector.state(of: Self.id)?.held == false)
        #expect(detector.state(of: Self.id)?.isOn == true)
        #expect(detector.lastSequence == 1)
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOff)
    }

    @Test
    func clearDoesNotRequireACurrentController() throws {
        var detector = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .latch)])
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOn)
        let cleared = try detector.clear(Self.id, truth: Fixture.truth(sources: []))
        #expect(cleared?.action == .switchedOff)
    }

    @Test
    func hazardousAndOtherNonLiveTargetsAreRefused() throws {
        var detector = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .latch)])
        for controlClass in ControlClass.allCases where controlClass != .live {
            let truth = try Fixture.truth(targets: [Fixture.next: controlClass])
            let before = detector
            #expect(throws: ControlTriggerRefusal.targetClass(Fixture.next, controlClass)) {
                try detector.handle(.absolute(normalized: 1), from: Fixture.pedal, binding: Self.id, truth: truth)
            }
            #expect(detector == before)
        }
        let missing = try Fixture.truth(targets: [Fixture.fire: .live])
        #expect(throws: ControlTriggerRefusal.targetMissing(Fixture.next)) {
            try detector.handle(.absolute(normalized: 1), from: Fixture.pedal, binding: Self.id, truth: missing)
        }
        #expect(detector.state(of: Self.id)?.held == false)
        #expect(detector.lastSequence == 0)
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOn)
        let hazardous = try Fixture.truth(targets: [Fixture.next: .hazardous])
        let latched = detector
        #expect(throws: ControlTriggerRefusal.targetClass(Fixture.next, .hazardous)) {
            try detector.clear(Self.id, truth: hazardous)
        }
        #expect(throws: ControlTriggerRefusal.targetMissing(Fixture.next)) {
            try detector.clear(Self.id, truth: missing)
        }
        #expect(detector == latched)
    }

    @Test
    func refusalsComeInDocumentedOrderAndChangeNothing() throws {
        var detector = try ControlTriggerDetector(bindings: [Fixture.binding()])
        let before = detector
        let empty = try ControlTriggerHostTruth(sources: [], targets: [Fixture.next: .safety])
        let other = try BindingID("bnd.other")
        #expect(throws: ControlTriggerRefusal.unknownBinding(other)) {
            try detector.handle(.relative(delta: 1), from: Fixture.button, binding: other, truth: empty)
        }
        #expect(throws: ControlTriggerRefusal.sourceMismatch(expected: Fixture.pedal, found: Fixture.button)) {
            try detector.handle(.relative(delta: 1), from: Fixture.button, binding: Self.id, truth: empty)
        }
        #expect(throws: ControlTriggerRefusal.controllerStale(Fixture.pedal)) {
            try detector.handle(.relative(delta: 1), from: Fixture.pedal, binding: Self.id, truth: empty)
        }
        let unsafe = try Fixture.truth(targets: [Fixture.next: .safety])
        #expect(throws: ControlTriggerRefusal.targetClass(Fixture.next, .safety)) {
            try detector.handle(.relative(delta: 1), from: Fixture.pedal, binding: Self.id, truth: unsafe)
        }
        let live = try Fixture.truth()
        #expect(throws: ControlTriggerRefusal.inputMismatch) {
            try detector.handle(.relative(delta: 1), from: Fixture.pedal, binding: Self.id, truth: live)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ControlTriggerRefusal.nonFinite) { try Fixture.feed(&detector, value) }
        }
        for value in [-0.01, 1.01] {
            #expect(throws: ControlTriggerRefusal.inputOutOfRange(value)) { try Fixture.feed(&detector, value) }
        }
        #expect(detector == before)
    }

    @Test
    func constructionIsBounded() throws {
        let duplicate = try Fixture.binding()
        #expect(throws: ControlTriggerRefusal.duplicateBinding(duplicate.id)) {
            try ControlTriggerDetector(bindings: [duplicate, Fixture.binding("bnd.b"), duplicate])
        }
        let bindings = try (0...ControlTriggerDetector.maximumBindings).map { try Fixture.binding("bnd.t\($0)") }
        _ = try ControlTriggerDetector(bindings: Array(bindings.dropLast()))
        #expect(throws: ControlTriggerRefusal.tooManyBindings(bindings.count)) {
            try ControlTriggerDetector(bindings: bindings)
        }
        let sources = try Set((0...ControlTriggerHostTruth.maximumSources).map { try ControlSourceID("ctl.s\($0)") })
        _ = try ControlTriggerHostTruth(sources: Set(sources.dropFirst()), targets: [:])
        #expect(throws: ControlTriggerRefusal.tooManySources(sources.count)) {
            try ControlTriggerHostTruth(sources: sources, targets: [:])
        }
        var targets: [ControlTriggerTargetID: ControlClass] = [:]
        for index in 0...ControlTriggerHostTruth.maximumTargets { targets[try .init("trg.t\(index)")] = .live }
        let fewer = targets.filter { $0.key.rawValue != "trg.t0" }
        _ = try ControlTriggerHostTruth(sources: [], targets: fewer)
        #expect(throws: ControlTriggerRefusal.tooManyTargets(targets.count)) {
            try ControlTriggerHostTruth(sources: [], targets: targets)
        }
    }
}
