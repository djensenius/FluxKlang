import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A routing rule's optional `MIDIValueTransform` as the note ledger applies it: note-on velocity and controller
/// values on the way out, nothing on the release path.
@Suite(.productionAccessAudit)
struct MIDIRoutingCurveTests {
    typealias Fixture = MIDIPerformanceFixture

    static func transform(
        velocity: MIDIResponseCurve? = nil, controllers: [MIDIControllerCurve] = []
    ) throws -> MIDIValueTransform {
        try MIDIValueTransform.make(velocity: velocity, pressure: nil, controllers: controllers)
    }

    static func controllerCurve(_ number: UInt8, _ pairs: [(UInt8, UInt8)]) throws -> MIDIControllerCurve {
        let points = pairs.map { MIDICurvePoint(input: $0.0, output: $0.1) }
        let curve = try MIDIResponseCurve.make(domain: .controller, points: points)
        return MIDIControllerCurve(controller: number, curve: curve)
    }

    static func rule(
        _ route: MIDIRouteID, transform: MIDIValueTransform?, notes: ClosedRange<UInt8> = 0...127
    ) throws -> MIDIRoutingRule {
        try #require(MIDIRoutingRule(input: Fixture.keys, route: route, notes: notes, transform: transform))
    }

    static func fixed(_ velocity: UInt8) throws -> MIDIValueTransform {
        try transform(velocity: MIDIResponseCurve.fixedVelocity(velocity))
    }

    static func inverted(_ number: UInt8) throws -> MIDIValueTransform {
        try transform(controllers: [controllerCurve(number, [(0, 127), (127, 0)])])
    }

