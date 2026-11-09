import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Automation bank")
struct AutomationBankTests {
    typealias Fixture = AutomationRenderTests

    static let parA = ParameterID(validated: "par.a")
    static let parB = ParameterID(validated: "par.b")
    static let parC = ParameterID(validated: "par.c")
    static let parZ = ParameterID(validated: "par.z")
    static let byteOrder = ["0.x", ":x", "Z.x", "_x", "a-x", "a.x", "a.xy"]
    static let scrambled = ["a.xy", "a.x", "0.x", "_x", "Z.x", ":x", "a-x"]
    // The ramp lane over [0, 4_096) at 48 kHz, as AutomationRenderTests pins it; typed by hand.
    static let rampStart = AutomationRampEvent(frame: 0, offset: 0, value: 0, rampFrames: 0, reason: .start)
    static let rampRise = AutomationRampEvent(frame: 0, offset: 0, value: 1, rampFrames: 1_563, reason: .start)
    static let rampDrop = AutomationRampEvent(frame: 3_125, offset: 3_125, value: 0.2, rampFrames: 0, reason: .curve)
    static let rampClimb = AutomationRampEvent(
        frame: 3_125, offset: 3_125, value: 0.8, rampFrames: 1_563, reason: .curve
    )

    static func bankLane(_ parameter: ParameterID, _ points: [AutomationBreakpoint]) throws -> AutomationLane {
        let descriptor = try ParameterDescriptor(.init(
            id: parameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0, ceiling: nil, curve: .linear,
            ramp: .step, controlClass: .live, verification: .unverified
        ))
        return try AutomationLane(descriptor: descriptor, breakpoints: points)
    }

