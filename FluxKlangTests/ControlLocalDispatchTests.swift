import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Local control dispatch (#88, LCD1): `admit` decides which bindings hear one local MIDI control message. This file
/// holds the fixtures and the admission tests; `+Composition` holds `settle` and the composition with the feedback
/// echo check. Every fixture is nested in `Fx`, so no name leaves the suite.
@Suite("Control local dispatch")
struct ControlLocalDispatchTests {
    // swiftlint:disable:next type_name
    enum Fx {
        static let level = ParameterID(validated: "par.ld.level")
        static let other = ParameterID(validated: "par.ld.other")
        static let pad70 = ControlSourceID(validated: "midi.ld-pad.1.cc.70")
        static let pad7 = ControlSourceID(validated: "midi.ld-pad.1.cc.7")
        static let pad700 = ControlSourceID(validated: "midi.ld-pad.1.cc.700")
        static let pair7 = ControlSourceID(validated: "midi.ld-pad.1.cc14.7")
        static let pad71 = ControlSourceID(validated: "midi.ld-pad.1.cc.71")
        static let aJump = BindingID(validated: "bnd.a-jump")
        static let bCatch = BindingID(validated: "bnd.b-catch")
        static let cOther = BindingID(validated: "bnd.c-other")
        static let dRel = BindingID(validated: "bnd.d-rel")
        static let wide = EncoderProfile.twosComplement(width: .fourteen)

        static func descriptor(_ id: ParameterID) throws -> ParameterDescriptor {
            try ParameterDescriptor(.init(
                id: id, unit: .percent, lower: 0, upper: 100, defaultValue: 0, ceiling: nil, curve: .linear,
                ramp: .step, controlClass: .live, verification: .unverified
            ))
        }

        /// Host truth with the percent parameter `level` at `host` (no value when `nil`).
        static func truth(host: Double? = 50) throws -> ControlHostTruth {
            let catalog = try ParameterCatalog([descriptor(level)])
            let values = host.map { [level: ParameterValue(value: $0, unit: .percent)] } ?? [:]
            return try ControlHostTruth(catalog: catalog, values: values)
        }

        /// Host truth whose catalog does not know `level`.
        static func truthWithoutLevel() throws -> ControlHostTruth {
            let catalog = try ParameterCatalog([descriptor(other)])
            return try ControlHostTruth(
                catalog: catalog, values: [other: ParameterValue(value: 10, unit: .percent)]
            )
        }

        static func binding(_ id: BindingID, source: ControlSourceID = pad70,
                            profile: EncoderProfile = .absolute(resolution: 128),
                            pickup: PickupMode = .jump, upper: Double? = nil) throws -> ControlBinding {
            try ControlBinding(.init(
                id: id, source: source, target: level, unit: .percent, profile: profile, upper: upper, pickup: pickup
            ))
        }

        static func relative(_ id: BindingID, source: ControlSourceID = pad70,
                             profile: EncoderProfile = wide) throws -> ControlBinding {
            try ControlBinding(.init(
                id: id, source: source, target: level, unit: .percent, profile: profile, step: 1
            ))
        }

        /// Three bindings on controller 70 (a jump, a catch and a 14-bit relative one) and one on controller 71.
        static func standardBindings() throws -> [ControlBinding] {
            try [
                binding(aJump), binding(bCatch, pickup: .catch), binding(cOther, source: pad71),
                relative(dRel)
            ]
        }

        /// Every binding in its own initial state, as a caller that has never dispatched holds them.
        static func fresh(_ bindings: [ControlBinding]) -> [BindingID: PickupState] {
            var table: [BindingID: PickupState] = [:]
            for binding in bindings { table[binding.id] = binding.initialPickupState }
            return table
        }

        static func controller(_ number: UInt8 = 70, _ value: UInt8 = 127) -> MIDI1StateUpdate {
            MIDI1StateUpdate(channel: 1, effect: .controller(number, value: value))
        }

        static var noteOn: MIDI1StateUpdate {
            MIDI1StateUpdate(channel: 1, effect: .noteOn(note: 60, velocity: 100))
        }

        static func input(_ update: MIDI1StateUpdate = controller()) throws -> ControlLocalInput {
            try ControlLocalInput(update: update, origin: ControlSourceOrigin("ld-pad"))
        }

        static func admit(_ bindings: [ControlBinding], learn: LearnPhaseKind = .idle,
                          update: MIDI1StateUpdate = controller(),
                          pickup: [BindingID: PickupState]? = nil) throws -> ControlLocalAdmission {
            try ControlLocalDispatch.admit(
                input: input(update), learn: learn, bindings: bindings, pickup: pickup ?? fresh(bindings)
            )
        }

        static func ids(_ admission: ControlLocalAdmission) -> [BindingID] {
            admission.candidates.map { $0.binding.id }
        }

        /// `count` absolute bindings `bnd.n<index>` on `source`.
        static func bulk(_ count: Int, source: ControlSourceID = pad70) throws -> [ControlBinding] {
            try (0..<count).map { index in
                try binding(BindingID("bnd.n\(index)"), source: source)
            }
        }
    }

    // MARK: Goldens

    @Test func admitHearsMatchingSourcesDecodesPerProfileAndRefusesTheWidthMismatch() throws {
        let admission = try Fx.admit(Fx.standardBindings())
        #expect(Fx.ids(admission) == [Fx.aJump, Fx.bCatch])
        let first = try #require(admission.candidates.first)
        #expect(first.input == .absolute(normalized: 1))
        #expect(first.state == .engaged(hardware: nil))
        let second = try #require(admission.candidates.last)
        #expect(second.input == .absolute(normalized: 1))
        #expect(second.state == .waiting(hardware: nil))
        let mismatch = ControlIntakeRefusal.widthMismatch(messageBits: 7, profileBits: 14)
        #expect(admission.refusals == [.bindingIntake(Fx.dRel, mismatch)])
    }

    @Test func admitOrdersCandidatesByUTF8BytesWhateverTheSuppliedOrder() throws {
        let names = ["bnd.b", "bnd.B", "bnd.a", "bnd.a.1"]
        let bindings = try names.map { try Fx.binding(BindingID($0)) }
        let expected = try ["bnd.B", "bnd.a", "bnd.a.1", "bnd.b"].map { try BindingID($0) }
        let forward = try Fx.admit(bindings)
        let backward = try Fx.admit(Array(bindings.reversed()))
        #expect(Fx.ids(forward) == expected)
        #expect(backward == forward)
    }

    @Test func admitSortsAHundredAndTwentyEightByteIdNextToAOneByteId() throws {
        let long = try BindingID("bnd." + String(repeating: "a", count: 124))
        let short = try BindingID("b")
        let low = try BindingID("bnd.z")
        let admission = try Fx.admit([Fx.binding(long), Fx.binding(short), Fx.binding(low)])
        #expect(Fx.ids(admission) == [short, long, low])
    }

    // MARK: Learn

    @Test(arguments: [LearnPhaseKind.idle, .committed, .cancelled, .blocked])
    func admitHearsWhenLearnIsNotActive(kind: LearnPhaseKind) throws {
        let admission = try Fx.admit(Fx.standardBindings(), learn: kind)
        #expect(Fx.ids(admission) == [Fx.aJump, Fx.bCatch])
    }

    @Test(arguments: [LearnPhaseKind.listening, .awaitingReview])
    func admitRefusesTheWholeCallWhenLearnIsActive(kind: LearnPhaseKind) throws {
        let admission = try Fx.admit(Fx.standardBindings(), learn: kind)
        #expect(admission.refusals == [.learnActive(kind)])
        #expect(admission.candidates.isEmpty)
    }

    // MARK: Call level

    @Test func admitRefusesANoteOnWithTheIntakeRefusal() throws {
        let admission = try Fx.admit(Fx.standardBindings(), update: Fx.noteOn)
        #expect(admission.refusals == [.intake(.notControlInput)])
        #expect(admission.candidates.isEmpty)
    }

    @Test func admitRefusesASystemUpdateWithoutAChannel() throws {
        let update = MIDI1StateUpdate(channel: nil, effect: .controller(70, value: 1))
        let admission = try Fx.admit(Fx.standardBindings(), update: update)
        #expect(admission.refusals == [.intake(.noChannel)])
        #expect(admission.candidates.isEmpty)
    }

    @Test func admitRefusesTwoBindingsOfTheSameIdAndNamesTheSmallestRepeat() throws {
        let zebra = try BindingID("bnd.z")
        let middle = try BindingID("bnd.m")
        let bindings = try [Fx.binding(zebra), Fx.binding(middle), Fx.binding(zebra), Fx.binding(middle)]
        let admission = try Fx.admit(bindings)
        #expect(admission.refusals == [.duplicateBinding(middle)])
        #expect(admission.candidates.isEmpty)
    }

    @Test func admitRefusesARepeatedIdOnABindingOfAnotherSource() throws {
        let twin = try BindingID("bnd.twin")
        let bindings = try [Fx.binding(twin), Fx.binding(twin, source: Fx.pad71)]
        let admission = try Fx.admit(bindings)
        #expect(admission.refusals == [.duplicateBinding(twin)])
    }

    @Test func admitAcceptsTheSharedLimitOfMatchingBindingsAndRefusesOneMore() throws {
        let limit = ControlBindingLimit.maximumBindings
        let full = try Fx.bulk(limit)
        let accepted = try Fx.admit(full)
        #expect(accepted.candidates.count == limit)
        #expect(accepted.refusals.isEmpty)
        let over = try Fx.bulk(limit + 1)
        let refused = try Fx.admit(over)
        #expect(refused.refusals == [.tooManyBindings(limit + 1)])
        #expect(refused.candidates.isEmpty)
    }

    @Test func admitCountsBindingsOfOtherSourcesTowardTheCap() throws {
        let limit = ControlBindingLimit.maximumBindings
        let full = try Fx.bulk(limit, source: Fx.pad71)
        let accepted = try Fx.admit(full)
        #expect(accepted.candidates.isEmpty)
        #expect(accepted.refusals.isEmpty)
        let over = try Fx.bulk(limit + 1, source: Fx.pad71)
        let refused = try Fx.admit(over)
        #expect(refused.refusals == [.tooManyBindings(limit + 1)])
    }

    @Test func controlBindingLimitIsOneValueAcrossTheControlTypes() {
        let golden = 4096
        let limit = ControlBindingLimit.maximumBindings
        #expect(limit == golden)
        #expect(ControlLocalDispatch.maximumBindings == limit)
        #expect(ControlLocalTriggerDispatch.maximumBindings == limit)
        #expect(ControlPickupBook.maximumBindings == limit)
        #expect(ControlSourceAvailability.maximumBindings == limit)
        #expect(ControlBindingGroupFields.maximumBindings == limit)
        #expect(ControlTriggerDetector.maximumBindings == limit)
        #expect(LearnConflicts.maximumExistingBindings == limit)
        #expect(ControlHostTruth.maximumValues == limit)
        #expect(ControlPickupBook.maximumChangedTargets == golden)
        let originGolden = 128
        #expect(ControlSourceAvailability.maximumLiveOrigins == originGolden)
    }

    @Test func admitHearsARigAboveTwoHundredFiftySixBindingsThatThePickupBookHolds() throws {
        let rig = try Fx.bulk(257)
        var book = ControlPickupBook()
        for binding in rig { try book.add(binding) }
        #expect(book.count == 257)
        let admission = try Fx.admit(rig, pickup: book.states)
        #expect(admission.candidates.count == 257)
        #expect(admission.refusals.isEmpty)
    }

    @Test func admitWithNoBindingsHearsNothingAndRefusesNothing() throws {
        let admission = try Fx.admit([])
        #expect(admission.candidates.isEmpty)
        #expect(admission.refusals.isEmpty)
    }

    @Test func admitMatchesTheWholeSourceIdAndNotAPrefixOfIt() throws {
        let exact = try Fx.binding(Fx.aJump)
        let longer = try Fx.binding(Fx.bCatch, source: Fx.pad700)
        let both = [exact, longer]
        let onlyExact = [Fx.aJump]
        let admission = try Fx.admit(both, update: Fx.controller(70, 127))
        #expect(admission.refusals.isEmpty)
        #expect(Fx.ids(admission) == onlyExact)
    }

    @Test func admitReadsAControllerPairUnderTheDialectOfTheInput() throws {
        let binding = try Fx.binding(Fx.bCatch, source: Fx.pad7)
        let update = MIDI1StateUpdate(channel: 1, effect: .controller14(7, value: 8192))
        let origin = try ControlSourceOrigin("ld-pad")
        let input = ControlLocalInput(update: update, origin: origin, dialect: .msbOnlySevenBit)
        let admission = ControlLocalDispatch.admit(
            input: input, learn: .idle, bindings: [binding], pickup: Fx.fresh([binding])
        )
        #expect(admission.refusals.isEmpty)
        try #require(admission.candidates.count == 1)
        let heard = try #require(admission.candidates.first)
        let onlyShort = [Fx.bCatch]
        #expect(Fx.ids(admission) == onlyShort)
        let expected = ControlInput.absolute(normalized: 64.0 / 127.0)
        #expect(heard.input == expected)
    }

    // MARK: Order of the call-level checks (each fixture holds both defects)

    @Test func admitReportsLearnBeforeAnUpdateWithNoControlSource() throws {
        let admission = try Fx.admit(Fx.standardBindings(), learn: .listening, update: Fx.noteOn)
        #expect(admission.refusals == [.learnActive(.listening)])
    }

    @Test func admitReportsTheUpdateBeforeTooManyBindings() throws {
        let over = try Fx.bulk(ControlBindingLimit.maximumBindings + 1)
        let admission = try Fx.admit(over, update: Fx.noteOn)
        #expect(admission.refusals == [.intake(.notControlInput)])
    }

    @Test func admitReportsTooManyBindingsBeforeARepeatedId() throws {
        let limit = ControlBindingLimit.maximumBindings
        var bindings = try Fx.bulk(limit)
        bindings.append(try Fx.binding(BindingID("bnd.n0")))
        #expect(bindings.count == limit + 1)
        let admission = try Fx.admit(bindings)
        #expect(admission.refusals == [.tooManyBindings(limit + 1)])
    }

    // MARK: Per binding

    @Test func admitSkipsABindingOfAnotherSourceEvenWhenItHasNoPickupEntry() throws {
        let bindings = try [Fx.binding(Fx.aJump), Fx.binding(Fx.cOther, source: Fx.pad71)]
        let admission = try Fx.admit(bindings, pickup: [Fx.aJump: .engaged(hardware: nil)])
        #expect(Fx.ids(admission) == [Fx.aJump])
        #expect(admission.refusals.isEmpty)
    }

    @Test func admitRefusesAMissingPickupEntryAndStillHearsTheOtherBindings() throws {
        let bindings = try [Fx.binding(Fx.aJump), Fx.binding(Fx.bCatch)]
        let admission = try Fx.admit(bindings, pickup: [Fx.bCatch: .waiting(hardware: nil)])
        #expect(admission.refusals == [.pickupStateMissing(Fx.aJump)])
        #expect(Fx.ids(admission) == [Fx.bCatch])
    }

    @Test func admitReportsAMissingPickupEntryBeforeAWidthMismatch() throws {
        let bindings = try [Fx.relative(Fx.dRel), Fx.binding(Fx.aJump)]
        let admission = try Fx.admit(bindings, pickup: [Fx.aJump: .engaged(hardware: nil)])
        #expect(admission.refusals == [.pickupStateMissing(Fx.dRel)])
        #expect(Fx.ids(admission) == [Fx.aJump])
    }

    @Test func admitRefusesOneBindingForItsWidthAndStillHearsTheBindingsAroundIt() throws {
        let bindings = try [Fx.binding(Fx.aJump), Fx.relative(Fx.bCatch), Fx.binding(Fx.cOther)]
        let admission = try Fx.admit(bindings)
        let mismatch = ControlIntakeRefusal.widthMismatch(messageBits: 7, profileBits: 14)
        #expect(admission.refusals == [.bindingIntake(Fx.bCatch, mismatch)])
        #expect(Fx.ids(admission) == [Fx.aJump, Fx.cOther])
    }

    @Test func admitIgnoresPickupEntriesOfIdsThatAreNotBindings() throws {
        let bindings = try Fx.standardBindings()
        var padded = Fx.fresh(bindings)
        for index in 0..<4096 {
            let stray = try BindingID("bnd.stray\(index)")
            padded[stray] = .unavailable
        }
        let plain = try Fx.admit(bindings)
        let large = try Fx.admit(bindings, pickup: padded)
        #expect(padded.count == 4100)
        #expect(large == plain)
    }
}
