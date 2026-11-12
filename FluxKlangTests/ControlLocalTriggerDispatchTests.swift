import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct Seen: Equatable {
    let binding: String
    let action: ControlTriggerAction
    let sequence: UInt64
}

// swiftlint:disable:next type_name
private enum Fx {
    static let padA = "midi.ltd-pad.1.cc.80"
    static let padB = "midi.ltd-pad.1.cc.81"
    static let padCh2 = "midi.ltd-pad.2.cc.80"
    static let padMSB = "midi.ltd-pad.1.cc.1"
    static let fireID = ControlTriggerTargetID(validated: "trg.ltd.fire")
    static let hazardID = ControlTriggerTargetID(validated: "trg.ltd.hazard")

    static let press = cc(80, 127)
    static let lift = cc(80, 0)
    static let note = MIDI1StateUpdate(channel: 1, effect: .noteOn(note: 60, velocity: 100))

    static func cc(_ number: UInt8, _ value: UInt8) -> MIDI1StateUpdate {
        MIDI1StateUpdate(channel: 1, effect: .controller(number, value: value))
    }

    static func id(_ text: String) throws -> BindingID { try BindingID(text) }

    static func binding(_ id: String, source: String = padA, mode: ControlTriggerMode = .momentary,
                        emitsRelease: Bool? = nil, target: ControlTriggerTargetID = fireID) throws
        -> ControlTriggerBinding {
        try ControlTriggerBinding(ControlTriggerBindingFields(
            id: BindingID(id), source: ControlSourceID(source), target: target, profile: .absolute(resolution: 128),
            mode: mode, pressAt: 0.5, releaseAt: 0.25, emitsRelease: emitsRelease
        ))
    }

    /// A binding whose profile reads 14 bits: the 7-bit controller update does not fit it.
    static func wide(_ id: String) throws -> ControlTriggerBinding {
        try ControlTriggerBinding(ControlTriggerBindingFields(
            id: BindingID(id), source: ControlSourceID(padA), target: fireID, profile: .absolute(resolution: 16_384),
            mode: .momentary, pressAt: 0.5, releaseAt: 0.25
        ))
    }

    static func truth(sources: [String] = [padA, padB, padCh2, padMSB]) throws -> ControlTriggerHostTruth {
        var current = Set<ControlSourceID>()
        for source in sources { current.insert(try ControlSourceID(source)) }
        return try ControlTriggerHostTruth(sources: current, targets: [fireID: .live, hazardID: .hazardous])
    }

    static func input(_ update: MIDI1StateUpdate,
                      dialect: ControlIntakeDialect = .pairedFourteenBit) throws -> ControlLocalInput {
        try ControlLocalInput(update: update, origin: ControlSourceOrigin("ltd-pad"), dialect: dialect)
    }

    static func run(_ detector: inout ControlTriggerDetector, _ bindings: [ControlTriggerBinding],
                    _ update: MIDI1StateUpdate = press, learn: LearnPhaseKind = .idle,
                    truth: ControlTriggerHostTruth? = nil) throws -> ControlLocalTriggerResult {
        let host = try truth ?? Fx.truth()
        return try ControlLocalTriggerDispatch.dispatch(
            input: input(update), learn: learn, bindings: bindings, detector: &detector, truth: host
        )
    }

    static func held(_ detector: ControlTriggerDetector, _ text: String) throws -> Bool? {
        detector.state(of: try id(text))?.held
    }

    static func seen(_ commands: [ControlTriggerCommand]) -> [Seen] {
        commands.map { Seen(binding: $0.binding.rawValue, action: $0.action, sequence: $0.sequence) }
    }

    static func names(_ list: [BindingID]) -> [String] { list.map { $0.rawValue } }

    /// `count` momentary bindings `bnd.n0000`, `bnd.n0001`, ... on `padA`, ascending by id.
    static func bulk(_ count: Int) throws -> [ControlTriggerBinding] {
        try (0..<count).map { index in
            let digits = String(index)
            return try binding("bnd.n" + String(repeating: "0", count: 4 - digits.count) + digits)
        }
    }
}

