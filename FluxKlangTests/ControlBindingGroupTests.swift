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
struct ControlBindingGroupTests {
    typealias Fixture = ControlBindingTests
    typealias Truth = ControlHostTruthTests
    static let mix = ParameterID(validated: "par.verb.mix")
    static let level = ParameterID(validated: "par.mains.gain")
    static let colour = ParameterID(validated: "par.colour")
    static let width = ParameterID(validated: "par.space.width")
    static let mixID = BindingID(validated: "bnd.g-mix")
    static let levelID = BindingID(validated: "bnd.g-level")
    static let colourID = BindingID(validated: "bnd.g-colour")
    static let widthID = BindingID(validated: "bnd.g-width")
    static let knob = ControlSourceID(validated: "ctl.knob-9")
    static let relative = EncoderProfile.twosComplement(width: .seven)
    static let absolute = EncoderProfile.absolute(resolution: 128)

    @Test
    func memberCountIsBoundedAtBothEnds() throws {
        let ids = try (0...64).map { try BindingID("bnd.m\($0)") }
        let invalid = ControlValidationError.invalid("Binding group needs 1...64 members")
        #expect(throws: invalid) { try Self.group([]) }
        #expect(throws: invalid) { try Self.group(ids) }
        #expect(try Self.group(Array(ids.prefix(1))).members.count == 1)
        #expect(try Self.group(Array(ids.prefix(64))).members.count == 64)
    }

