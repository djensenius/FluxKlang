import Testing
@testable import FluxKlang

/// Everything an event may change, so a refusal can be shown to change nothing. Private
/// state is captured through behaviour, each probe on its own copy (see HANDOFF.md audit).
private struct EventSourceSnapshot: Equatable {
    let primaryClock: GenerationKey
    let musicalClock: ClockID?
    let generations: [GenerationKey: Generation]
    let pendingRestart: Generation?
    let restartRecord: ClockRestartRecord?
    let awaitingTransportBump: Bool
    let resume: TransportResume?
    let nominalRate: Int
    /// `resume` after recording a probe restart with previous frame 0 and, on another copy, 1;
    /// nil when the ledger refuses a record. This is where the private
    /// `restartPositionSuperseded` flag is observable.
    let resumeAfterRecordProbes: [TransportResume?]?
    let states: [ActionID: ReadinessState]
    let reasons: [ActionID: ReadinessReason]
    /// The private ready-entry count of every action, ready or not (a later `markReady` exposes it).
    let readyEntries: [ActionID: Int]
    let current: Set<ActionID>
    /// For every ledger counter, the actions its change would invalidate: the private dependencies.
    let invalidatedBy: [GenerationKey: [ActionID]]

    init(_ ledger: GenerationLedger, _ readiness: ActionReadiness) {
        primaryClock = ledger.primaryClock
        musicalClock = ledger.musicalClock
        generations = ledger.current
        pendingRestart = ledger.pendingRestart
        restartRecord = ledger.restartRecord
        awaitingTransportBump = ledger.awaitingTransportBump
        resume = ledger.resume
        nominalRate = ledger.nominalRate
        resumeAfterRecordProbes = Self.recordProbes(ledger)
        states = readiness.states
        reasons = readiness.reasons
        readyEntries = Self.entryProbe(readiness, ledger)
        current = Set(readiness.states.keys.filter { readiness.isCurrent($0, ledger: ledger) })
        invalidatedBy = ledger.current.keys.reduce(into: [:]) { result, key in
            var probe = readiness
            result[key] = probe.generationChanged(key)
        }
    }

    /// A record leaves `resume` unchanged when the flag is set and makes it
    /// `.afterRestart(previousFrame)` when it is clear. One fixed frame is masked when `resume`
    /// already equals `.afterRestart` of that frame; two different frames cannot be: set gives
    /// two equal results, clear gives two different ones. Only `previousFrame` reaches the flag.
    private static func recordProbes(_ ledger: GenerationLedger) -> [TransportResume?]? {
        guard let pending = ledger.pendingRestart,
              let clock = ClockID(rawValue: ledger.primaryClock.subject.rawValue) else { return nil }
        var results: [TransportResume?] = []
        for previousFrame: Int64 in [0, 1] {
            var probe = ledger
            let record = ClockRestartRecord(start: SampleStamp(clock: clock, generation: pending, frame: 0),
                                            host: HostStamp(ticks: 0), previousFrame: previousFrame)
            guard (try? probe.recordClockRestart(record)) != nil else { return nil }
            results.append(probe.resume)
        }
        return results
    }

    private static func entryProbe(_ readiness: ActionReadiness, _ ledger: GenerationLedger) -> [ActionID: Int] {
        readiness.states.keys.reduce(into: [:]) { result, action in
            if let entry = readiness.readyEntry(action) {
                result[action] = entry
                return
            }
            var probe = readiness
            if probe.state(action) != .preparing { try? probe.transition(action, to: .preparing) }
            try? probe.markReady(action, preparedAgainst: [], ledger: ledger)
            // `markReady` adds exactly 1 whatever the requirements, so the count maps one to one.
            if let entry = probe.readyEntry(action) { result[action] = entry - 1 }
        }
    }
}

extension ContractFixtureTests {
    struct EventSources {
        static let primary = GenerationKey(.sampleClock, ContractFixtureIDs.primaryClock)
        static let transport = GenerationKey(.transport, ContractFixtureIDs.musicalClock)
        static let source = GenerationKey(.source, ContractFixtureIDs.stream)
        static let context = GenerationKey(.context, ContractFixtureIDs.host)
        static let rate = 48_000