/// Local trigger dispatch (#87, LTD1): one MIDI1 state update becomes the commands of `ControlTriggerDetector.handle`.
/// Every fixture lives in the file-scope private `Fx`, so no name leaves this file.
#if os(macOS)
@Suite("Local trigger dispatch", .productionAccessAudit)
#else
@Suite("Local trigger dispatch")
#endif
struct ControlLocalTriggerDispatchTests {
    @Test
    func controlLocalTriggerDispatchGoldenPressFiresOneCommandForTheHeardBinding() throws {
        let bindings = try [Fx.binding("bnd.a")]
        var detector = try ControlTriggerDetector(bindings: bindings)
        let result = try Fx.run(&detector, bindings)
        let command = try #require(result.commands.first)
        #expect(result.commands.count == 1)
        #expect(command.binding.rawValue == "bnd.a")
        #expect(command.target.rawValue == "trg.ltd.fire")
        #expect(command.source.rawValue == "midi.ltd-pad.1.cc.80")
        #expect(command.action == .press)
        #expect(command.cause == .input)
        #expect(command.sequence == 1)
        #expect(result.silent.isEmpty)
        #expect(result.refusals.isEmpty)
        let held = try Fx.held(detector, "bnd.a")
        #expect(held == true)
        #expect(detector.lastSequence == 1)
    }

    @Test
    func controlLocalTriggerDispatchRepeatedHighValuesAreSilentUntilTheValueFalls() throws {
        let emitting = try [Fx.binding("bnd.a", emitsRelease: true)]
        var detector = try ControlTriggerDetector(bindings: emitting)
        _ = try Fx.run(&detector, emitting)
        let repeated = try Fx.run(&detector, emitting)
        #expect(repeated.commands.isEmpty)
        #expect(Fx.names(repeated.silent) == ["bnd.a"])
        #expect(repeated.refusals.isEmpty)
        #expect(detector.lastSequence == 1)
        let released = try Fx.run(&detector, emitting, Fx.lift)
        #expect(Fx.seen(released.commands) == [Seen(binding: "bnd.a", action: .release, sequence: 2)])
        #expect(released.silent.isEmpty)
        let heldAfterRelease = try Fx.held(detector, "bnd.a")
        #expect(heldAfterRelease == false)

        let plain = try [Fx.binding("bnd.a")]
        var quiet = try ControlTriggerDetector(bindings: plain)
        _ = try Fx.run(&quiet, plain)
        let lifted = try Fx.run(&quiet, plain, Fx.lift)
        #expect(lifted.commands.isEmpty)
        #expect(Fx.names(lifted.silent) == ["bnd.a"])
        let heldAfterLift = try Fx.held(quiet, "bnd.a")
        #expect(heldAfterLift == false)
        #expect(quiet.lastSequence == 1)

        var fresh = try ControlTriggerDetector(bindings: plain)
        let unpressed = try Fx.run(&fresh, plain, Fx.lift)
        #expect(unpressed.commands.isEmpty)
        #expect(Fx.names(unpressed.silent) == ["bnd.a"])
        #expect(fresh.lastSequence == 0)
    }

    @Test
    func controlLocalTriggerDispatchBindingsOnTheSameSourceIdHearTheUpdate() throws {
        let bindings = try [
            Fx.binding("bnd.a"), Fx.binding("bnd.b", source: Fx.padB), Fx.binding("bnd.c", source: Fx.padCh2)
        ]
        var detector = try ControlTriggerDetector(bindings: bindings)
        let result = try Fx.run(&detector, bindings)
        #expect(Fx.seen(result.commands) == [Seen(binding: "bnd.a", action: .press, sequence: 1)])
        #expect(result.silent.isEmpty)
        #expect(result.refusals.isEmpty)
        let heldB = try Fx.held(detector, "bnd.b")
        let heldC = try Fx.held(detector, "bnd.c")
        #expect(heldB == false)
        #expect(heldC == false)

        let bystanders = Array(bindings.dropFirst())
        var bystander = try ControlTriggerDetector(bindings: bystanders)
        let before = bystander
        let quiet = try Fx.run(&bystander, bystanders)
        #expect(quiet.commands.isEmpty)
        #expect(quiet.silent.isEmpty)
        #expect(quiet.refusals.isEmpty)
        #expect(bystander == before)
    }