    @Test
    func duplicateMemberIDsAreRefused() throws {
        #expect(throws: DuplicateIDError(rawValue: "bnd.g-mix")) {
            try Self.group([Self.mixID, Self.levelID, Self.mixID])
        }
    }

    @Test
    func codableRoundTripKeepsUnknownFieldsAndOrder() throws {
        let wire = #"{"future":true,"id":"bgp.knob-9","members":["bnd.g-mix","bnd.g-level","bnd.g-colour"]}"#
        let decoded = try ContractCoding.decode(ControlBindingGroup.self, from: Data(wire.utf8))
        #expect(decoded.members == [Self.mixID, Self.levelID, Self.colourID])
        #expect(decoded.unknownFields == ["future": .bool(true)])
        #expect(try ContractCoding.makeEncoder().encode(decoded) == Data(wire.utf8))
        let duplicate = wire.replacingOccurrences(of: "bnd.g-colour", with: "bnd.g-mix")
        #expect(throws: (any Error).self) {
            try ContractCoding.decode(ControlBindingGroup.self, from: Data(duplicate.utf8))
        }
    }

    @Test
    func staleOrInconsistentGroupsRefuseAsAWhole() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.colourID])
        let (mix, level, colour) = (try Self.relativeMix(), try Self.relativeLevel(), try Self.relativeColour())
        let truth = try Self.relativeTruth()
        let states = Self.engaged([Self.mixID, Self.levelID, Self.colourID])
        func refusal(_ bindings: [ControlBinding], _ custom: [BindingID: PickupState]? = nil,
                     group other: ControlBindingGroup? = nil) -> ControlBindingGroupRefusal? {
            do throws(ControlBindingGroupRefusal) {
                _ = try (other ?? group).resolve(input: .relative(delta: 1), bindings: bindings, truth: truth,
                                                 states: custom ?? states)
                return nil
            } catch { return error }
        }
        #expect(refusal([mix, colour]) == .memberMissing(Self.levelID))
        #expect(refusal([mix, level, colour, mix]) == .duplicateBinding(Self.mixID))
        let elsewhere = ControlSourceID(validated: "ctl.other")
        let moved = try Self.member(Self.levelID, Self.level, .decibels, Self.relative, step: 0.5, source: elsewhere)
        #expect(refusal([mix, moved, colour]) == .mixedSource(Self.levelID, expected: Self.knob, found: elsewhere))
        let sign = EncoderProfile.signMagnitude(width: .seven)
        let signed = try Self.member(Self.levelID, Self.level, .decibels, sign, step: 0.5)
        #expect(refusal([mix, signed, colour]) == .mixedProfile(Self.levelID, expected: Self.relative, found: sign))
        let again = try Self.member(Self.colourID, Self.mix, .percent, Self.relative, step: 1)
        #expect(refusal([mix, level, again]) == .duplicateTarget(Self.mix))
        #expect(refusal([mix, level, colour], Self.engaged([Self.mixID, Self.levelID])) == .stateMissing(Self.colourID))
        let movedColour = try Self.member(Self.colourID, Self.colour, .index, Self.relative, step: 1, source: elsewhere)
        #expect(refusal([mix, movedColour]) == .memberMissing(Self.levelID))
        let fine = EncoderProfile.absolute(resolution: 16_384)
        let faders = [try Self.member(Self.mixID, Self.mix, .percent, Self.absolute, pickup: .jump),
                      try Self.member(Self.levelID, Self.level, .decibels, fine, pickup: .jump)]
        let pair = try Self.group([Self.mixID, Self.levelID])
        #expect(refusal(faders, group: pair) == .mixedProfile(Self.levelID, expected: Self.absolute, found: fine))
        #expect(throws: ControlBindingGroupRefusal.memberMissing(Self.levelID)) { try group.members(in: [mix, colour]) }
    }

    @Test
    func suppliedBindingSetIsBounded() throws {
        let group = try Self.group([Self.mixID])
        let mix = try Self.relativeMix()
        let filler = try (0..<4095).map {
            try Self.member(BindingID("bnd.f\($0)"), Self.level, .decibels, Self.relative, step: 0.5)
        }
        #expect(try group.members(in: [mix] + filler) == [mix])
        let extra = try Self.member(BindingID("bnd.f4095"), Self.level, .decibels, Self.relative, step: 0.5)
        #expect(throws: ControlBindingGroupRefusal.tooManyBindings(4097)) {
            try group.members(in: [mix] + filler + [extra])
        }
    }

    @Test
    func relativeFanOutStepsEachMemberByItsOwnStepInDeclaredOrder() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.colourID])
        let (mix, level, colour) = (try Self.relativeMix(), try Self.relativeLevel(), try Self.relativeColour())
        let result = try group.resolve(input: .relative(delta: 2), bindings: [colour, level, mix],
                                       truth: try Self.relativeTruth(),
                                       states: Self.engaged([Self.mixID, Self.levelID, Self.colourID]))
        #expect(result.map(\.binding) == [Self.mixID, Self.levelID, Self.colourID])
        #expect(result.map(\.outcome) == [
            Self.applied(Self.mix, 34, .percent), Self.applied(Self.level, -9, .decibels),
            Self.applied(Self.colour, 7, .index)
        ])
    }

    @Test
    func relativeMembersClampIndependently() throws {
        let group = try Self.group([Self.mixID, Self.levelID])
        let (mix, level) = (try Self.relativeMix(), try Self.relativeLevel())
        let truth = try Self.relativeTruth(mix: 100)
        let result = try group.resolve(input: .relative(delta: 1), bindings: [mix, level], truth: truth,
                                       states: Self.engaged([Self.mixID, Self.levelID]))
        #expect(result.map(\.outcome) == [
            .resolved(PickupResolution(decision: .unchanged, state: .engaged(hardware: nil))),
            Self.applied(Self.level, -9.5, .decibels)
        ])
    }

    @Test
    func absoluteFanOutMapsOnePositionOverEachMembersRange() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.widthID])
        let faders = try Self.absoluteMembers()
        let truth = try Self.absoluteTruth()
        let states = Self.engaged([Self.mixID, Self.levelID, Self.widthID])
        for (position, expected) in [(0.5, [50, -45, 0.5]), (0.0, [0, -90, 0.25]), (1.0, [100, 0, 0.75])] {
            let result = try group.resolve(input: .absolute(normalized: position), bindings: faders, truth: truth,
                                           states: states)
            let values = result.map { Self.value(of: $0.outcome) }
            #expect(values == expected.map(Optional.some), "position \(position)")
            #expect(result.map(\.outcome).allSatisfy {
                guard case .resolved(let resolution) = $0 else { return false }
                return resolution.state == .engaged(hardware: position)
            })
        }
    }

    @Test
    func catchMembersEngageIndependently() throws {
        let group = try Self.group([Self.mixID, Self.levelID])
        let faders = [try Self.member(Self.mixID, Self.mix, .percent, Self.absolute, pickup: .catch),
                      try Self.member(Self.levelID, Self.level, .decibels, Self.absolute, pickup: .jump)]
        let states: [BindingID: PickupState] = [
            Self.mixID: .waiting(hardware: nil), Self.levelID: .engaged(hardware: nil)
        ]
        let result = try group.resolve(input: .absolute(normalized: 0.5), bindings: faders,
                                       truth: try Self.absoluteTruth(), states: states)
        #expect(result.map(\.outcome) == [
            .resolved(PickupResolution(decision: .held(hardware: 0.5, target: 0.3, reason: .notCaught),
                                       state: .waiting(hardware: 0.5))),
            .resolved(PickupResolution(decision: .apply(.set(Self.level, .init(value: -45, unit: .decibels))),
                                       state: .engaged(hardware: 0.5)))
        ])
    }

    @Test
    func storedCatchPositionsFlowThroughPerMember() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.widthID])
        let faders = [try Self.member(Self.mixID, Self.mix, .percent, Self.absolute, pickup: .catch),
                      try Self.member(Self.levelID, Self.level, .decibels, Self.absolute, pickup: .catch),
                      try Self.member(Self.widthID, Self.width, .normalized, Self.absolute, pickup: .catch)]
        let states: [BindingID: PickupState] = [
            Self.mixID: .waiting(hardware: 0.2), Self.levelID: .waiting(hardware: 0.95),
            Self.widthID: .waiting(hardware: 0.6)
        ]
        let result = try group.resolve(input: .absolute(normalized: 0.5), bindings: faders,
                                       truth: try Self.absoluteTruth(), states: states)
        #expect(result.map(\.outcome) == [
            .resolved(PickupResolution(decision: .apply(.set(Self.mix, .init(value: 50, unit: .percent))),
                                       state: .engaged(hardware: 0.5))),
            .resolved(PickupResolution(decision: .apply(.set(Self.level, .init(value: -45, unit: .decibels))),
                                       state: .engaged(hardware: 0.5))),
            .resolved(PickupResolution(decision: .held(hardware: 0.5, target: 0.3, reason: .notCaught),
                                       state: .waiting(hardware: 0.5)))
        ])
    }

    @Test
    func duplicateNonMemberBindingRefusesTheGroup() throws {
        let group = try Self.group([Self.mixID])
        let (mix, level) = (try Self.relativeMix(), try Self.relativeLevel())
        let outsider = try Self.member(Self.widthID, Self.width, .normalized, Self.relative, step: 0.1)
        let twin = try Self.member(Self.widthID, Self.colour, .index, Self.relative, step: 1)
        #expect(throws: ControlBindingGroupRefusal.duplicateBinding(Self.widthID)) {
            try group.members(in: [mix, outsider, level, twin])
        }
        #expect(throws: ControlBindingGroupRefusal.duplicateBinding(Self.widthID)) {
            try group.resolve(input: .relative(delta: 1), bindings: [outsider, mix, twin],
                              truth: try Self.relativeTruth(), states: Self.engaged([Self.mixID]))
        }
        #expect(try group.members(in: [outsider, mix, level]) == [mix])
    }

    @Test
    func groupRefusalsPrecedeMemberChecksInFixedOrder() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.colourID])
        let (mix, level, colour) = (try Self.relativeMix(), try Self.relativeLevel(), try Self.relativeColour())
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let index = try Fixture.descriptor(Self.colour, unit: .index, range: 1...12, curve: .stepped)
        let levelGone = try Truth.truth([percent, index], [Self.mix: 30, Self.colour: 5])
        #expect(throws: ControlBindingGroupRefusal.memberMissing(Self.colourID)) {
            try group.resolve(input: .relative(delta: 1), bindings: [mix, level], truth: levelGone,
                              states: Self.engaged([Self.mixID]))
        }
        #expect(throws: ControlBindingGroupRefusal.stateMissing(Self.levelID)) {
            try group.resolve(input: .relative(delta: 1), bindings: [mix, level, colour], truth: levelGone,
                              states: Self.engaged([Self.mixID, Self.colourID]))
        }
    }

    @Test
    func nonFiniteHostValueRefusesOnlyThatMember() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.colourID])
        let (mix, level, colour) = (try Self.relativeMix(), try Self.relativeLevel(), try Self.relativeColour())
        let descriptors = [
            try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100),
            try Fixture.descriptor(Self.level, unit: .decibels, range: -90...0),
            try Fixture.descriptor(Self.colour, unit: .index, range: 1...12, curve: .stepped)
        ]
        for (first, last) in [(Double.nan, Double.infinity), (-.infinity, .nan)] {
            let truth = try Truth.truth(descriptors, [Self.mix: first, Self.level: -10, Self.colour: last])
            let result = try group.resolve(input: .relative(delta: 1), bindings: [mix, level, colour], truth: truth,
                                           states: Self.engaged([Self.mixID, Self.levelID, Self.colourID]))
            #expect(result.map(\.outcome) == [.refused(.nonFinite), Self.applied(Self.level, -9.5, .decibels),
                                              .refused(.nonFinite)])
        }
    }

    @Test
    func memberRefusalIsIsolated() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.colourID])
        let (mix, level, colour) = (try Self.relativeMix(), try Self.relativeLevel(), try Self.relativeColour())
        let ids = [Self.mixID, Self.levelID, Self.colourID]
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let index = try Fixture.descriptor(Self.colour, unit: .index, range: 1...12, curve: .stepped)
        let missing = try Truth.truth([percent, index], [Self.mix: 30, Self.level: -10, Self.colour: 5])
        var result = try group.resolve(input: .relative(delta: 1), bindings: [mix, level, colour], truth: missing,
                                       states: Self.engaged(ids))
        #expect(result.map(\.outcome) == [Self.applied(Self.mix, 32, .percent), .refused(.targetMissing(Self.level)),
                                          Self.applied(Self.colour, 6, .index)])
        let decibels = try Fixture.descriptor(Self.level, unit: .decibels, range: -90...0)
        let hazardous = try Fixture.descriptor(Self.colour, unit: .index, range: 1...12, curve: .stepped,
                                               controlClass: .hazardous)
        let reclassed = try Truth.truth([percent, decibels, hazardous], [Self.mix: 30, Self.level: -10, Self.colour: 5])
        result = try group.resolve(input: .relative(delta: 1), bindings: [mix, level, colour], truth: reclassed,
                                   states: Self.engaged(ids))
        #expect(result.map(\.outcome) == [
            Self.applied(Self.mix, 32, .percent), Self.applied(Self.level, -9.5, .decibels),
            .refused(.unboundableClass(.hazardous))
        ])
        var stale = Self.engaged(ids)
        stale[Self.mixID] = .unavailable
        result = try group.resolve(input: .relative(delta: 1), bindings: [mix, level, colour],
                                   truth: try Self.relativeTruth(), states: stale)
        #expect(result.map(\.outcome) == [.refused(.pickupUnavailable), Self.applied(Self.level, -9.5, .decibels),
                                          Self.applied(Self.colour, 6, .index)])
    }

    @Test
    func fanOutIsDeterministicAndIndependentOfSuppliedOrder() throws {
        let group = try Self.group([Self.mixID, Self.levelID, Self.colourID])
        let (mix, level, colour) = (try Self.relativeMix(), try Self.relativeLevel(), try Self.relativeColour())
        let truth = try Self.relativeTruth()
        let states = Self.engaged([Self.mixID, Self.levelID, Self.colourID])
        let orders = [[mix, level, colour], [colour, level, mix], [level, colour, mix], [mix, level, colour]]
        let runs = try orders.map {
            try group.resolve(input: .relative(delta: -3), bindings: $0, truth: truth, states: states)
        }
        #expect(runs.allSatisfy { $0 == runs[0] })
        #expect(runs[0].map(\.binding) == [Self.mixID, Self.levelID, Self.colourID])
        #expect(runs[0].map { Self.value(of: $0.outcome) } == [24, -11.5, 2])
    }

    @Test
    func singleMemberGroupEqualsBindingResolve() throws {
        let group = try Self.group([Self.levelID])
        let level = try Self.relativeLevel()
        let truth = try Self.relativeTruth()
        for delta in [-200, -1, 0, 1, 25] {
            let input = ControlInput.relative(delta: delta)
            let result = try group.resolve(input: input, bindings: [level], truth: truth,
                                           states: [Self.levelID: .engaged(hardware: nil)])
            let direct = try level.resolve(input: input, truth: truth, state: .engaged(hardware: nil))
            #expect(result == [ControlGroupMemberResolution(binding: Self.levelID, outcome: .resolved(direct))])
        }
    }

    @Test
    func extraStatesAndNonMemberBindingsAreIgnored() throws {
        let group = try Self.group([Self.mixID])
        let (mix, level, colour) = (try Self.relativeMix(), try Self.relativeLevel(), try Self.relativeColour())
        let outsider = try Self.member(Self.widthID, Self.mix, .percent, .signMagnitude(width: .seven), step: 1,
                                       source: ControlSourceID(validated: "ctl.other"))
        var states = Self.engaged([Self.mixID, Self.levelID])
        states[Self.widthID] = .unavailable
        let result = try group.resolve(input: .relative(delta: 1), bindings: [outsider, level, mix, colour],
                                       truth: try Self.relativeTruth(), states: states)
        let applied = Self.applied(Self.mix, 32, .percent)
        #expect(result == [ControlGroupMemberResolution(binding: Self.mixID, outcome: applied)])
    }
}