        static func makeLedger() throws -> GenerationLedger {
            try GenerationLedger(primaryClock: ContractFixtureIDs.primaryClock,
                                 musicalClock: ContractFixtureIDs.musicalClock,
                                 nominalRate: rate, declaring: [source, context])
        }

        static func actions(_ count: Int) throws -> [ActionID] {
            var sequence = try FixtureIDSequence<ActionTag>(prefix: "event", limit: count)
            return try (0..<count).map { _ in try sequence.next() }
        }

        static func requirement(_ key: GenerationKey, _ ledger: GenerationLedger) throws -> GenerationRequirement {
            GenerationRequirement(key: key, generation: try #require(ledger.generation(key)))
        }

        /// Prepares `action` against the current generation of every key.
        static func prepare(_ action: ActionID, on keys: [GenerationKey], ledger: GenerationLedger,
                            readiness: inout ActionReadiness) throws {
            let requirements = try keys.map { try requirement($0, ledger) }
            try readiness.transition(action, to: .preparing)
            try readiness.markReady(action, preparedAgainst: requirements, ledger: ledger)
        }

        static func expectRefusal(_ expected: FixtureEventError, applying event: ContractFixtureEvent,
                                  ledger: inout GenerationLedger, readiness: inout ActionReadiness) {
            let before = EventSourceSnapshot(ledger, readiness)
            #expect(throws: expected) {
                try FixtureEventApplier.apply(event, ledger: &ledger, readiness: &readiness)
            }
            #expect(EventSourceSnapshot(ledger, readiness) == before)
        }

        /// The restart of the primary clock into generation 2 and an anchor that agrees with it.
        static func restartEvents() throws -> (record: ClockRestartRecord, anchor: ClockAnchor) {
            var clock = try FixtureHostClock(startTicks: 0, step: 1_000_000)
            let restarted = try Generation.initial.next()
            let start = SampleStamp(clock: ContractFixtureIDs.primaryClock, generation: restarted, frame: 0)
            let record = ClockRestartRecord(start: start, host: try clock.tick(), previousFrame: 96_000)
            _ = try clock.tick()
            // One millisecond after the restart point is 48 frames at 48 kHz.
            return (record, clock.anchor(frame: 48, generation: restarted))
        }

        static func deliver(_ source: inout ScriptedEventSource) throws -> ContractFixtureEvent {
            let event = source.next()
            return try #require(event)
        }

        @Test func scriptedEventsReplayInOrder() throws {
            let events: [ContractFixtureEvent] = [
                .bump(Self.source, .sourceLost), .bump(Self.context, .contextChange),
                .bump(Self.source, .sourceReacquired), .bump(Self.transport, .locate(ticks: 15_360))
            ]
            var first = try ScriptedEventSource(capacity: 4, events: events)
            var second = try ScriptedEventSource(capacity: 4, events: events)
            let ids = try Self.actions(2)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try Self.prepare(ids[0], on: [Self.source], ledger: ledger, readiness: &readiness)
            try Self.prepare(ids[1], on: [Self.context], ledger: ledger, readiness: &readiness)

            var delivered: [ContractFixtureEvent] = []
            var stale: [[ActionID]] = []
            while let event = first.next() {
                delivered.append(event)
                stale.append(try FixtureEventApplier.apply(event, ledger: &ledger, readiness: &readiness))
            }
            let afterEnd = first.next()
            #expect(delivered == events && afterEnd == nil)
            #expect(first.deliveredCount == 4 && first.lostCount == 0)
            #expect(stale == [[ids[0]], [ids[1]], [], []])
            #expect(ledger.generation(Self.source)?.value == 3 && ledger.generation(Self.context)?.value == 2)
            #expect(ledger.generation(Self.transport)?.value == 2 && ledger.resume == .locate(ticks: 15_360))
            #expect(ids.allSatisfy { readiness.state($0) == .invalidated && readiness.reasons[$0] == .sourceChanged })

            // The replay starts from the same prepared actions and must reproduce every invalidation.
            var replayed = try Self.makeLedger()
            var replayReadiness = ActionReadiness()
            try Self.prepare(ids[0], on: [Self.source], ledger: replayed, readiness: &replayReadiness)
            try Self.prepare(ids[1], on: [Self.context], ledger: replayed, readiness: &replayReadiness)
            var redelivered: [ContractFixtureEvent] = []
            var replayStale: [[ActionID]] = []
            while let event = second.next() {
                redelivered.append(event)
                replayStale.append(try FixtureEventApplier.apply(event, ledger: &replayed, readiness: &replayReadiness))
            }
            #expect(redelivered == delivered && replayStale == stale)
            #expect(EventSourceSnapshot(replayed, replayReadiness) == EventSourceSnapshot(ledger, readiness))
        }

