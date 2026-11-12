import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
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
    func rawMIDIStepsCrossThresholdsAtTheGoldenRawValues() throws {
        // At resolution 128 raw r is r / 127: pressAt 0.5 first holds at raw 64 (63 is 0.496), and releaseAt 0.25
        // first holds at raw 31 (32 is 0.252).
        let fields = try Self.fields(emitsRelease: true)
        var detector = try ControlTriggerDetector(bindings: [ControlTriggerBinding(fields)])
        var edges: [Int: ControlTriggerAction] = [:]
        for raw in Array(0...127) + Array((0...126).reversed()) {
            let input = try fields.profile.decode(raw: raw)
            if let command = try detector.handle(input, from: Self.pedal, binding: fields.id, truth: Self.truth()) {
                edges[raw] = command.action
            }
        }
        #expect(edges == [64: .press, 31: .release])
        #expect(detector.lastSequence == 2)
    }

    @Test
    func emitsReleaseFalseIsNormalisedToNil() throws {
        #expect(try Self.fields(emitsRelease: false) == Self.fields(emitsRelease: nil))
        #expect(try Self.binding(emitsRelease: false) == Self.binding())
        #expect(try Self.fields(emitsRelease: false).emitsRelease == nil)
        #expect(try Self.fields(emitsRelease: true).emitsRelease == true)
        #expect(try Self.fields(emitsRelease: true) != Self.fields())
        let wire = #"{"emitsRelease":false,"id":"bnd.trigger","mode":"momentary","pressAt":0.5,"#
            + #""profile":{"absolute":{"resolution":128}},"releaseAt":0.25,"source":"ctl.pedal-1","#
            + #""target":"trg.show.next"}"#
        let decoded = try ContractCoding.decode(ControlTriggerBinding.self, from: Data(wire.utf8))
        #expect(decoded.fields == (try Self.fields()))
        // Deliberate: the decoded record keeps the `false` spelling for byte round-tripping, so records differ.
        #expect(decoded != (try Self.binding()))
        #expect(try ContractCoding.makeEncoder().encode(decoded) == Data(wire.utf8))
        let opted = wire.replacingOccurrences(of: #""emitsRelease":false"#, with: #""emitsRelease":true"#)
        let optedIn = try ContractCoding.decode(ControlTriggerBinding.self, from: Data(opted.utf8))
        #expect(optedIn.fields == (try Self.fields(emitsRelease: true)))
        #expect(try ContractCoding.makeEncoder().encode(optedIn) == Data(opted.utf8))
    }

    @Test
    func bindingsOnOneSourceFanOutIndependently() throws {
        let low = try Self.binding("bnd.low", pressAt: 0.3, releaseAt: 0.1, emitsRelease: true)
        let high = try Self.binding("bnd.high", mode: .toggle, pressAt: 0.8, releaseAt: 0.6)
        var detector = try ControlTriggerDetector(bindings: [low, high])
        var commands: [ControlTriggerCommand] = []
        for position in [0.5, 0.9, 0.7, 0.5, 0.05, 0.9] {
            for id in ["bnd.low", "bnd.high"] {
                if let command = try Self.feed(&detector, position, id) { commands.append(command) }
            }
        }
        let fired = commands.map { "\($0.binding.rawValue) \($0.action.rawValue) \($0.sequence)" }
        #expect(fired == ["bnd.low press 1", "bnd.high switchedOn 2", "bnd.low release 3", "bnd.low press 4",
                          "bnd.high switchedOff 5"])
        #expect(try detector.forgetHeld(on: [Self.button]) == [])
        #expect(detector.state(of: low.id)?.held == true)
        #expect(detector.state(of: high.id)?.held == true)
        let released = try detector.forgetHeld(on: [Self.pedal])
        #expect(released.map(\.binding) == [low.id])
        #expect(released.map(\.sequence) == [6])
        #expect(detector.state(of: low.id)?.held == false)
        #expect(detector.state(of: high.id)?.held == false)
        #expect(detector.state(of: high.id)?.isOn == false)
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
        let cleared = try detector.clear(id)
        #expect(cleared?.action == .switchedOff)
        #expect(cleared?.cause == .clear)
        #expect(cleared?.sequence == 4)
        #expect(detector.state(of: id)?.isOn == false)
        #expect(detector.state(of: id)?.held == false)
    }

    @Test
    func latchStaysOnUntilExplicitClear() throws {
        let id = try BindingID("bnd.trigger")
        var detector = try ControlTriggerDetector(bindings: [Self.binding(mode: .latch)])
        let actions = try Self.actions(&detector, [0.9, 0, 0.9, 0, 1])
        #expect(actions == [.switchedOn, nil, nil, nil, nil])
        #expect(detector.lastSequence == 1)
        let cleared = try detector.clear(id)
        #expect(cleared?.action == .switchedOff)
        #expect(cleared?.sequence == 2)
        #expect(detector.state(of: id)?.isOn == false)
        #expect(detector.state(of: id)?.held == true)
        #expect(try detector.clear(id) == nil)
        #expect(detector.lastSequence == 2)
        #expect(try Self.actions(&detector, [1, 0, 0.8]) == [nil, nil, .switchedOn])
        #expect(detector.lastSequence == 3)
    }

    @Test
    func clearRefusesMomentary() throws {
        var detector = try ControlTriggerDetector(bindings: [Self.binding()])
        #expect(throws: ControlTriggerRefusal.notClearable(.momentary)) {
            try detector.clear(BindingID("bnd.trigger"))
        }
        #expect(throws: ControlTriggerRefusal.unknownBinding(try BindingID("bnd.other"))) {
            try detector.clear(BindingID("bnd.other"))
        }
    }
}