    @Test
    func controlLocalTriggerDispatchCommandsAscendByBindingIdBytesWhateverTheInputOrder() throws {
        let scrambled = try ["bnd.c", "bnd.a", "bnd.b"].map { try Fx.binding($0) }
        let reversed = try ["bnd.b", "bnd.a", "bnd.c"].map { try Fx.binding($0) }
        var first = try ControlTriggerDetector(bindings: scrambled)
        var second = try ControlTriggerDetector(bindings: reversed)
        let one = try Fx.run(&first, scrambled)
        let two = try Fx.run(&second, reversed)
        let expected = [
            Seen(binding: "bnd.a", action: .press, sequence: 1),
            Seen(binding: "bnd.b", action: .press, sequence: 2),
            Seen(binding: "bnd.c", action: .press, sequence: 3)
        ]
        #expect(Fx.seen(one.commands) == expected)
        #expect(one == two)
        #expect(first == second)

        let mixedCase = try ["bnd.B", "bnd.a", "bnd.A"].map { try Fx.binding($0) }
        var third = try ControlTriggerDetector(bindings: mixedCase)
        let bytes = try Fx.run(&third, mixedCase)
        let byteOrder = [
            Seen(binding: "bnd.A", action: .press, sequence: 1),
            Seen(binding: "bnd.B", action: .press, sequence: 2),
            Seen(binding: "bnd.a", action: .press, sequence: 3)
        ]
        #expect(Fx.seen(bytes.commands) == byteOrder)
    }

    @Test
    func controlLocalTriggerDispatchLearnListeningAndAwaitingReviewRefuseTheWholeCall() throws {
        let bindings = try [Fx.binding("bnd.a")]
        for kind in [LearnPhaseKind.listening, .awaitingReview] {
            var detector = try ControlTriggerDetector(bindings: bindings)
            let before = detector
            let result = try Fx.run(&detector, bindings, learn: kind)
            #expect(result.refusals == [.learnActive(kind)])
            #expect(result.commands.isEmpty)
            #expect(result.silent.isEmpty)
            #expect(detector == before)
            #expect(detector.lastSequence == 0)
        }
        for kind in [LearnPhaseKind.idle, .committed, .cancelled, .blocked] {
            var detector = try ControlTriggerDetector(bindings: bindings)
            let result = try Fx.run(&detector, bindings, learn: kind)
            #expect(Fx.seen(result.commands) == [Seen(binding: "bnd.a", action: .press, sequence: 1)])
            #expect(result.refusals.isEmpty)
        }
    }

    @Test
    func controlLocalTriggerDispatchRefusesWhatTheIntakeRefusesAndLeavesTheDetectorEqual() throws {
        let bindings = try [Fx.binding("bnd.a")]
        var detector = try ControlTriggerDetector(bindings: bindings)
        let before = detector
        let notControl: [MIDI1StateUpdate] = [
            Fx.note,
            MIDI1StateUpdate(channel: 1, effect: .noteOff(note: 60, sustained: false)),
            MIDI1StateUpdate(channel: 1, effect: .sustain(down: true, released: [])),
            MIDI1StateUpdate(channel: 1, effect: .program(MIDI1ProgramSelection(bankMSB: 0, bankLSB: 0, program: 5))),
            MIDI1StateUpdate(channel: 1, effect: .unchanged)
        ]
        for update in notControl {
            let result = try Fx.run(&detector, bindings, update)
            #expect(result.refusals == [.intake(.notControlInput)])
            #expect(result.commands.isEmpty)
            #expect(result.silent.isEmpty)
        }
        let system = MIDI1StateUpdate(channel: nil, effect: .controller(80, value: 127))
        let unaddressed = try Fx.run(&detector, bindings, system)
        #expect(unaddressed.refusals == [.intake(.noChannel)])
        #expect(unaddressed.commands.isEmpty)
        #expect(detector == before)
        let accepted = try Fx.run(&detector, bindings)
        #expect(Fx.seen(accepted.commands) == [Seen(binding: "bnd.a", action: .press, sequence: 1)])
    }

