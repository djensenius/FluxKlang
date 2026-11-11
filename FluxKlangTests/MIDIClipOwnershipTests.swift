import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI clip note ownership", .productionAccessAudit)
struct MIDIClipOwnershipTests {
    static let primary = ClockID(validated: "smp.main")
    static let musical = ClockID(validated: "mus.main")
    static let live = MIDIClipGenerations(sample: .initial, transport: .initial, musicalMap: .initial)
    static let quarter = MusicalTime.ticksPerQuarter
    static let clipID = MIDIInputID(1)
    static let otherID = MIDIInputID(2)
    static let thirdID = MIDIInputID(3)
    static let route1 = MIDIRouteID(10)
    static let route2 = MIDIRouteID(11)

    /// Generations with the given counters (1 is `.initial`).
    static func generations(sample: Int = 1, transport: Int = 1, map: Int = 1) throws -> MIDIClipGenerations {
        MIDIClipGenerations(sample: try Generation(sample), transport: try Generation(transport),
                            musicalMap: try Generation(map))
    }

    /// A clock for `current` whose anchor puts `ticks` on `frame`; 120 BPM at 48 kHz by default (a quarter is
    /// 24_000 frames).
    static func clock(_ current: MIDIClipGenerations = live, frame: Int64 = 0, ticks: Int64 = 0,
                      segments: [(Int64, Int64)] = [(0, 500_000)],
                      loopIteration: UInt32 = 0) throws -> MusicalClockMap {
        let anchor = ClockAnchor(
            sample: SampleStamp(clock: primary, generation: current.sample, frame: frame), host: HostStamp(ticks: 0),
            musical: MusicalStamp(transport: current.transport, musicalMap: current.musicalMap, ticks: ticks,
                                  loopIteration: loopIteration)
        )
        let map = try MusicalMap(clock: musical, revision: current.musicalMap,
                                 segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: 48_000, currentSample: current.sample,
                                   currentTransport: current.transport)
    }

    static func note(_ start: Int64, _ end: Int64, pitch: UInt8 = 60, release: UInt8 = 64) -> MIDIClipItem {
        .note(MIDIClipNote(channel: 1, note: pitch, velocity: 100, releaseVelocity: release,
                           startTicks: start, endTicks: end))
    }

    static func placement(_ items: [MIDIClipItem], length: Int64 = 4 * quarter,
                          loop: (Int64, Int64)? = nil) throws -> MIDIClipPlacement {
        let clip = try MIDIClip.make(lengthTicks: length, items: items)
        return try MIDIClipPlacement.make(clip: clip, startTicks: 0,
                                          loop: loop.map { try LoopRange(startTicks: $0.0, endTicks: $0.1) })
    }

    static func on(_ pitch: UInt8, velocity: UInt8 = 100) -> MIDI1Semantic {
        .noteOn(channel: 1, note: pitch, velocity: velocity)
    }

    static func off(_ pitch: UInt8, velocity: UInt8 = 64) -> MIDI1Semantic {
        .noteOff(channel: 1, note: pitch, velocity: velocity)
    }

    /// A routing of `input` to every route of `routes` on all channels, in the given order.
    static func routing(_ input: MIDIInputID, to routes: [MIDIRouteID] = [route1]) throws -> MIDIRouting {
        let rules = try routes.map { try #require(MIDIRoutingRule(input: input, route: $0)) }
        return try #require(MIDIRouting(rules: rules))
    }

    static func clipInput(_ id: MIDIInputID = clipID, to routes: [MIDIRouteID] = [route1]) throws -> MIDIClipInput {
        try MIDIClipInput.make(input: id, routing: routing(id, to: routes))
    }

    /// A host over `ledger` (a fresh one by default) with one clip bound to `id`.
    static func host(_ items: [MIDIClipItem], id: MIDIInputID = clipID, to routes: [MIDIRouteID] = [route1],
                     length: Int64 = 4 * quarter, loop: (Int64, Int64)? = nil,
                     ledger: MIDINoteLedger? = nil) throws -> MIDIClipHost {
        var host = MIDIClipHost(ledger: try ledger ?? Self.ledger())
        try addClip(items, id: id, to: routes, length: length, loop: loop, in: &host)
        return host
    }

    static func addClip(_ items: [MIDIClipItem], id: MIDIInputID, to routes: [MIDIRouteID] = [route1],
                        length: Int64 = 4 * quarter, loop: (Int64, Int64)? = nil,
                        in host: inout MIDIClipHost) throws {
        try host.add(try clipInput(id, to: routes), placement: try placement(items, length: length, loop: loop))
    }

    static func ledger(noteCapacity: Int = 1024) throws -> MIDINoteLedger {
        MIDINoteLedger(policy: try #require(MIDINoteLedgerPolicy(noteCapacity: noteCapacity)))
    }

    /// Routes one live message of `input` through `routing`, as a drone or pedal player would.
    @discardableResult
    static func play(_ message: MIDI1Semantic, input: MIDIInputID, to routes: [MIDIRouteID] = [route1],
                     in ledger: inout MIDINoteLedger) throws -> [MIDIRoutedOutput] {
        try ledger.route(MIDIPerformanceEvent(input: input, message: message), routing: routing(input, to: routes))
    }

    /// The same, through the host's pass-through.
    @discardableResult
    static func play(_ message: MIDI1Semantic, input: MIDIInputID, to routes: [MIDIRouteID] = [route1],
                     in host: inout MIDIClipHost) throws -> [MIDIRoutedOutput] {
        try host.routeOther([MIDIPerformanceEvent(input: input, message: message)],
                            routing: routing(input, to: routes))
    }

    static func entries(of input: MIDIInputID, in ledger: MIDINoteLedger) -> [MIDINoteInstance] {
        ledger.notes.filter { $0.input == input }
    }

    static func refusal(_ body: () throws -> some Any) -> MIDIClipHostRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? MIDIClipHostRefusal
        }
    }