extension ControlBindingGroupTests {
    static func group(_ members: [BindingID]) throws -> ControlBindingGroup {
        try ControlBindingGroup(.init(id: BindingGroupID(validated: "bgp.knob-9"), members: members))
    }

    static func member(
        _ id: BindingID, _ target: ParameterID, _ unit: ParameterUnit, _ profile: EncoderProfile,
        step: Double? = nil, lower: Double? = nil, upper: Double? = nil, pickup: PickupMode? = nil,
        source: ControlSourceID = knob
    ) throws -> ControlBinding {
        try ControlBinding(.init(id: id, source: source, target: target, unit: unit, profile: profile, step: step,
                                 lower: lower, upper: upper, pickup: pickup))
    }

    /// Relative members: Verb Mix steps 2 %, Mains Level 0.5 dB and Colour one index.
    static func relativeMix() throws -> ControlBinding { try member(mixID, mix, .percent, relative, step: 2) }
    static func relativeLevel() throws -> ControlBinding { try member(levelID, level, .decibels, relative, step: 0.5) }
    static func relativeColour() throws -> ControlBinding { try member(colourID, colour, .index, relative, step: 1) }

    /// Absolute jump members: Verb Mix 0...100 %, Mains Level -90...0 dB and Space Width narrowed to 0.25...0.75.
    static func absoluteMembers() throws -> [ControlBinding] {
        [try member(mixID, mix, .percent, absolute, pickup: .jump),
         try member(levelID, level, .decibels, absolute, pickup: .jump),
         try member(widthID, width, .normalized, absolute, lower: 0.25, upper: 0.75, pickup: .jump)]
    }