        @Test func sourceRejectsEventsBeyondCapacity() throws {
            let bump = ContractFixtureEvent.bump(Self.source, .sourceLost)
            #expect(throws: ScriptedEventSourceError.capacity) {
                try ScriptedEventSource(capacity: 2, events: [bump, bump, bump])
            }
            for capacity in [0, ScriptedEventSource.maximumCapacity + 1] {
                #expect(throws: ScriptedEventSourceError.invalidCapacity) {
                    try ScriptedEventSource(capacity: capacity, events: [])
                }
            }
            for capacity in [1, ScriptedEventSource.maximumCapacity] {
                let events = Array(repeating: bump, count: capacity)
                let filled = try ScriptedEventSource(capacity: capacity, events: events)
                #expect(filled.capacity == capacity && filled.pending.count == capacity)
            }

            var source = try ScriptedEventSource(capacity: 2, events: [bump, .bump(Self.context, .contextChange)])
            let full = source
            #expect(throws: ScriptedEventSourceError.capacity) { try source.inject(.duplicate) }
            #expect(source == full)

            let ids = try Self.actions(1)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try Self.prepare(ids[0], on: [Self.source], ledger: ledger, readiness: &readiness)
            let first = try Self.deliver(&source)
            let firstStale = try FixtureEventApplier.apply(first, ledger: &ledger, readiness: &readiness)
            #expect(firstStale == ids)

            // With room again, a duplicated delivery reaches the ledger as a second, real bump.
            try source.inject(.duplicate)
            #expect(source.pending.count == 2)
            let duplicate = try Self.deliver(&source)
            #expect(duplicate == .bump(Self.context, .contextChange))
            try FixtureEventApplier.apply(duplicate, ledger: &ledger, readiness: &readiness)
            try FixtureEventApplier.apply(try Self.deliver(&source), ledger: &ledger, readiness: &readiness)
            let drained = source.next()
            #expect(ledger.generation(Self.context)?.value == 3 && drained == nil)

            let empty = source
            #expect(throws: ScriptedEventSourceError.noPendingEvent) { try source.inject(.drop) }
            #expect(throws: ScriptedEventSourceError.noPendingEvent) { try source.inject(.duplicate) }
            #expect(throws: ScriptedEventSourceError.noPendingEvent) { try source.inject(.overflow) }
            #expect(throws: ScriptedEventSourceError.nothingToSwap) { try source.inject(.swapNext) }
            #expect(source == empty)