    static func render(_ host: inout MIDIClipHost, _ id: MIDIInputID = clipID, from start: Int64 = 0,
                       to end: Int64, clock: MusicalClockMap? = nil,
                       current: MIDIClipGenerations = live) throws -> MIDIClipOwnershipReport {
        try host.render(input: id, from: start, to: end, clock: try clock ?? Self.clock(), current: current)
    }

    @Test
    func aClipInputPairsTheClipsOwnIdentityWithItsRouting() throws {
        let routing = try Self.routing(Self.clipID, to: [Self.route1, Self.route2])
        let input = try MIDIClipInput.make(input: Self.clipID, routing: routing)
        #expect(input.input == Self.clipID)
        #expect(input.routing == routing)
        #expect(input.routing.rules.map(\.route) == [Self.route1, Self.route2])
    }

    @Test
    func aRoutingWithAForeignRuleIsRefusedAtTheFirstForeignRuleInEitherOrder() throws {
        let own = try #require(MIDIRoutingRule(input: Self.clipID, route: Self.route1))
        let other = try #require(MIDIRoutingRule(input: Self.otherID, route: Self.route1))
        let third = try #require(MIDIRoutingRule(input: Self.thirdID, route: Self.route2))
        let forward = try #require(MIDIRouting(rules: [own, other, third]))
        #expect(throws: MIDIClipOwnershipRefusal.foreignRoutingRule(
            index: 1, ruleInput: Self.otherID, clipInput: Self.clipID
        )) { try MIDIClipInput.make(input: Self.clipID, routing: forward) }
        let reversed = try #require(MIDIRouting(rules: [third, other, own]))
        #expect(throws: MIDIClipOwnershipRefusal.foreignRoutingRule(
            index: 0, ruleInput: Self.thirdID, clipInput: Self.clipID
        )) { try MIDIClipInput.make(input: Self.clipID, routing: reversed) }
    }

    @Test
    func theMaximumRuleCountIsAcceptedAndAForeignRuleInTheLastSlotIsRefused() throws {
        let own = try #require(MIDIRoutingRule(input: Self.clipID, route: Self.route1))
        let foreign = try #require(MIDIRoutingRule(input: Self.otherID, route: Self.route1))
        let full = try #require(MIDIRouting(rules: Array(repeating: own, count: MIDIRouting.maximumRules)))
        #expect(try MIDIClipInput.make(input: Self.clipID, routing: full).routing.rules.count == 64)
        let lastForeign = try #require(MIDIRouting(
            rules: Array(repeating: own, count: MIDIRouting.maximumRules - 1) + [foreign]
        ))
        #expect(throws: MIDIClipOwnershipRefusal.foreignRoutingRule(
            index: 63, ruleInput: Self.otherID, clipInput: Self.clipID
        )) { try MIDIClipInput.make(input: Self.clipID, routing: lastForeign) }
        #expect(MIDIRouting(rules: Array(repeating: own, count: MIDIRouting.maximumRules + 1)) == nil)
    }

    @Test
    func anEmptyRoutingIsAcceptedAndAClipThroughItSendsNothing() throws {
        let input = try MIDIClipInput.make(input: Self.clipID, routing: .empty)
        var host = MIDIClipHost(ledger: try Self.ledger())
        try host.add(input, placement: try Self.placement([Self.note(0, Self.quarter)]))
        let played = try Self.render(&host, to: 12_000)
        #expect(played.routedEventCount == 1 && played.outputs.isEmpty && played.refusals.isEmpty)
        #expect(host.ledger.notes.isEmpty)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.routedEventCount == 1 && stopped.outputs.isEmpty && stopped.unownedNoteCount == 1)
    }
}