    static func relativeTruth(mix value: Double = 30) throws -> ControlHostTruth {
        try ControlHostTruthTests.truth([
            Fixture.descriptor(mix, unit: .percent, range: 0...100),
            Fixture.descriptor(level, unit: .decibels, range: -90...0),
            Fixture.descriptor(colour, unit: .index, range: 1...12, curve: .stepped)
        ], [mix: value, level: -10, colour: 5])
    }

    static func absoluteTruth() throws -> ControlHostTruth {
        try ControlHostTruthTests.truth([
            Fixture.descriptor(mix, unit: .percent, range: 0...100),
            Fixture.descriptor(level, unit: .decibels, range: -90...0),
            Fixture.descriptor(width, unit: .normalized, range: 0...1)
        ], [mix: 30, level: -10, width: 0.3])
    }

    static func engaged(_ ids: [BindingID]) -> [BindingID: PickupState] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, PickupState.engaged(hardware: nil)) })
    }

    static func applied(_ id: ParameterID, _ value: Double, _ unit: ParameterUnit) -> ControlGroupMemberOutcome {
        .resolved(PickupResolution(decision: .apply(.set(id, .init(value: value, unit: unit))),
                                   state: .engaged(hardware: nil)))
    }

    /// The value an applied outcome sets, or `nil` for any other outcome.
    static func value(of outcome: ControlGroupMemberOutcome) -> Double? {
        guard case .resolved(let resolution) = outcome, case .apply(.set(_, let value)) = resolution.decision else {
            return nil
        }
        return value.value
    }
}
