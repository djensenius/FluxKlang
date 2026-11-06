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
        #expect(first?.cause == .input)
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
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try latch.clear(Self.id) }
        #expect(latch == latched)
        #expect(latch.state(of: Self.id)?.isOn == true)
    }

    @Test
    func staleControlSourceIsRefusedWithoutStateChange() throws {
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
        #expect(try detector.forgetHeld(on: [Fixture.button]) == [])
        #expect(detector == before)
        #expect(try detector.forgetHeld(on: [Fixture.pedal]) == [])
        #expect(detector.state(of: Self.id)?.held == false)
        #expect(detector.state(of: Self.id)?.isOn == true)
        #expect(detector.lastSequence == 1)
        #expect(try Fixture.feed(&detector, 1)?.action == .switchedOff)
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
        let held = detector
        #expect(throws: ControlTriggerRefusal.targetClass(Fixture.next, .hazardous)) {
            try detector.handle(.absolute(normalized: 0.4), from: Fixture.pedal, binding: Self.id, truth: hazardous)
        }
        #expect(detector == held)
        // Clearing only ends an action: it needs no truth, so a hazardous or missing target cannot leave it stuck.
        let cleared = try detector.clear(Self.id)
        #expect(cleared?.action == .switchedOff)
        #expect(cleared?.cause == .clear)
        #expect(cleared?.sequence == 2)
    }

    @Test
    func releaseEdgesSkipTheTargetChecks() throws {
        let gone = try Fixture.truth(targets: [Fixture.fire: .live])
        var truths = [gone]
        for controlClass in ControlClass.allCases where controlClass != .live {
            truths.append(try Fixture.truth(targets: [Fixture.next: controlClass]))
        }
        for truth in truths {
            var detector = try ControlTriggerDetector(bindings: [Fixture.binding(emitsRelease: true)])
            #expect(try Fixture.feed(&detector, 1)?.action == .press)
            let release = try detector.handle(.absolute(normalized: 0), from: Fixture.pedal, binding: Self.id,
                                              truth: truth)
            #expect(release?.action == .release)
            #expect(release?.cause == .input)
            #expect(release?.sequence == 2)
            #expect(detector.state(of: Self.id)?.held == false)
            #expect(throws: ControlTriggerRefusal.self) {
                try detector.handle(.absolute(normalized: 1), from: Fixture.pedal, binding: Self.id, truth: truth)
            }
            #expect(detector.state(of: Self.id)?.held == false)
        }
        var toggle = try ControlTriggerDetector(bindings: [Fixture.binding(mode: .toggle)])
        #expect(try Fixture.feed(&toggle, 1)?.action == .switchedOn)
        #expect(try toggle.handle(.absolute(normalized: 0), from: Fixture.pedal, binding: Self.id, truth: gone) == nil)
        #expect(toggle.state(of: Self.id)?.held == false)
        #expect(toggle.state(of: Self.id)?.isOn == true)
    }

    @Test
    func forgetHeldReleasesHeldOptedInMomentaryBindingsInIDOrder() throws {
        let bindings = [
            try Fixture.binding("bnd.c", emitsRelease: true), try Fixture.binding("bnd.a", emitsRelease: true),
            try Fixture.binding("bnd.b"), try Fixture.binding("bnd.d", source: Fixture.button, emitsRelease: true),
            try Fixture.binding("bnd.t", mode: .toggle), try Fixture.binding("bnd.l", mode: .latch)
        ]
        var detector = try ControlTriggerDetector(bindings: bindings)
        for binding in bindings {
            #expect(try Fixture.feed(&detector, 1, binding.id.rawValue, source: binding.source) != nil)
        }
        let released = try detector.forgetHeld(on: [Fixture.pedal])
        #expect(released.map(\.binding) == [try BindingID("bnd.a"), try BindingID("bnd.c")])
        #expect(released.map(\.action) == [.release, .release])
        #expect(released.map(\.cause) == [.disconnect, .disconnect])
        #expect(released.map(\.sequence) == [7, 8])
        #expect(released.allSatisfy { $0.source == Fixture.pedal && $0.target == Fixture.next })
        #expect(detector.lastSequence == 8)
        for binding in bindings {
            #expect(detector.state(of: binding.id)?.held == (binding.source == Fixture.button))
            #expect(detector.state(of: binding.id)?.isOn == [ControlTriggerMode.toggle, .latch].contains(binding.mode))
        }
        #expect(try detector.forgetHeld(on: [Fixture.pedal]) == [])
        #expect(detector.lastSequence == 8)
        #expect(try Fixture.feed(&detector, 1, "bnd.a")?.sequence == 9)
        #expect(try Fixture.feed(&detector, 1, "bnd.t")?.action == .switchedOff)
    }

    @Test
    func forgetHeldOrdersManyReleasesByBindingID() throws {
        let names = (0..<16).map { "bnd.k\(String(format: "%02d", $0))" }
        var detector = try ControlTriggerDetector(bindings: names.map { try Fixture.binding($0, emitsRelease: true) },
                                                  after: 100)
        for name in names.reversed() { _ = try Fixture.feed(&detector, 1, name) }
        let released = try detector.forgetHeld(on: [Fixture.pedal, Fixture.button])
        #expect(released.map(\.binding.rawValue) == names)
        #expect(released.map(\.sequence) == Array(117...132))
    }

    @Test
    func pressesReserveSequencesForEveryOwedRelease() throws {
        let first = try Fixture.binding("bnd.a", emitsRelease: true)
        let second = try Fixture.binding("bnd.b", emitsRelease: true)
        let plain = try Fixture.binding("bnd.c")
        var detector = try ControlTriggerDetector(bindings: [first, second, plain], after: .max - 3)
        #expect(try Fixture.feed(&detector, 1, "bnd.a")?.sequence == .max - 2)
        let before = detector
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try Fixture.feed(&detector, 1, "bnd.b") }
        #expect(detector == before)
        #expect(try Fixture.feed(&detector, 1, "bnd.c")?.sequence == .max - 1)
        #expect(try Fixture.feed(&detector, 0, "bnd.c") == nil)
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try Fixture.feed(&detector, 1, "bnd.c") }
        let release = try Fixture.feed(&detector, 0, "bnd.a")
        #expect(release?.action == .release)
        #expect(release?.sequence == .max)

        var single = try ControlTriggerDetector(bindings: [first], after: .max - 1)
        #expect(throws: ControlTriggerRefusal.sequenceExhausted) { try Fixture.feed(&single, 1, "bnd.a") }
        #expect(single.state(of: first.id)?.held == false)
        var disconnected = try ControlTriggerDetector(bindings: [first, second], after: .max - 4)
        #expect(try Fixture.feed(&disconnected, 1, "bnd.a")?.sequence == .max - 3)
        #expect(try Fixture.feed(&disconnected, 1, "bnd.b")?.sequence == .max - 2)
        #expect(try disconnected.forgetHeld(on: [Fixture.pedal]).map(\.sequence) == [.max - 1, .max])
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
        #expect(throws: ControlTriggerRefusal.inputMismatch) {
            try detector.handle(.relative(delta: 1), from: Fixture.pedal, binding: Self.id, truth: unsafe)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ControlTriggerRefusal.nonFinite) {
                try detector.handle(.absolute(normalized: value), from: Fixture.pedal, binding: Self.id, truth: unsafe)
            }
        }
        for value in [-0.01, 1.01] {
            #expect(throws: ControlTriggerRefusal.inputOutOfRange(value)) {
                try detector.handle(.absolute(normalized: value), from: Fixture.pedal, binding: Self.id, truth: unsafe)
            }
        }
        let missing = try Fixture.truth(targets: [Fixture.fire: .safety])
        #expect(throws: ControlTriggerRefusal.targetMissing(Fixture.next)) {
            try detector.handle(.absolute(normalized: 1), from: Fixture.pedal, binding: Self.id, truth: missing)
        }
        #expect(throws: ControlTriggerRefusal.targetClass(Fixture.next, .safety)) {
            try detector.handle(.absolute(normalized: 1), from: Fixture.pedal, binding: Self.id, truth: unsafe)
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
        #expect(ControlTriggerHostTruth.maximumSources == ControlTriggerDetector.maximumBindings)
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
