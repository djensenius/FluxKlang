import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ControlTriggerTests {
    static let pedal = ControlSourceID(validated: "ctl.pedal-1")
    static let button = ControlSourceID(validated: "ctl.button-2")
    static let next = ControlTriggerTargetID(validated: "trg.show.next")
    static let fire = ControlTriggerTargetID(validated: "trg.action.fire")

    static func fields(_ id: String = "bnd.trigger", source: ControlSourceID = pedal,
                       target: ControlTriggerTargetID = next, profile: EncoderProfile = .absolute(resolution: 128),
                       mode: ControlTriggerMode = .momentary, pressAt: Double = 0.5, releaseAt: Double = 0.25,
                       emitsRelease: Bool? = nil) throws -> ControlTriggerBindingFields {
        ControlTriggerBindingFields(id: try BindingID(id), source: source, target: target, profile: profile,
                                    mode: mode, pressAt: pressAt, releaseAt: releaseAt, emitsRelease: emitsRelease)
    }

    static func binding(_ id: String = "bnd.trigger", source: ControlSourceID = pedal,
                        target: ControlTriggerTargetID = next, mode: ControlTriggerMode = .momentary,
                        pressAt: Double = 0.5, releaseAt: Double = 0.25,
                        emitsRelease: Bool? = nil) throws -> ControlTriggerBinding {
        try ControlTriggerBinding(fields(id, source: source, target: target, mode: mode, pressAt: pressAt,
                                         releaseAt: releaseAt, emitsRelease: emitsRelease))
    }

    static func truth(sources: Set<ControlSourceID> = [pedal, button],
                      targets: [ControlTriggerTargetID: ControlClass] = [next: .live, fire: .live]) throws
        -> ControlTriggerHostTruth {
        try ControlTriggerHostTruth(sources: sources, targets: targets)
    }

    /// Feeds one absolute position to `id` from its own source under live truth.
    static func feed(_ detector: inout ControlTriggerDetector, _ position: Double,
                     _ id: String = "bnd.trigger", source: ControlSourceID = pedal) throws -> ControlTriggerCommand? {
        try detector.handle(.absolute(normalized: position), from: source, binding: BindingID(id), truth: truth())
    }

    /// Feeds positions in order and returns the action of every input (`nil` where nothing was emitted).
    static func actions(_ detector: inout ControlTriggerDetector, _ positions: [Double],
                        _ id: String = "bnd.trigger") throws -> [ControlTriggerAction?] {
        var result: [ControlTriggerAction?] = []
        for position in positions { result.append(try feed(&detector, position, id)?.action) }
        return result
    }

    @Test
    func constructionAcceptsBoundaryThresholdsAndRefusesInvalidOnes() throws {
        _ = try Self.binding(pressAt: 1, releaseAt: 0)
        _ = try Self.binding(pressAt: 0.5, releaseAt: 0.4999)
        _ = try Self.binding(mode: .toggle, emitsRelease: false)
        _ = try Self.binding(mode: .momentary, emitsRelease: true)
        let invalid: [(Double, Double)] = [
            (0.5, 0.5), (0.4, 0.5), (0.5, -0.01), (1.01, 0.2), (.nan, 0.2), (0.5, .nan),
            (.infinity, 0.2), (0.5, -.infinity), (0, 0)
        ]
        for (pressAt, releaseAt) in invalid {
            #expect(throws: ControlValidationError.self) { try Self.binding(pressAt: pressAt, releaseAt: releaseAt) }
        }
        for mode in [ControlTriggerMode.toggle, .latch] {
            #expect(throws: ControlValidationError.self) { try Self.binding(mode: mode, emitsRelease: true) }
        }
    }

    @Test
    func constructionRefusesRelativeAndInvalidProfiles() throws {
        let refused: [EncoderProfile] = [
            .binaryOffset(width: .seven), .twosComplement(width: .seven), .signMagnitude(width: .fourteen)
        ]
        for profile in refused {
            #expect(throws: ControlValidationError.self) { try ControlTriggerBinding(Self.fields(profile: profile)) }
        }
        for resolution in [0, 1, EncoderProfile.maximumResolution + 1] {
            #expect(throws: EncoderDecodeError.invalidResolution(resolution)) {
                try ControlTriggerBinding(Self.fields(profile: .absolute(resolution: resolution)))
            }
        }
        _ = try ControlTriggerBinding(Self.fields(profile: .absolute(resolution: 2)))
    }

    @Test
    func codableRoundTripKeepsUnknownFields() throws {
        let wire = #"{"future":{"a":1},"id":"bnd.trigger","mode":"latch","pressAt":0.5,"#
            + #""profile":{"absolute":{"resolution":128}},"releaseAt":0.25,"source":"ctl.pedal-1","#
            + #""target":"trg.show.next"}"#
        let decoded = try ContractCoding.decode(ControlTriggerBinding.self, from: Data(wire.utf8))
        #expect(decoded.fields == (try Self.fields(mode: .latch)))
        #expect(decoded.unknownFields == ["future": .object(["a": .int(1)])])
        #expect(try ContractCoding.makeEncoder().encode(decoded) == Data(wire.utf8))
        let invalid = wire.replacingOccurrences(of: #""releaseAt":0.25"#, with: #""releaseAt":0.75"#)
        #expect(throws: (any Error).self) {
            try ContractCoding.decode(ControlTriggerBinding.self, from: Data(invalid.utf8))
        }
    }

    @Test
    func noRepeatWhileHeld() throws {
        var detector = try ControlTriggerDetector(bindings: [Self.binding()])
        let actions = try Self.actions(&detector, [0.6, 0.9, 1, 1, 0.6, 0.3, 0.5, 0.26, 0.25, 0.7, 1])
        #expect(actions == [.press, nil, nil, nil, nil, nil, nil, nil, nil, .press, nil])
        #expect(detector.lastSequence == 2)
        #expect(detector.state(of: try BindingID("bnd.trigger"))?.held == true)
    }

    @Test
    func hysteresisBandHonoursExactThresholds() throws {
        var detector = try ControlTriggerDetector(bindings: [Self.binding(emitsRelease: true)])
        let rising = try Self.actions(&detector, [0, 0.25, 0.4999, 0.5])
        #expect(rising == [nil, nil, nil, .press])
        let falling = try Self.actions(&detector, [0.4999, 0.2501, 0.25])
        #expect(falling == [nil, nil, .release])
        let chatter = try Self.actions(&detector, [0.3, 0.45, 0.26, 0.4999, 0.3])
        #expect(chatter == [nil, nil, nil, nil, nil])
        let again = try Self.actions(&detector, [0.5, 0.26, 0.4999, 0])
        #expect(again == [.press, nil, nil, .release])
    }

    @Test
    func rawButtonDecodesThroughItsOwnProfile() throws {
        let fields = try Self.fields(profile: .absolute(resolution: 2), pressAt: 1, releaseAt: 0)
        var detector = try ControlTriggerDetector(bindings: [ControlTriggerBinding(fields)])
        var actions: [ControlTriggerAction?] = []
        for raw in [0, 1, 1, 0, 1] {
            let input = try fields.profile.decode(raw: raw)
            let command = try detector.handle(input, from: Self.pedal, binding: fields.id, truth: Self.truth())
            actions.append(command?.action)
        }
        #expect(actions == [nil, .press, nil, nil, .press])
    }

    @Test
    func momentaryReleaseIsOptInButHeldStateIsAlwaysTracked() throws {
        let id = try BindingID("bnd.trigger")
        let cases: [(Bool?, ControlTriggerAction?)] = [(nil, nil), (false, nil), (true, .release)]
        for (emits, release) in cases {
            var detector = try ControlTriggerDetector(bindings: [Self.binding(emitsRelease: emits)])
            #expect(try Self.feed(&detector, 0.8)?.action == .press)
            #expect(detector.state(of: id)?.held == true)
            #expect(try Self.feed(&detector, 0.1)?.action == release)
            #expect(detector.state(of: id)?.held == false)
            #expect(detector.state(of: id)?.isOn == false)
            #expect(detector.lastSequence == (release == nil ? 1 : 2))
        }
    }

    @Test
    func toggleFlipsOnEachPressEdgeOnly() throws {
        let id = try BindingID("bnd.trigger")
        var detector = try ControlTriggerDetector(bindings: [Self.binding(mode: .toggle)])
        let actions = try Self.actions(&detector, [0.9, 1, 0, 0.9, 0.6, 0.1, 0.7, 0.2])
        #expect(actions == [.switchedOn, nil, nil, .switchedOff, nil, nil, .switchedOn, nil])
        #expect(detector.state(of: id)?.isOn == true)
        #expect(detector.lastSequence == 3)
        #expect(throws: ControlTriggerRefusal.notLatch(.toggle)) { try detector.clear(id, truth: Self.truth()) }
    }

    @Test
    func latchStaysOnUntilExplicitClear() throws {
        let id = try BindingID("bnd.trigger")
        var detector = try ControlTriggerDetector(bindings: [Self.binding(mode: .latch)])
        let actions = try Self.actions(&detector, [0.9, 0, 0.9, 0, 1])
        #expect(actions == [.switchedOn, nil, nil, nil, nil])
        #expect(detector.lastSequence == 1)
        let cleared = try detector.clear(id, truth: Self.truth())
        #expect(cleared?.action == .switchedOff)
        #expect(cleared?.sequence == 2)
        #expect(detector.state(of: id)?.isOn == false)
        #expect(detector.state(of: id)?.held == true)
        #expect(try detector.clear(id, truth: Self.truth()) == nil)
        #expect(detector.lastSequence == 2)
        #expect(try Self.actions(&detector, [1, 0, 0.8]) == [nil, nil, .switchedOn])
        #expect(detector.lastSequence == 3)
    }

    @Test
    func clearIsLatchOnly() throws {
        var detector = try ControlTriggerDetector(bindings: [Self.binding()])
        #expect(throws: ControlTriggerRefusal.notLatch(.momentary)) {
            try detector.clear(BindingID("bnd.trigger"), truth: Self.truth())
        }
        #expect(throws: ControlTriggerRefusal.unknownBinding(try BindingID("bnd.other"))) {
            try detector.clear(BindingID("bnd.other"), truth: Self.truth())
        }
    }
}