    @Test
    func fixedVelocityCurveSetsTheSentNoteOnVelocity() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.fixed(77)))
        let sent = try ledger.route(Fixture.on(60, 100), routing: routing)
        #expect(sent == [Fixture.sentOn(Fixture.piano, 60, 77)])
    }

    @Test
    func linearVelocityCurveSendsTheReceivedVelocity() throws {
        var ledger = MIDINoteLedger()
        let linear = try Self.transform(velocity: MIDIResponseCurve.linear(.velocity))
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: linear))
        let sent = try ledger.route(Fixture.on(60, 100), routing: routing)
        #expect(sent == [Fixture.sentOn(Fixture.piano, 60, 100)])
    }

    @Test
    func invertedControllerCurveReshapesValues() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.inverted(10)))
        let middle = try ledger.route(Fixture.control(10, 100), routing: routing)
        let bottom = try ledger.route(Fixture.control(10, 0), routing: routing)
        let top = try ledger.route(Fixture.control(10, 127), routing: routing)
        #expect(middle == [Fixture.sentControl(Fixture.piano, 10, 27)])
        #expect(bottom == [Fixture.sentControl(Fixture.piano, 10, 127)])
        #expect(top == [Fixture.sentControl(Fixture.piano, 10, 0)])
    }

    @Test
    func constantControllerCurveLeavesOtherControllersAlone() throws {
        var ledger = MIDINoteLedger()
        let constant = try Self.transform(controllers: [Self.controllerCurve(11, [(0, 5), (127, 5)])])
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: constant))
        let curved = try ledger.route(Fixture.control(11, 90), routing: routing)
        let unlisted = try ledger.route(Fixture.control(12, 90), routing: routing)
        #expect(curved == [Fixture.sentControl(Fixture.piano, 11, 5)])
        #expect(unlisted == [Fixture.sentControl(Fixture.piano, 12, 90)])
    }

    @Test
    func noteOffAfterACurvedPressReleasesTheSameNoteWithTheReceivedVelocity() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.fixed(77)))
        _ = try ledger.route(Fixture.on(60, 100), routing: routing)
        let released = try ledger.route(Fixture.off(60, 33), routing: routing)
        #expect(released == [Fixture.sentOff(Fixture.piano, 60, 33)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func noteOnWithVelocityZeroStillReleasesAfterACurvedPress() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.fixed(77)))
        _ = try ledger.route(Fixture.on(60, 100), routing: routing)
        let released = try ledger.route(Fixture.on(60, 0), routing: routing)
        #expect(released == [Fixture.sentOff(Fixture.piano, 60, MIDINoteLedger.releaseVelocity)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func replacingTheTableAfterACurvedPressStillReleasesTheOldRoute() throws {
        var ledger = MIDINoteLedger()
        let curved = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.fixed(77)))
        let moved = try Fixture.routing(Fixture.rule(Fixture.strings))
        _ = try ledger.route(Fixture.on(60, 100), routing: curved)
        let released = try ledger.route(Fixture.off(60, 20), routing: moved)
        #expect(released == [Fixture.sentOff(Fixture.piano, 60, 20)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func forwardedControllers121And124AreSentAsReceivedWhenARuleHasATransform() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.inverted(10)))
        let reset = try ledger.route(Fixture.control(121, 100), routing: routing)
        let local = try ledger.route(Fixture.control(124, 0), routing: routing)
        #expect(reset == [Fixture.sentControl(Fixture.piano, 121, 100)])
        #expect(local == [Fixture.sentControl(Fixture.piano, 124, 0)])
    }

    @Test
    func sustainPedalDownAndUpAreSentAsReceivedWhenARuleHasATransform() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.inverted(10)))
        let down = try ledger.route(Fixture.control(64, 100), routing: routing)
        let heldDown = ledger.isPedalDown(.sustain, route: Fixture.piano, channel: 1)
        let released = try ledger.route(Fixture.control(64, 0), routing: routing)
        let heldUp = ledger.isPedalDown(.sustain, route: Fixture.piano, channel: 1)
        #expect(down == [Fixture.sentControl(Fixture.piano, 64, 100)])
        #expect(heldDown)
        #expect(released == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(!heldUp)
    }

    @Test
    func ruleInitializerRefusesAPressureCurveAndAcceptsTheOthers() throws {
        let pressure = MIDIResponseCurve.linear(.controller)
        let withPressure = try MIDIValueTransform.make(velocity: nil, pressure: pressure, controllers: [])
        let refused = MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, transform: withPressure)
        let identity = MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, transform: .identity)
        let absent = MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, transform: nil)
        let velocityOnly = MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, transform: try Self.fixed(77))
        #expect(refused == nil)
        #expect(identity != nil)
        #expect(absent != nil)
        #expect(velocityOnly != nil)
    }

    @Test
    func ruleInitializerStillChecksChannelsWhenTheTransformIsValid() throws {
        let badChannels = MIDIRoutingRule(
            input: Fixture.keys, route: Fixture.piano, channels: 0...16, transform: try Self.fixed(77)
        )
        #expect(badChannels == nil)
    }

    @Test
    func rulesDifferingOnlyInTheirTransformAreNotEqual() throws {
        let plain = try Fixture.rule(Fixture.piano)
        let curved = try Self.rule(Fixture.piano, transform: Self.fixed(77))
        let sameCurve = try Self.rule(Fixture.piano, transform: Self.fixed(77))
        let otherCurve = try Self.rule(Fixture.piano, transform: Self.fixed(78))
        let samePlain = try Self.rule(Fixture.piano, transform: nil)
        #expect(plain != curved)
        #expect(curved == sameCurve)
        #expect(curved != otherCurve)
        #expect(plain == samePlain)
        #expect(Set([plain, curved, sameCurve, otherCurve, samePlain]).count == 3)
    }

    @Test
    func twoRulesToOneRouteWithDifferentCurvesSendOneNoteOnAndRecordOneInstance() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(
            Self.rule(Fixture.piano, transform: Self.fixed(77)), Self.rule(Fixture.piano, transform: Self.fixed(30))
        )
        let sent = try ledger.route(Fixture.on(60, 100), routing: routing)
        #expect(sent == [Fixture.sentOn(Fixture.piano, 60, 77)])
        #expect(ledger.notes.count == 1)
    }

    @Test
    func anUncurvedRuleBeforeACurvedRuleToTheSameRouteSendsTheReceivedVelocity() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(
            Fixture.rule(Fixture.piano), Self.rule(Fixture.piano, transform: Self.fixed(77))
        )
        let sent = try ledger.route(Fixture.on(60, 100), routing: routing)
        #expect(sent == [Fixture.sentOn(Fixture.piano, 60, 100)])
        #expect(ledger.notes.count == 1)
    }

    @Test
    func rulesToDifferentRoutesEachShapeTheirOwnNoteOn() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(
            Self.rule(Fixture.piano, transform: Self.fixed(77)), Self.rule(Fixture.strings, transform: Self.fixed(30)),
            Self.rule(Fixture.bass, transform: Self.fixed(77))
        )
        let sent = try ledger.route(Fixture.on(60, 100), routing: routing)
        let expected = [
            Fixture.sentOn(Fixture.piano, 60, 77), Fixture.sentOn(Fixture.strings, 60, 30),
            Fixture.sentOn(Fixture.bass, 60, 77)
        ]
        #expect(sent == expected)
        #expect(ledger.notes.count == 3)
    }

    @Test
    func twoRulesToOneRouteWithDifferentControllerCurvesSendOneControlChange() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(
            Self.rule(Fixture.piano, transform: Self.inverted(10)), Fixture.rule(Fixture.piano)
        )
        let sent = try ledger.route(Fixture.control(10, 100), routing: routing)
        #expect(sent == [Fixture.sentControl(Fixture.piano, 10, 27)])
    }

    @Test
    func sustainPedalDownThroughTwoLayeredRulesToOneRouteSendsOneControlChangeAndOneHold() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(
            Self.rule(Fixture.piano, transform: Self.inverted(10)), Fixture.rule(Fixture.piano)
        )
        let sent = try ledger.route(Fixture.control(64, 127), routing: routing)
        #expect(sent == [Fixture.sentControl(Fixture.piano, 64, 127)])
        #expect(ledger.pedalHolds.count == 1)
    }

    @Test
    func heldPedalCarriedToOneNewRouteSendsOneControlChangeWhenTwoRulesReachIt() throws {
        var ledger = MIDINoteLedger()
        let first = try Fixture.routing(Fixture.rule(Fixture.piano, notes: 0...59))
        let layered = try Fixture.routing(
            Fixture.rule(Fixture.piano, notes: 0...59), Self.rule(Fixture.strings, transform: Self.fixed(77)),
            Fixture.rule(Fixture.strings)
        )
        _ = try ledger.route(Fixture.control(64, 127), routing: first)
        let sent = try ledger.route(Fixture.on(70, 100), routing: layered)
        #expect(sent == [Fixture.sentControl(Fixture.strings, 64, 127), Fixture.sentOn(Fixture.strings, 70, 77)])
    }

    @Test
    func channelPressureAndPolyPressureAreSentAsReceivedWhenARuleHasATransform() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.fixed(77)))
        _ = try ledger.route(Fixture.on(60, 100), routing: routing)
        let polyEvent = Fixture.event(.polyphonicPressure(channel: 1, note: 60, pressure: 90))
        let channelEvent = Fixture.event(.channelPressure(channel: 1, pressure: 90))
        let poly = try ledger.route(polyEvent, routing: routing)
        let channel = try ledger.route(channelEvent, routing: routing)
        let channelSent = MIDIRoutedOutput(route: Fixture.piano, message: .channelPressure(channel: 1, pressure: 90))
        #expect(poly == [Fixture.sentPressure(Fixture.piano, 60, 90)])
        #expect(channel == [channelSent])
    }

    @Test
    func identityTransformSendsTheSameBytesAsNoTransform() throws {
        var plainLedger = MIDINoteLedger()
        var identityLedger = MIDINoteLedger()
        let plain = try Fixture.routing(Fixture.rule(Fixture.piano))
        let identity = try Fixture.routing(Self.rule(Fixture.piano, transform: .identity))
        let events = [Fixture.on(60, 100), Fixture.control(10, 100), Fixture.off(60, 40)]
        let plainSent = try Fixture.play(events, on: &plainLedger, routing: plain)
        let identitySent = try Fixture.play(events, on: &identityLedger, routing: identity)
        #expect(plainSent == identitySent)
    }

    @Test
    func shapedLeavesMessagesWithoutAMatchingCurveUnchanged() throws {
        let rule = try Self.rule(Fixture.piano, transform: Self.fixed(77))
        let plain = try Fixture.rule(Fixture.piano)
        let samples: [MIDI1Semantic] = [
            .noteOff(channel: 1, note: 60, velocity: 100), .noteOn(channel: 1, note: 60, velocity: 0),
            .noteOn(channel: 1, note: 60, velocity: 200), .programChange(channel: 1, program: 5),
            .pitchBend(channel: 1, value: 9000), .controlChange(channel: 1, controller: 10, value: 100)
        ]
        let reshaped = samples.map(rule.shaped)
        let unchanged = samples.map(plain.shaped)
        #expect(reshaped == samples)
        #expect(unchanged == samples)
        let curved = rule.shaped(.noteOn(channel: 3, note: 61, velocity: 100))
        #expect(curved == .noteOn(channel: 3, note: 61, velocity: 77))
    }

    @Test
    func sharesTargetIgnoresOnlyTheDataByteOfANoteOnOrControlChange() {
        let noteA = MIDIRoutedOutput(route: Fixture.piano, message: .noteOn(channel: 1, note: 60, velocity: 10))
        let noteB = MIDIRoutedOutput(route: Fixture.piano, message: .noteOn(channel: 1, note: 60, velocity: 99))
        let otherNote = MIDIRoutedOutput(route: Fixture.piano, message: .noteOn(channel: 1, note: 61, velocity: 10))
        let otherChannel = MIDIRoutedOutput(route: Fixture.piano, message: .noteOn(channel: 2, note: 60, velocity: 10))
        let otherRoute = MIDIRoutedOutput(route: Fixture.strings, message: .noteOn(channel: 1, note: 60, velocity: 10))
        let ccA = Fixture.sentControl(Fixture.piano, 10, 1)
        let ccB = Fixture.sentControl(Fixture.piano, 10, 2)
        let otherController = Fixture.sentControl(Fixture.piano, 11, 1)
        let offA = Fixture.sentOff(Fixture.piano, 60, 1)
        let offB = Fixture.sentOff(Fixture.piano, 60, 2)
        let sameNote = noteA.sharesTarget(noteB)
        let sameController = ccA.sharesTarget(ccB)
        let sameOff = offA.sharesTarget(offA)
        let noteVersusController = noteA.sharesTarget(ccA)
        let noteVersusOff = Fixture.sentOn(Fixture.piano, 60, 0).sharesTarget(Fixture.sentOff(Fixture.piano, 60, 0))
        #expect(sameNote)
        #expect(sameController)
        #expect(sameOff)
        #expect(!noteVersusOff)
        #expect(!noteA.sharesTarget(otherNote))
        #expect(!noteA.sharesTarget(otherChannel))
        #expect(!noteA.sharesTarget(otherRoute))
        #expect(!ccA.sharesTarget(otherController))
        #expect(!offA.sharesTarget(offB))
        #expect(!noteVersusController)
    }

    @Test
    func sharesTargetKeepsTheDataByteOfPolyPressureChannelPressureProgramAndPitchBend() {
        let route = Fixture.piano
        let poly1 = MIDIRoutedOutput(route: route, message: .polyphonicPressure(channel: 1, note: 60, pressure: 1))
        let poly2 = MIDIRoutedOutput(route: route, message: .polyphonicPressure(channel: 1, note: 60, pressure: 2))
        let channel1 = MIDIRoutedOutput(route: route, message: .channelPressure(channel: 1, pressure: 1))
        let channel2 = MIDIRoutedOutput(route: route, message: .channelPressure(channel: 1, pressure: 2))
        let program1 = MIDIRoutedOutput(route: route, message: .programChange(channel: 1, program: 1))
        let program2 = MIDIRoutedOutput(route: route, message: .programChange(channel: 1, program: 2))
        let bend1 = MIDIRoutedOutput(route: route, message: .pitchBend(channel: 1, value: 1))
        let bend2 = MIDIRoutedOutput(route: route, message: .pitchBend(channel: 1, value: 2))
        let samePoly = poly1.sharesTarget(poly1)
        let sameBend = bend1.sharesTarget(bend1)
        #expect(samePoly)
        #expect(sameBend)
        #expect(!poly1.sharesTarget(poly2))
        #expect(!channel1.sharesTarget(channel2))
        #expect(!program1.sharesTarget(program2))
        #expect(!bend1.sharesTarget(bend2))
    }

    @Test
    func fixedVelocityCurveReshapesTheLowestAndHighestVelocities() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(Self.rule(Fixture.piano, transform: Self.fixed(77)))
        let lowest = try ledger.route(Fixture.on(60, 1), routing: routing)
        let highest = try ledger.route(Fixture.on(61, 127), routing: routing)
        #expect(lowest == [Fixture.sentOn(Fixture.piano, 60, 77)])
        #expect(highest == [Fixture.sentOn(Fixture.piano, 61, 77)])
    }
}