    @Test
    func controlLocalTriggerDispatchProfileAndDialectRefusalsAreListedPerBinding() throws {
        let bindings = try [Fx.wide("bnd.a"), Fx.binding("bnd.z")]
        var detector = try ControlTriggerDetector(bindings: bindings)
        let result = try Fx.run(&detector, bindings)
        let refusal = ControlLocalTriggerRefusal.bindingIntake(
            try Fx.id("bnd.a"), .widthMismatch(messageBits: 7, profileBits: 14)
        )
        #expect(result.refusals == [refusal])
        #expect(Fx.seen(result.commands) == [Seen(binding: "bnd.z", action: .press, sequence: 1)])
        #expect(result.silent.isEmpty)
        let heldA = try Fx.held(detector, "bnd.a")
        #expect(heldA == false)

        let msb = try [Fx.binding("bnd.a", source: Fx.padMSB)]
        let paired = MIDI1StateUpdate(channel: 1, effect: .controller14(1, value: 16_256))
        let host = try Fx.truth()
        var seven = try ControlTriggerDetector(bindings: msb)
        let sevenBit = try ControlLocalTriggerDispatch.dispatch(
            input: Fx.input(paired, dialect: .msbOnlySevenBit), learn: .idle, bindings: msb, detector: &seven,
            truth: host
        )
        #expect(Fx.seen(sevenBit.commands) == [Seen(binding: "bnd.a", action: .press, sequence: 1)])
        var fourteen = try ControlTriggerDetector(bindings: msb)
        let fourteenBit = try ControlLocalTriggerDispatch.dispatch(
            input: Fx.input(paired), learn: .idle, bindings: msb, detector: &fourteen, truth: host
        )
        #expect(fourteenBit.commands.isEmpty)
        #expect(fourteenBit.silent.isEmpty)
        #expect(fourteenBit.refusals.isEmpty)
        let lsb = MIDI1StateUpdate(channel: 1, effect: .controller14(1, value: 16_257))
        var partial = try ControlTriggerDetector(bindings: msb)
        let lsbResult = try ControlLocalTriggerDispatch.dispatch(
            input: Fx.input(lsb, dialect: .msbOnlySevenBit), learn: .idle, bindings: msb, detector: &partial,
            truth: host
        )
        #expect(lsbResult.refusals == [.intake(.lsbPresent(raw: 1))])
    }

    @Test
    func controlLocalTriggerDispatchDetectorRefusalsAreListedPerBindingAndSiblingsStillFire() throws {
        let padID = try ControlSourceID(Fx.padA)
        let otherID = try ControlSourceID(Fx.padB)
        let idA = try Fx.id("bnd.a")
        let fires = Seen(binding: "bnd.z", action: .press, sequence: 1)

        let pair = try [Fx.binding("bnd.a"), Fx.binding("bnd.z")]
        var stale = try ControlTriggerDetector(bindings: pair)
        let before = stale
        let staleResult = try Fx.run(&stale, pair, truth: Fx.truth(sources: []))
        let idZ = try Fx.id("bnd.z")
        let bothStale: [ControlLocalTriggerRefusal] = [
            .detector(idA, .controllerStale(padID)), .detector(idZ, .controllerStale(padID))
        ]
        #expect(staleResult.refusals == bothStale)
        #expect(staleResult.commands.isEmpty)
        #expect(stale == before)

        let hazardous = try [Fx.binding("bnd.a", target: Fx.hazardID), Fx.binding("bnd.z")]
        var classed = try ControlTriggerDetector(bindings: hazardous)
        let classedResult = try Fx.run(&classed, hazardous)
        #expect(classedResult.refusals == [.detector(idA, .targetClass(Fx.hazardID, .hazardous))])
        #expect(Fx.seen(classedResult.commands) == [fires])
        let heldHazard = try Fx.held(classed, "bnd.a")
        #expect(heldHazard == false)

        let known = try [Fx.binding("bnd.z")]
        var unknown = try ControlTriggerDetector(bindings: known)
        let unknownResult = try Fx.run(&unknown, pair)
        #expect(unknownResult.refusals == [.detector(idA, .unknownBinding(idA))])
        #expect(Fx.seen(unknownResult.commands) == [fires])

        let moved = try [Fx.binding("bnd.a", source: Fx.padB), Fx.binding("bnd.z")]
        var mismatch = try ControlTriggerDetector(bindings: moved)
        let mismatchResult = try Fx.run(&mismatch, pair)
        #expect(mismatchResult.refusals == [.detector(idA, .sourceMismatch(expected: otherID, found: padID))])
        #expect(Fx.seen(mismatchResult.commands) == [fires])
        let heldMoved = try Fx.held(mismatch, "bnd.a")
        #expect(heldMoved == false)
    }