    static func bankRamp(_ parameter: ParameterID) throws -> AutomationLane {
        try bankLane(parameter, [.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1, interpolation: .step),
                                 .init(ticks: 2_000, value: 0.2), .init(ticks: 3_000, value: 0.8)])
    }

    /// `count` step breakpoints on ticks 0, 1, 2, ...: `count` events over [0, 4_096) while `count` is 1...1_024.
    static func bankSteps(_ parameter: ParameterID, _ count: Int) throws -> AutomationLane {
        try bankLane(parameter, (0..<max(count, 0)).map {
            .init(ticks: Int64($0), value: $0.isMultiple(of: 2) ? 0 : 1, interpolation: .step)
        })
    }

    static func laneID(_ index: Int) throws -> ParameterID {
        let pad = index < 10 ? "0" : ""
        return try ParameterID("par.\(pad)\(index)")
    }

    static func makeBank(_ lanes: [AutomationLane]) throws -> AutomationBank {
        var bank = AutomationBank()
        for lane in lanes {
            try bank.add(Fixture.renderer(lane))
        }
        return bank
    }

    /// Lanes without breakpoints for the given ids, added in the given order.
    static func orderedBank(_ names: [String]) throws -> AutomationBank {
        try makeBank(names.map { try bankLane(ParameterID($0), []) })
    }

    /// `count` lanes without breakpoints: `par.00`, `par.01`, ...
    static func filledBank(_ count: Int) throws -> AutomationBank {
        var bank = AutomationBank()
        for index in 0..<max(count, 0) {
            try bank.add(Fixture.renderer(bankLane(laneID(index), [])))
        }
        return bank
    }

    /// The step a caller would build: it carries the tempo map and the generations, which the bank does not name.
    static func stepper(rate: Int = 48_000, revision: Generation = .initial,
                        current: AutomationRenderGenerations = Fixture.live) throws -> AutomationBank.Step {
        let map = try Fixture.clock(rate: rate, revision: revision)
        return { renderer, start, end throws(AutomationRenderRefusal) in
            try renderer.render(from: start, to: end, clock: map, current: current)
        }
    }

    static func rendered(_ lane: AutomationLane, upTo end: Int64 = 512) throws -> AutomationBlockRenderer {
        var renderer = try Fixture.renderer(lane)
        let step = try stepper()
        _ = try step(&renderer, 0, end)
        return renderer
    }

    /// How many events the lane renders alone over [0, 4_096); throws the renderer's refusal.
    static func aloneCount(_ lane: AutomationLane) throws -> Int {
        var alone = try Fixture.renderer(lane)
        return try stepper()(&alone, 0, 4_096).count
    }

    static func tag(_ parameter: ParameterID, _ event: AutomationRampEvent) -> AutomationParameterEvent {
        AutomationParameterEvent(parameter: parameter, event: event)
    }

    static func golden(_ parameter: ParameterID) -> [AutomationParameterEvent] {
        [tag(parameter, rampStart), tag(parameter, rampRise), tag(parameter, rampDrop), tag(parameter, rampClimb)]
    }

    static func idBytes(_ parameters: [ParameterID]) -> [[UInt8]] {
        parameters.map { Array($0.rawValue.utf8) }
    }

    static func nameBytes(_ names: [String]) -> [[UInt8]] {
        names.map { Array($0.utf8) }
    }

    /// True if the frames do not go back and equal frames ascend by parameter bytes (strictly, if asked).
    static func inMergeOrder(_ events: [AutomationParameterEvent], strict: Bool = false) -> Bool {
        zip(events, events.dropFirst()).allSatisfy { lhs, rhs in
            guard lhs.event.frame == rhs.event.frame else { return lhs.event.frame < rhs.event.frame }
            let ascending = lhs.parameter.rawValue.utf8.lexicographicallyPrecedes(rhs.parameter.rawValue.utf8)
            return ascending || (lhs.parameter == rhs.parameter && !strict)
        }
    }

    /// Counts the lane renders a step is asked for.
    final class Tally {
        private(set) var calls = 0

        func counting(_ step: @escaping AutomationBank.Step) -> AutomationBank.Step {
            { renderer, start, end throws(AutomationRenderRefusal) in
                self.calls += 1
                return try step(&renderer, start, end)
            }
        }
    }

    @Test func automationBankMergesLanesByFrameThenParameterBytesThenEmission() throws {
        var bank = try Self.makeBank([Self.bankRamp(Self.parB), Self.bankRamp(Self.parA)])
        let events = try bank.render(from: 0, to: 4_096, using: Self.stepper())
        let expected = [
            Self.tag(Self.parA, Self.rampStart), Self.tag(Self.parA, Self.rampRise),
            Self.tag(Self.parB, Self.rampStart), Self.tag(Self.parB, Self.rampRise),
            Self.tag(Self.parA, Self.rampDrop), Self.tag(Self.parA, Self.rampClimb),
            Self.tag(Self.parB, Self.rampDrop), Self.tag(Self.parB, Self.rampClimb)
        ]
        #expect(events == expected)
        let cursors: [Int64?] = bank.renderers.map(\.cursor)
        #expect(cursors == [4_096, 4_096])
    }

    @Test func automationBankKeepsLanesInByteOrderOfTheParameterId() throws {
        let sorted = Self.nameBytes(Self.byteOrder)
        let mixed = try Self.orderedBank(Self.scrambled)
        let ascending = try Self.orderedBank(Self.byteOrder)
        let descending = try Self.orderedBank(Self.byteOrder.reversed())
        for bank in [mixed, ascending, descending] {
            #expect(Self.idBytes(bank.parameters) == sorted)
            #expect(bank.count == 7)
            for name in Self.byteOrder {
                let id = try ParameterID(name)
                #expect(bank.renderer(for: id)?.arbiter.lane.parameter == id)
            }
            for name in ["a.y", "0.w", "par.z"] {
                let missing = try ParameterID(name)
                #expect(bank.renderer(for: missing) == nil)
            }
        }
        #expect(mixed == ascending)
        #expect(ascending == descending)
    }

    @Test func automationBankOrdersTiedFramesByParameterBytesNotByInsertionOrder() throws {
        let lower = try ParameterID("a.x")
        let underscore = try ParameterID("_x")
        let upper = try ParameterID("Z.x")
        var bank = try Self.makeBank([Self.bankRamp(lower), Self.bankRamp(underscore), Self.bankRamp(upper)])
        let events = try bank.render(from: 0, to: 4_096, using: Self.stepper())
        let expected = [
            Self.tag(upper, Self.rampStart), Self.tag(upper, Self.rampRise),
            Self.tag(underscore, Self.rampStart), Self.tag(underscore, Self.rampRise),
            Self.tag(lower, Self.rampStart), Self.tag(lower, Self.rampRise),
            Self.tag(upper, Self.rampDrop), Self.tag(upper, Self.rampClimb),
            Self.tag(underscore, Self.rampDrop), Self.tag(underscore, Self.rampClimb),
            Self.tag(lower, Self.rampDrop), Self.tag(lower, Self.rampClimb)
        ]
        #expect(events == expected)
    }

    @Test func automationBankEqualsItsLanesRenderedAloneAcrossBlockSplitsAndRates() throws {
        let edges: [Int64] = [0, 700, 2_049, 4_096, 8_192]
        for rate in [44_100, 48_000, 96_000] {
            let step = try Self.stepper(rate: rate)
            var bank = try Self.makeBank([Self.bankRamp(Self.parA), Self.bankSteps(Self.parB, 24)])
            var aloneA = try Fixture.renderer(Self.bankRamp(Self.parA))
            var aloneB = try Fixture.renderer(Self.bankSteps(Self.parB, 24))
            for (from, to) in zip(edges, edges.dropFirst()) {
                let merged = try bank.render(from: from, to: to, using: step)
                let eventsA = try step(&aloneA, from, to)
                let eventsB = try step(&aloneB, from, to)
                let mergedA = merged.filter { $0.parameter == Self.parA }.map(\.event)
                let mergedB = merged.filter { $0.parameter == Self.parB }.map(\.event)
                let total = eventsA.count + eventsB.count
                #expect(mergedA == eventsA)
                #expect(mergedB == eventsB)
                #expect(merged.count == total)
                #expect(Self.inMergeOrder(merged))
            }
        }
    }

    @Test func automationBankPublishesNothingWhenALaterLaneRefuses() throws {
        let refused = AutomationRenderRefusal.tooManyEvents(limit: 1_024)
        #expect(throws: refused) { try Self.aloneCount(Self.bankSteps(Self.parB, 1_025)) }
        var bank = try Self.makeBank([Self.bankRamp(Self.parA), Self.bankSteps(Self.parB, 1_025)])
        let before = bank
        let step = try Self.stepper()
        #expect(throws: AutomationBankRefusal.lane(parameter: Self.parB, refusal: refused)) {
            try bank.render(from: 0, to: 4_096, using: step)
        }
        #expect(bank == before)
        try bank.remove(Self.parB)
        #expect(try bank.render(from: 0, to: 4_096, using: step) == Self.golden(Self.parA))
    }

    @Test func automationBankRefusesALaneThatDidNotReachTheWindowEnd() throws {
        let base = try Self.stepper()
        func refusal(got: Int64?, _ step: AutomationBank.Step) throws {
            var bank = try Self.makeBank([Self.bankRamp(Self.parA)])
            let before = bank
            let expected = AutomationBankRefusal.laneNotAtWindowEnd(parameter: Self.parA, expected: 4_096, got: got)
            #expect(throws: expected) { try bank.render(from: 0, to: 4_096, using: step) }
            #expect(bank == before)
        }
        try refusal(got: 4_095) { renderer, start, end throws(AutomationRenderRefusal) in
            try base(&renderer, start, end - 1)
        }
        try refusal(got: nil) { _, _, _ in [] }
        try refusal(got: 4_097) { renderer, start, end throws(AutomationRenderRefusal) in
            try base(&renderer, start, end + 1)
        }
        // Both defects at once: 1,200 events across the two lanes and a short second lane. The cursor check wins.
        let shortOnSecond: AutomationBank.Step = { renderer, start, end throws(AutomationRenderRefusal) in
            let isSecond = renderer.arbiter.lane.parameter == Self.parB
            return try base(&renderer, start, isSecond ? end - 1 : end)
        }
        #expect(try Self.aloneCount(Self.bankSteps(Self.parB, 600)) == 600)
        var crowded = try Self.makeBank([Self.bankSteps(Self.parA, 600), Self.bankSteps(Self.parB, 600)])
        let before = crowded
        let both = AutomationBankRefusal.laneNotAtWindowEnd(parameter: Self.parB, expected: 4_096, got: 4_095)
        #expect(throws: both) { try crowded.render(from: 0, to: 4_096, using: shortOnSecond) }
        #expect(crowded == before)
    }

    @Test func automationBankReportsTheFirstRefusingLaneInByteOrderAndStops() throws {
        var bank = try Self.makeBank([Self.bankSteps(Self.parC, 1_025), Self.bankRamp(Self.parA),
                                      Self.bankSteps(Self.parB, 1_025)])
        let before = bank
        let tally = Self.Tally()
        let step = try tally.counting(Self.stepper())
        let expected = AutomationBankRefusal.lane(parameter: Self.parB, refusal: .tooManyEvents(limit: 1_024))
        #expect(throws: expected) { try bank.render(from: 0, to: 4_096, using: step) }
        #expect(tally.calls == 2)
        #expect(bank == before)
    }

    @Test func automationBankChecksDuplicateThenLaneLimitThenRenderedOnAdd() throws {
        var full = try Self.filledBank(AutomationBank.maximumLanes)
        let fullBefore = full
        let seventh = try Self.laneID(7)
        let present = try Fixture.renderer(Self.bankLane(seventh, []))
        #expect(throws: AutomationBankRefusal.duplicateLane(seventh)) { try full.add(present) }
        let usedUp = try Self.rendered(Self.bankLane(Self.laneID(64), []))
        #expect(throws: AutomationBankRefusal.laneLimitReached(limit: 64)) { try full.add(usedUp) }
        #expect(full == fullBefore)
        var bank = try Self.makeBank([Self.bankRamp(Self.parA)])
        let before = bank
        let usedA = try Self.rendered(Self.bankRamp(Self.parA))
        #expect(throws: AutomationBankRefusal.duplicateLane(Self.parA)) { try bank.add(usedA) }
        var usedB = try Self.rendered(Self.bankRamp(Self.parB))
        #expect(throws: AutomationBankRefusal.laneAlreadyRendered(Self.parB)) { try bank.add(usedB) }
        #expect(bank == before)
        usedB.reset()
        try bank.add(usedB)
        #expect(bank.count == 2)
        #expect(bank.renderer(for: Self.parB)?.cursor == nil)
    }

    @Test func automationBankWithoutLanesRendersNothingAndKeepsNoPosition() throws {
        var bank = AutomationBank()
        let tally = Self.Tally()
        let step = try tally.counting(Self.stepper())
        let none = try bank.render(from: 0, to: 4_096, using: step)
        #expect(none.isEmpty)
        #expect(bank == AutomationBank())
        #expect(tally.calls == 0)
        try bank.add(Fixture.renderer(Self.bankRamp(Self.parA)))
        let later = try bank.render(from: 7_000, to: 7_100, using: step)
        let first = try #require(later.first)
        #expect(first.parameter == Self.parA)
        #expect(first.event.reason == .start)
        #expect(first.event.frame == 7_000)
        #expect(first.event.offset == 0)
        #expect(bank.renderers.map(\.cursor) == [7_100])
    }

    @Test func automationBankRoutesAGestureToTheNamedLaneAndLeavesTheOthersUnchanged() throws {
        var bank = try Self.makeBank([Self.bankRamp(Self.parA), Self.bankRamp(Self.parB), Self.bankRamp(Self.parC)])
        _ = try bank.render(from: 0, to: 2_048, using: Self.stepper())
        let beforeA = try #require(bank.renderer(for: Self.parA))
        let beforeB = try #require(bank.renderer(for: Self.parB))
        let beforeC = try #require(bank.renderer(for: Self.parC))
        let result = try bank.perform(.touch(Fixture.fader, priority: 1), on: Self.parB)
        #expect(result.owner == .gesture(Fixture.fader))
        #expect(bank.renderer(for: Self.parB)?.arbiter.owner == .gesture(Fixture.fader))
        #expect(bank.renderer(for: Self.parB) != beforeB)
        #expect(bank.renderer(for: Self.parA) == beforeA)
        #expect(bank.renderer(for: Self.parC) == beforeC)
    }

    @Test func automationBankRefusesGesturesItCannotRoute() throws {
        var bank = try Self.makeBank([Self.bankRamp(Self.parA)])
        _ = try bank.render(from: 0, to: 2_048, using: Self.stepper())
        try bank.add(Fixture.renderer(Self.bankRamp(Self.parB)))
        let before = bank
        let touch = AutomationRenderGesture.touch(Fixture.fader, priority: 1)
        #expect(throws: AutomationBankRefusal.parameterNotInBank(Self.parZ)) {
            try bank.perform(touch, on: Self.parZ)
        }
        #expect(bank == before)
        #expect(throws: AutomationBankRefusal.lane(parameter: Self.parB, refusal: .notStarted)) {
            try bank.perform(touch, on: Self.parB)
        }
        #expect(bank == before)
        let untouched = AutomationRenderRefusal.automation(.notTouched(Fixture.fader))
        #expect(throws: AutomationBankRefusal.lane(parameter: Self.parA, refusal: untouched)) {
            try bank.perform(.move(Fixture.fader, to: 0.5), on: Self.parA)
        }
        #expect(bank == before)
    }

    @Test func automationBankResetClearsTheCursorsAndKeepsTheArbiters() throws {
        var bank = try Self.makeBank([Self.bankRamp(Self.parA), Self.bankRamp(Self.parB), Self.bankRamp(Self.parC)])
        let step = try Self.stepper()
        _ = try bank.render(from: 0, to: 2_048, using: step)
        _ = try bank.perform(.touch(Fixture.fader, priority: 1), on: Self.parB)
        let parameters = bank.parameters
        let arbiters = bank.renderers.map(\.arbiter)
        bank.reset()
        let cursors: [Int64?] = bank.renderers.map(\.cursor)
        #expect(cursors == [nil, nil, nil])
        #expect(bank.parameters == parameters)
        #expect(bank.renderers.map(\.arbiter) == arbiters)
        #expect(bank.count == 3)
        _ = try bank.render(from: 10_000, to: 12_000, using: step)
        #expect(bank.renderers.map(\.cursor) == [12_000, 12_000, 12_000])
    }

    @Test func automationBankLetsALaneJoinAtTheNextWindowAndRefusesASkippedOne() throws {
        var bank = try Self.makeBank([Self.bankRamp(Self.parA)])
        let base = try Self.stepper()
        _ = try bank.render(from: 0, to: 2_048, using: base)
        try bank.add(Fixture.renderer(Self.bankRamp(Self.parB)))
        let before = bank
        let tally = Self.Tally()
        let skipped = tally.counting(base)
        let gap = AutomationRenderRefusal.nonContiguousWindow(expected: 2_048, start: 4_096)
        #expect(throws: AutomationBankRefusal.lane(parameter: Self.parA, refusal: gap)) {
            try bank.render(from: 4_096, to: 6_144, using: skipped)
        }
        #expect(tally.calls == 1)
        #expect(bank == before)
        let joined = try bank.render(from: 2_048, to: 4_096, using: base)
        let first = try #require(joined.first { $0.parameter == Self.parB })
        #expect(first.event.reason == .start)
        #expect(first.event.frame == 2_048)
        #expect(first.event.offset == 0)
        #expect(bank.renderers.map(\.cursor) == [4_096, 4_096])
    }

    @Test func automationBankRemovesALaneAndKeepsRenderingTheRest() throws {
        var bank = try Self.makeBank([Self.bankRamp(Self.parA), Self.bankRamp(Self.parB), Self.bankRamp(Self.parC)])
        let step = try Self.stepper()
        _ = try bank.render(from: 0, to: 2_048, using: step)
        let removed = try bank.remove(Self.parB)
        #expect(removed.cursor == 2_048)
        #expect(Self.idBytes([removed.arbiter.lane.parameter]) == Self.idBytes([Self.parB]))
        #expect(bank.count == 2)
        #expect(bank.renderer(for: Self.parB) == nil)
        let afterRemoval = bank
        #expect(throws: AutomationBankRefusal.parameterNotInBank(Self.parB)) { try bank.remove(Self.parB) }
        #expect(bank == afterRemoval)
        let events = try bank.render(from: 2_048, to: 4_096, using: step)
        let drop = AutomationRampEvent(frame: 3_125, offset: 1_077, value: 0.2, rampFrames: 0, reason: .curve)
        let climb = AutomationRampEvent(frame: 3_125, offset: 1_077, value: 0.8, rampFrames: 1_563, reason: .curve)
        let expected = [
            Self.tag(Self.parA, drop), Self.tag(Self.parA, climb), Self.tag(Self.parC, drop), Self.tag(Self.parC, climb)
        ]
        #expect(events == expected)
    }

    @Test func automationBankRefusesAStaleGenerationAtTheFirstLaneAndResetStartsAfresh() throws {
        var bank = try Self.makeBank([Self.bankRamp(Self.parA), Self.bankRamp(Self.parB)])
        _ = try bank.render(from: 0, to: 512, using: Self.stepper())
        let before = bank
        let newer = try Generation(2)
        let staleSample = AutomationRenderGenerations(sample: newer, transport: .initial, musicalMap: .initial)
        let stale = try Self.stepper(current: staleSample)
        let refused = AutomationRenderRefusal.clock(.staleSampleGeneration)
        #expect(throws: AutomationBankRefusal.lane(parameter: Self.parA, refusal: refused)) {
            try bank.render(from: 512, to: 600, using: stale)
        }
        #expect(bank == before)
        bank.reset()
        let current = AutomationRenderGenerations(sample: .initial, transport: .initial, musicalMap: newer)
        let fresh = try Self.stepper(revision: newer, current: current)
        _ = try bank.render(from: 9_000, to: 9_100, using: fresh)
        #expect(bank.renderers.map(\.cursor) == [9_100, 9_100])
    }
}
