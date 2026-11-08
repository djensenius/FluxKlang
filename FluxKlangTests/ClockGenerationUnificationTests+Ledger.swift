import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The ledger-backed read of a snapshot: the values read, and the refusals and the order they are made in.
extension ClockGenerationUnificationTests {
    /// Counters of `keys`, each at the first generation.
    static func counters(_ keys: [GenerationKey]) -> [GenerationKey: Generation] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, Generation.initial) })
    }

    /// Reads the seam on the primary and musical clocks of the fixtures.
    static func liveRead(counters: [GenerationKey: Generation]) -> Live {
        liveRead(primaryClock: primaryKey, musicalClock: musical, counters: counters)
    }

    /// Bumps `key` once and checks that the snapshot read before is stale on exactly `axis`: in the report, in its
    /// first stale axis and in the ledger's own `isCurrent` for each counter.
    private static func expectOnlyStale(_ axis: ClockGenerationAxis, afterBumping key: GenerationKey,
                                        for reason: GenerationBumpReason) throws {
        var ledger = try Self.ledger()
        let before = try ClockGenerationSnapshot.live(from: ledger)
        try ledger.bump(key, reason: reason)
        let after = try ClockGenerationSnapshot.live(from: ledger)
        #expect(Self.flags(of: before, against: after) == Self.flags(differing: [axis]))
        #expect(ClockGenerationSnapshot.staleness(of: before, against: after)?.firstStale == axis)
        #expect(ClockGenerationSnapshot.staleness(of: after, against: after) == nil)
        let keys = [Self.primaryKey, Self.transportKey, Self.mapKey]
        for (probe, counter) in zip(Self.axes, keys) {
            let requirement = GenerationRequirement(key: counter, generation: Self.generation(probe, of: before))
            #expect(ledger.isCurrent(requirement) == (probe != axis), "\(probe)")
        }
    }

    @Test func eachAxisIsReadFromItsOwnCounterOfTheLedger() throws {
        var ledger = try Self.ledger()
        try ledger.bump(Self.primaryKey, reason: .deviceRestart)
        for _ in 0..<2 { try ledger.bump(Self.transportKey, reason: .locate(ticks: 0)) }
        for _ in 0..<3 { try ledger.bump(Self.mapKey, reason: .tempoEdit) }
        let expected = try ClockGenerationSnapshot(
            sample: Generation(2), transport: Generation(3), musicalMap: Generation(4)
        )
        #expect(Self.liveRead(of: ledger) == .read(expected))
    }

    @Test func theLiveReadCopiesTheGenerationsOfTheTableUnchangedAndIgnoresOtherCounters() throws {
        let others = [GenerationKey(.source, Self.primary), GenerationKey(.sampleClock, Self.musical)]
        for snapshot in try Self.triples() {
            var counters = Self.counters(others)
            counters[Self.primaryKey] = snapshot.sample
            counters[Self.transportKey] = snapshot.transport
            counters[Self.mapKey] = snapshot.musicalMap
            #expect(Self.liveRead(counters: counters) == .read(snapshot))
        }
    }

    @Test func aLedgerWithoutAMusicalClockIsRefusedWithNoMusicalClock() throws {
        var ledger = try Self.ledger(musicalClock: nil)
        #expect(ledger.generation(Self.primaryKey) == .initial)
        #expect(Self.liveRead(of: ledger) == .refused(.noMusicalClock))
        try ledger.bump(Self.primaryKey, reason: .deviceRestart)
        #expect(Self.liveRead(of: ledger) == .refused(.noMusicalClock))
    }

    @Test func noMusicalClockIsReportedBeforeAMissingSampleCounter() {
        let read = Self.liveRead(primaryClock: Self.primaryKey, musicalClock: nil, counters: [:])
        #expect(read == .refused(.noMusicalClock))
    }

    @Test func aMissingSampleCounterIsReportedBeforeAMissingTransportCounter() {
        let read = Self.liveRead(counters: Self.counters([Self.mapKey]))
        #expect(read == .refused(.undeclared(Self.primaryKey)))
    }

    @Test func aMissingTransportCounterIsReportedBeforeAMissingMapCounter() {
        let read = Self.liveRead(counters: Self.counters([Self.primaryKey]))
        #expect(read == .refused(.undeclared(Self.transportKey)))
    }

    @Test func aMissingSampleCounterIsReportedBeforeAMissingMapCounter() {
        let read = Self.liveRead(counters: Self.counters([Self.transportKey]))
        #expect(read == .refused(.undeclared(Self.primaryKey)))
    }

    @Test func eachMissingCounterIsNamedByItsOwnKeyAndOtherKeysDoNotStandInForTheSampleCounter() {
        let all = [Self.primaryKey, Self.transportKey, Self.mapKey]
        for missing in all {
            let present = all.filter { $0 != missing }
            #expect(Self.liveRead(counters: Self.counters(present)) == .refused(.undeclared(missing)), "\(missing)")
        }
        let wrongCounters = [
            GenerationKey(.source, Self.primary), GenerationKey(.sampleClock, Self.musical),
            GenerationKey(.transport, Self.primary), GenerationKey(.musicalMap, Self.primary)
        ]
        #expect(Self.liveRead(counters: Self.counters(wrongCounters)) == .refused(.undeclared(Self.primaryKey)))
    }

    @Test func aRealLedgerIsReadWithAMusicalClockAndRefusedAsWithoutOneOtherwise() throws {
        let extra = [GenerationKey(.source, Self.primary), GenerationKey(.context, Self.primary)]
        var bumped = try Self.ledger(declaring: extra)
        try bumped.bump(Self.primaryKey, reason: .deviceRestart)
        try bumped.bump(Self.mapKey, reason: .externalTempo)
        let withMusicalClock = try [Self.ledger(), Self.ledger(declaring: extra), bumped]
        for ledger in withMusicalClock {
            #expect(Self.liveRead(of: ledger).snapshot != nil)
        }
        let withoutMusicalClock = try [Self.ledger(musicalClock: nil), Self.ledger(musicalClock: nil, declaring: extra)]
        for ledger in withoutMusicalClock {
            #expect(Self.liveRead(of: ledger) == .refused(.noMusicalClock))
        }
    }

    @Test func aTempoEditMakesOnlyTheMusicalMapStale() throws {
        try Self.expectOnlyStale(.musicalMap, afterBumping: Self.mapKey, for: .tempoEdit)
    }

    @Test func aLocateMakesOnlyTheTransportStale() throws {
        try Self.expectOnlyStale(.transport, afterBumping: Self.transportKey, for: .locate(ticks: 0))
    }

    @Test func aDeviceRestartMakesOnlyTheSampleClockStale() throws {
        try Self.expectOnlyStale(.sample, afterBumping: Self.primaryKey, for: .deviceRestart)
    }
}