    @Test
    func controlLocalTriggerDispatchToggleAndLatchFollowTheDetectorPressEdges() throws {
        let toggles = try [Fx.binding("bnd.t", mode: .toggle)]
        var toggle = try ControlTriggerDetector(bindings: toggles)
        let pressed = try Fx.run(&toggle, toggles)
        #expect(Fx.seen(pressed.commands) == [Seen(binding: "bnd.t", action: .switchedOn, sequence: 1)])
        let lifted = try Fx.run(&toggle, toggles, Fx.lift)
        #expect(lifted.commands.isEmpty)
        #expect(Fx.names(lifted.silent) == ["bnd.t"])
        let off = try Fx.run(&toggle, toggles)
        #expect(Fx.seen(off.commands) == [Seen(binding: "bnd.t", action: .switchedOff, sequence: 2)])

        let latches = try [Fx.binding("bnd.l", source: Fx.padB, mode: .latch)]
        var latch = try ControlTriggerDetector(bindings: latches)
        let first = try Fx.run(&latch, latches, Fx.cc(81, 127))
        #expect(Fx.seen(first.commands) == [Seen(binding: "bnd.l", action: .switchedOn, sequence: 1)])
        _ = try Fx.run(&latch, latches, Fx.cc(81, 0))
        let second = try Fx.run(&latch, latches, Fx.cc(81, 127))
        #expect(second.commands.isEmpty)
        #expect(Fx.names(second.silent) == ["bnd.l"])
        #expect(latch.lastSequence == 1)
    }

    @Test
    func controlLocalTriggerDispatchAcceptsTheBindingCapAndRefusesOneMore() throws {
        let cap = ControlBindingLimit.maximumBindings
        for count in [cap - 1, cap] {
            let bindings = try Fx.bulk(count)
            var detector = try ControlTriggerDetector(bindings: bindings)
            let result = try Fx.run(&detector, Array(bindings.reversed()))
            #expect(result.commands.map { $0.binding.rawValue } == bindings.map { $0.id.rawValue })
            #expect(result.commands.map { $0.sequence } == Array(1...UInt64(count)))
            #expect(result.silent.isEmpty)
            #expect(result.refusals.isEmpty)
        }
        let over = cap + 1
        let crowded = try Fx.bulk(over)
        var detector = try ControlTriggerDetector(bindings: Array(crowded.dropLast()))
        let before = detector
        let refused = try Fx.run(&detector, crowded)
        #expect(refused.refusals == [.tooManyBindings(over)])
        #expect(refused.commands.isEmpty)
        #expect(refused.silent.isEmpty)
        #expect(detector == before)
        #expect(detector.lastSequence == 0)
    }

    @Test
    func controlLocalTriggerDispatchRepeatedBindingIdsAreRefusedAndTheSmallestIsNamed() throws {
        let unique = try [Fx.binding("bnd.x"), Fx.binding("bnd.m"), Fx.binding("bnd.b"), Fx.binding("bnd.y")]
        var detector = try ControlTriggerDetector(bindings: unique)
        let before = detector
        let twice = try [Fx.binding("bnd.x"), Fx.binding("bnd.x")]
        let single = try Fx.run(&detector, twice)
        #expect(single.refusals == [.duplicateBinding(try Fx.id("bnd.x"))])
        #expect(single.commands.isEmpty)
        #expect(single.silent.isEmpty)
        #expect(detector == before)

        let tangled = try ["bnd.m", "bnd.b", "bnd.m", "bnd.b"].map { try Fx.binding($0) }
        let smallest = try Fx.run(&detector, tangled)
        #expect(smallest.refusals == [.duplicateBinding(try Fx.id("bnd.b"))])
        #expect(smallest.commands.isEmpty)
        #expect(detector == before)

        // Here the smallest repeated id is found first and a larger one last.
        let reversed = try ["bnd.b", "bnd.m", "bnd.b", "bnd.m"].map { try Fx.binding($0) }
        let firstSmallest = try Fx.run(&detector, reversed)
        #expect(firstSmallest.refusals == [.duplicateBinding(try Fx.id("bnd.b"))])
        #expect(detector == before)

        let elsewhere = try [Fx.binding("bnd.y", source: Fx.padB), Fx.binding("bnd.y", source: Fx.padB)]
        let unheard = try Fx.run(&detector, elsewhere)
        #expect(unheard.refusals == [.duplicateBinding(try Fx.id("bnd.y"))])
        #expect(detector == before)
    }