            // One pending event with earlier loss and delivery history: the swap is refused and nothing changes.
            var single = try ScriptedEventSource(capacity: 3, events: [bump, first, duplicate])
            try single.inject(.drop)
            _ = single.next()
            let singleton = single
            #expect(throws: ScriptedEventSourceError.nothingToSwap) { try single.inject(.swapNext) }
            #expect(single == singleton && single.pending == [duplicate] && single.deliveredCount == 1)
            #expect(single.droppedCount == 1 && single.overflowCount == 0 && single.lost.entries == [bump])
        }

        @Test func duplicateIsDeliveredNextToItsOriginal() throws {
            let sourceBump = ContractFixtureEvent.bump(Self.source, .sourceLost)
            let contextBump = ContractFixtureEvent.bump(Self.context, .contextChange)
            var source = try ScriptedEventSource(capacity: 3, events: [sourceBump, contextBump])
            try source.inject(.duplicate)
            #expect(source.pending == [sourceBump, sourceBump, contextBump])

            let ids = try Self.actions(2)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try Self.prepare(ids[0], on: [Self.source], ledger: ledger, readiness: &readiness)
            try Self.prepare(ids[1], on: [Self.context], ledger: ledger, readiness: &readiness)
            var delivered: [ContractFixtureEvent] = []
            var stale: [[ActionID]] = []
            while let event = source.next() {
                delivered.append(event)
                stale.append(try FixtureEventApplier.apply(event, ledger: &ledger, readiness: &readiness))
            }
            #expect(delivered == [sourceBump, sourceBump, contextBump] && stale == [[ids[0]], [], [ids[1]]])
            #expect(ledger.generation(Self.source)?.value == 3 && ledger.generation(Self.context)?.value == 2)
        }

        @Test func droppedEventIsCountedNotSilent() throws {
            let lostBump = ContractFixtureEvent.bump(Self.source, .sourceLost)
            var source = try ScriptedEventSource(capacity: 2, events: [lostBump, .bump(Self.context, .contextChange)])
            let ids = try Self.actions(2)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try Self.prepare(ids[0], on: [Self.source], ledger: ledger, readiness: &readiness)
            try Self.prepare(ids[1], on: [Self.context], ledger: ledger, readiness: &readiness)

            try source.inject(.drop)
            #expect(source.droppedCount == 1 && source.lostCount == 1 && source.lost.entries == [lostBump])
            while let event = source.next() {
                try FixtureEventApplier.apply(event, ledger: &ledger, readiness: &readiness)
            }
            // The ledger never saw the lost bump, so only the count reveals that the source action is stale.
            #expect(readiness.isCurrent(ids[0], ledger: ledger) && !readiness.isCurrent(ids[1], ledger: ledger))
            #expect(ledger.generation(Self.source) == .initial && source.deliveredCount == 1)

            // A lost event past the record's capacity is still counted.
            var repeated = try ScriptedEventSource(capacity: 2, events: [lostBump, lostBump])
            _ = repeated.next()
            for _ in 0..<3 {
                try repeated.inject(.duplicate)
                try repeated.inject(.drop)
            }
            #expect(repeated.droppedCount == 3 && repeated.lost.entries.count == 2 && repeated.lost.droppedCount == 1)

            let contextBump = ContractFixtureEvent.bump(Self.context, .contextChange)
            let locate = ContractFixtureEvent.bump(Self.transport, .locate(ticks: 0))
            var overflowing = try ScriptedEventSource(capacity: 3, events: [lostBump, contextBump, locate])
            _ = overflowing.next()
            try overflowing.inject(.overflow)
            #expect(overflowing.overflowCount == 2 && overflowing.droppedCount == 0 && overflowing.lostCount == 2)
            #expect(overflowing.lost.entries == [contextBump, locate] && overflowing.lost.droppedCount == 0)
            let afterOverflow = overflowing.next()
            #expect(overflowing.pending.isEmpty && afterOverflow == nil && overflowing.deliveredCount == 1)

            // An overflow after an earlier drop keeps recording until the record is full, then counts.
            var mixed = try ScriptedEventSource(capacity: 2, events: [lostBump, contextBump])
            try mixed.inject(.drop)
            try mixed.inject(.duplicate)
            try mixed.inject(.overflow)
            #expect(mixed.droppedCount == 1 && mixed.overflowCount == 2 && mixed.lostCount == 3)
            #expect(mixed.lost.entries == [lostBump, contextBump] && mixed.lost.droppedCount == 1)
        }

        @Test func duplicatedPrimaryBumpIsRefusedWhileRestartPending() throws {
            let restart = ContractFixtureEvent.bump(Self.primary, .deviceRestart)
            var source = try ScriptedEventSource(capacity: 2, events: [restart])
            try source.inject(.duplicate)
            let ids = try Self.actions(1)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try Self.prepare(ids[0], on: [Self.primary, Self.context], ledger: ledger, readiness: &readiness)

            let first = try Self.deliver(&source)
            let firstStale = try FixtureEventApplier.apply(first, ledger: &ledger, readiness: &readiness)
            #expect(firstStale == ids)
            #expect(ledger.hasRestartObligations && ledger.generation(Self.primary)?.value == 2)

            let duplicate = try Self.deliver(&source)
            Self.expectRefusal(.ledger(.restartObligationsPending), applying: duplicate,
                               ledger: &ledger, readiness: &readiness)
            #expect(ledger.generation(Self.primary)?.value == 2 && readiness.state(ids[0]) == .invalidated)
            // A refused rate change must not change the declared rate either; the snapshot covers it.
            Self.expectRefusal(.ledger(.restartObligationsPending),
                               applying: .bump(Self.primary, .rateChange(nominalRate: 96_000)),
                               ledger: &ledger, readiness: &readiness)

            // Once the record and transport bump exist, the same primary change is accepted.
            let (record, _) = try Self.restartEvents()
            try FixtureEventApplier.apply(.restartRecord(record), ledger: &ledger, readiness: &readiness)
            try FixtureEventApplier.apply(.bump(Self.transport, .clockRestart), ledger: &ledger, readiness: &readiness)
            #expect(!ledger.hasRestartObligations)
            try FixtureEventApplier.apply(duplicate, ledger: &ledger, readiness: &readiness)
            #expect(ledger.generation(Self.primary)?.value == 3 && ledger.hasRestartObligations)
        }

        @Test func refusedPrimaryBumpKeepsTransportRestartSupersession() throws {
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try FixtureEventApplier.apply(.bump(Self.primary, .deviceRestart), ledger: &ledger, readiness: &readiness)
            try FixtureEventApplier.apply(.bump(Self.transport, .transportRestart), ledger: &ledger,
                                          readiness: &readiness)
            #expect(ledger.hasRestartObligations && ledger.resume == nil)
            Self.expectRefusal(.ledger(.restartObligationsPending), applying: .bump(Self.primary, .wake),
                               ledger: &ledger, readiness: &readiness)

            // The transport restart superseded the restart position, so the record must not set one.
            let (record, _) = try Self.restartEvents()
            try FixtureEventApplier.apply(.restartRecord(record), ledger: &ledger, readiness: &readiness)
            #expect(ledger.restartRecord == record && ledger.resume == nil)
        }

        @Test func refusedPrimaryBumpKeepsRestartPositionAfterEarlierRestart() throws {
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try FixtureEventApplier.apply(.bump(Self.primary, .deviceRestart), ledger: &ledger, readiness: &readiness)
            let (earlier, _) = try Self.restartEvents()
            let atZero = ClockRestartRecord(start: earlier.start, host: earlier.host, previousFrame: 0)
            try FixtureEventApplier.apply(.restartRecord(atZero), ledger: &ledger, readiness: &readiness)
            try FixtureEventApplier.apply(.bump(Self.transport, .clockRestart), ledger: &ledger, readiness: &readiness)
            try FixtureEventApplier.apply(.bump(Self.primary, .wake), ledger: &ledger, readiness: &readiness)
            // A new restart is pending while the earlier one left `.afterRestart(previousFrame: 0)`.
            #expect(ledger.resume == .afterRestart(previousFrame: 0) && ledger.restartRecord == nil)
            #expect(ledger.pendingRestart?.value == 3)
            Self.expectRefusal(.ledger(.restartObligationsPending), applying: .bump(Self.primary, .wake),
                               ledger: &ledger, readiness: &readiness)

            let pending = try #require(ledger.pendingRestart)
            let start = SampleStamp(clock: ContractFixtureIDs.primaryClock, generation: pending, frame: 0)
            let next = ClockRestartRecord(start: start, host: earlier.host, previousFrame: 5)
            try FixtureEventApplier.apply(.restartRecord(next), ledger: &ledger, readiness: &readiness)
            #expect(ledger.resume == .afterRestart(previousFrame: 5))
        }

        @Test func swappedRestartEventsRespectLedgerObligations() throws {
            let (record, anchor) = try Self.restartEvents()
            let events: [ContractFixtureEvent] = [
                .bump(Self.primary, .deviceRestart), .restartRecord(record),
                .bump(Self.transport, .clockRestart), .anchor(anchor, nominalRate: Self.rate)
            ]

            // A record delivered before its primary change is refused and the change stays unrecorded.
            var early = try ScriptedEventSource(capacity: 4, events: events)
            try early.inject(.swapNext)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            Self.expectRefusal(.ledger(.noPendingRestart), applying: try Self.deliver(&early),
                               ledger: &ledger, readiness: &readiness)
            for _ in 0..<2 {
                try FixtureEventApplier.apply(try Self.deliver(&early), ledger: &ledger, readiness: &readiness)
            }
            #expect(ledger.hasRestartObligations && ledger.restartRecord == nil)
            Self.expectRefusal(.firstAnchorRestartIncomplete, applying: try Self.deliver(&early),
                               ledger: &ledger, readiness: &readiness)
            Self.expectRefusal(.ledger(.restartObligationsPending), applying: .bump(Self.primary, .wake),
                               ledger: &ledger, readiness: &readiness)

            // Transport bump and record may arrive in either order; the anchor waits for both.
            var swapped = try ScriptedEventSource(capacity: 4, events: events)
            var ordered = try Self.makeLedger()
            var orderedReadiness = ActionReadiness()
            try FixtureEventApplier.apply(try Self.deliver(&swapped), ledger: &ordered, readiness: &orderedReadiness)
            try swapped.inject(.swapNext)
            let transportBump = try Self.deliver(&swapped)
            #expect(transportBump == .bump(Self.transport, .clockRestart))
            try FixtureEventApplier.apply(transportBump, ledger: &ordered, readiness: &orderedReadiness)
            #expect(ordered.hasRestartObligations)
            Self.expectRefusal(.firstAnchorRestartIncomplete, applying: .anchor(anchor, nominalRate: Self.rate),
                               ledger: &ordered, readiness: &orderedReadiness)
            try FixtureEventApplier.apply(try Self.deliver(&swapped), ledger: &ordered, readiness: &orderedReadiness)
            #expect(!ordered.hasRestartObligations && ordered.resume == .afterRestart(previousFrame: 96_000))
            let anchorStale = try FixtureEventApplier.apply(try Self.deliver(&swapped), ledger: &ordered,
                                                            readiness: &orderedReadiness)
            // Stateless policy: the restart point itself, delivered after that later anchor, is accepted too.
            let point = ClockAnchor(sample: record.start, host: record.host)
            let pointStale = try FixtureEventApplier.apply(.anchor(point, nominalRate: Self.rate), ledger: &ordered,
                                                           readiness: &orderedReadiness)
            #expect(anchorStale.isEmpty && pointStale.isEmpty)

            let restarted = anchor.sample.generation
            let disagreeing = ClockAnchor(sample: SampleStamp(clock: anchor.sample.clock, generation: restarted,
                                                              frame: 1_000_000), host: anchor.host)
            Self.expectRefusal(.firstAnchorRejected, applying: .anchor(disagreeing, nominalRate: Self.rate),
                               ledger: &ordered, readiness: &orderedReadiness)
            // The ledger's own rate check runs: the agreeing anchor at another rate is refused.
            Self.expectRefusal(.firstAnchorRejected, applying: .anchor(anchor, nominalRate: 96_000),
                               ledger: &ordered, readiness: &orderedReadiness)
            let stale = ClockAnchor(sample: SampleStamp(clock: anchor.sample.clock, generation: .initial, frame: 48),
                                    host: anchor.host)
            Self.expectRefusal(.staleAnchor, applying: .anchor(stale, nominalRate: Self.rate), ledger: &ordered,
                               readiness: &orderedReadiness)
        }

        @Test func firstAnchorMustBeOnThePrimaryClock() throws {
            var clock = try FixtureHostClock(startTicks: 0, step: 1_000_000)
            _ = try clock.tick()
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            let current = try #require(ledger.generation(ledger.primaryClock))
            let musical = clock.anchor(frame: 48, generation: current, clock: ContractFixtureIDs.musicalClock)
            Self.expectRefusal(.anchorOffPrimaryClock, applying: .anchor(musical, nominalRate: Self.rate),
                               ledger: &ledger, readiness: &readiness)

            // The starting generation has no restart point, so a primary anchor is accepted as is.
            let primary = clock.anchor(frame: 48, generation: current)
            let before = EventSourceSnapshot(ledger, readiness)
            let stale = try FixtureEventApplier.apply(.anchor(primary, nominalRate: Self.rate),
                                                      ledger: &ledger, readiness: &readiness)
            #expect(stale.isEmpty && EventSourceSnapshot(ledger, readiness) == before)
            #expect(ledger.pendingRestart == nil && ledger.restartRecord == nil)
        }

        @Test func firstAnchorIsCheckedOnTheGivenTimebase() throws {
            // At 125/3 ns per tick, 24,000,000 ticks are one second: 48,000 frames at 48 kHz.
            let timebase = HostTimebase(numer: 125, denom: 3)
            var clock = try FixtureHostClock(startTicks: 0, step: 24_000_000, timebase: timebase)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try FixtureEventApplier.apply(.bump(Self.primary, .deviceRestart), ledger: &ledger, readiness: &readiness)
            let restarted = try #require(ledger.generation(Self.primary))
            let start = SampleStamp(clock: ContractFixtureIDs.primaryClock, generation: restarted, frame: 0)
            let record = ClockRestartRecord(start: start, host: try clock.tick(), previousFrame: 0)
            try FixtureEventApplier.apply(.restartRecord(record), ledger: &ledger, readiness: &readiness)
            try FixtureEventApplier.apply(.bump(Self.transport, .clockRestart), ledger: &ledger, readiness: &readiness)
            _ = try clock.tick()
            let anchor = ContractFixtureEvent.anchor(clock.anchor(frame: 48_000, generation: restarted),
                                                     nominalRate: Self.rate)

            // The default 1:1 timebase reads the same ticks as 24 ms, so the anchor disagrees there.
            Self.expectRefusal(.firstAnchorRejected, applying: anchor, ledger: &ledger, readiness: &readiness)
            let before = EventSourceSnapshot(ledger, readiness)
            let stale = try FixtureEventApplier.apply(anchor, ledger: &ledger, readiness: &readiness,
                                                      timebase: clock.timebase)
            #expect(stale.isEmpty && EventSourceSnapshot(ledger, readiness) == before)
        }

        @Test func contextBumpMakesContextRequirementStale() throws {
            let ids = try Self.actions(2)
            var ledger = try Self.makeLedger()
            var readiness = ActionReadiness()
            try Self.prepare(ids[0], on: [Self.context], ledger: ledger, readiness: &readiness)
            try Self.prepare(ids[1], on: [Self.source], ledger: ledger, readiness: &readiness)
            let preparedContext = try Self.requirement(Self.context, ledger)

            let stale = try FixtureEventApplier.apply(.bump(Self.context, .contextChange),
                                                      ledger: &ledger, readiness: &readiness)
            #expect(stale == [ids[0]] && !ledger.isCurrent(preparedContext))
            #expect(readiness.state(ids[0]) == .invalidated && readiness.reasons[ids[0]] == .sourceChanged)
            #expect(!readiness.isCurrent(ids[0], ledger: ledger) && readiness.isCurrent(ids[1], ledger: ledger))

            // Re-prepared against the new context, the action must survive refused context bumps untouched.
            try Self.prepare(ids[0], on: [Self.context], ledger: ledger, readiness: &readiness)
            #expect(readiness.isCurrent(ids[0], ledger: ledger) && ledger.generation(Self.context)?.value == 2)
            Self.expectRefusal(.ledger(.reasonDoesNotMatchKind(Self.context)),
                               applying: .bump(Self.context, .sourceLost), ledger: &ledger, readiness: &readiness)
            let undeclared = GenerationKey(.context, ContractFixtureIDs.device)
            Self.expectRefusal(.ledger(.undeclaredCounter(undeclared)), applying: .bump(undeclared, .contextChange),
                               ledger: &ledger, readiness: &readiness)
            #expect(readiness.state(ids[0]) == .ready && readiness.isCurrent(ids[0], ledger: ledger))
            #expect(ledger.generation(Self.context)?.value == 2)
        }
    }
}