    @Test
    func controlLocalTriggerDispatchRefusalsAreCheckedInTheOrderLearnIntakeCapDuplicates() throws {
        let cap = ControlBindingLimit.maximumBindings
        let bindings = try [Fx.binding("bnd.a")]
        var detector = try ControlTriggerDetector(bindings: bindings)
        let before = detector
        let learning = try Fx.run(&detector, bindings, Fx.note, learn: .listening)
        #expect(learning.refusals == [.learnActive(.listening)])

        let crowded = try Fx.bulk(cap + 1)
        let intake = try Fx.run(&detector, crowded, Fx.note)
        #expect(intake.refusals == [.intake(.notControlInput)])

        var repeated = crowded
        let head = try #require(repeated.first)
        repeated.removeLast()
        repeated.append(head)
        let counted = try Fx.run(&detector, repeated)
        #expect(counted.refusals == [.tooManyBindings(cap + 1)])
        #expect(detector == before)

        let valid = try Fx.run(&detector, bindings)
        #expect(Fx.seen(valid.commands) == [Seen(binding: "bnd.a", action: .press, sequence: 1)])
    }

    @Test
    func controlLocalTriggerDispatchSequencesContinueAcrossCallsAndStopAtExhaustion() throws {
        let bindings = try [Fx.binding("bnd.a"), Fx.binding("bnd.b"), Fx.binding("bnd.c", source: Fx.padB)]
        var detector = try ControlTriggerDetector(bindings: bindings)
        let first = try Fx.run(&detector, bindings)
        #expect(first.commands.map { $0.sequence } == [1, 2])
        _ = try Fx.run(&detector, bindings, Fx.press, learn: .listening)
        let second = try Fx.run(&detector, bindings, Fx.cc(81, 127))
        #expect(Fx.seen(second.commands) == [Seen(binding: "bnd.c", action: .press, sequence: 3)])
        #expect(detector.lastSequence == 3)

        var resumed = try ControlTriggerDetector(bindings: bindings, after: 10)
        let eleventh = try Fx.run(&resumed, bindings)
        #expect(eleventh.commands.map { $0.sequence } == [11, 12])

        let pair = try [Fx.binding("bnd.a"), Fx.binding("bnd.b")]
        var nearEnd = try ControlTriggerDetector(bindings: pair, after: UInt64.max - 1)
        let exhausted = try Fx.run(&nearEnd, pair)
        let top = Seen(binding: "bnd.a", action: .press, sequence: 18_446_744_073_709_551_615)
        #expect(Fx.seen(exhausted.commands) == [top])
        #expect(exhausted.refusals == [.detector(try Fx.id("bnd.b"), .sequenceExhausted)])
        #expect(nearEnd.lastSequence == UInt64.max)
    }

    @Test
    func controlLocalTriggerDispatchEqualInputsGiveEqualResultsInAscendingOrder() throws {
        let names = [
            "bnd.k", "bnd.c", "bnd.h", "bnd.a", "bnd.j", "bnd.e", "bnd.i", "bnd.b", "bnd.g", "bnd.d", "bnd.f"
        ]
        let ascending = [
            "bnd.a", "bnd.b", "bnd.c", "bnd.d", "bnd.e", "bnd.f", "bnd.g", "bnd.h", "bnd.i", "bnd.j", "bnd.k"
        ]
        let scrambled = try names.map { try Fx.binding($0) }
        var left = try ControlTriggerDetector(bindings: scrambled)
        var right = try ControlTriggerDetector(bindings: scrambled)
        let one = try Fx.run(&left, scrambled)
        let two = try Fx.run(&right, Array(scrambled.reversed()))
        #expect(one == two)
        #expect(left == right)
        #expect(one.commands.map { $0.binding.rawValue } == ascending)
        #expect(one.commands.map { $0.sequence } == Array(1...11))
    }

    @Test
    func controlLocalTriggerDispatchTheRoutingProfileDecidesAndTheDetectorProfileIsNotCompared() throws {
        let narrow = try [Fx.binding("bnd.a")]
        var detector = try ControlTriggerDetector(bindings: [Fx.wide("bnd.a")])
        let result = try Fx.run(&detector, narrow)
        #expect(Fx.seen(result.commands) == [Seen(binding: "bnd.a", action: .press, sequence: 1)])
        #expect(result.refusals.isEmpty)

        var other = try ControlTriggerDetector(bindings: narrow)
        let before = other
        let wide = try Fx.run(&other, [Fx.wide("bnd.a")])
        #expect(wide.refusals == [.bindingIntake(try Fx.id("bnd.a"), .widthMismatch(messageBits: 7, profileBits: 14))])
        #expect(other == before)
    }
}
