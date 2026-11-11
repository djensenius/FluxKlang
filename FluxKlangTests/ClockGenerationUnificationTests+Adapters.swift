import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The refusals the three real validators share for a clock map of another generation.
private protocol StaleClockRefusal: Error, Equatable {
    static func clock(_ error: ClockMapError) -> Self
    static var staleMusicalMap: Self { get }
}

extension MetronomeRefusal: StaleClockRefusal {}
extension MIDIClipRefusal: StaleClockRefusal {}
extension AutomationRenderRefusal: StaleClockRefusal {}

/// The drift guard: the three real validators, which take the snapshot itself (the metronome's since #108 GU1b-1, the
/// MIDI clip's since GU1b-2, the automation renderer's since GU1b-3), refuse a clock map of another generation on the
/// axis the snapshot reports as stale first. The file name is kept from GU1 slice a, when it also tested the adapters
/// to the local mirrors; GU1b-1 to GU1b-3 deleted those mirrors, their adapters and the adapter tests.
extension ClockGenerationUnificationTests {
    private struct Verdicts: Equatable {
        let metronome: MetronomeRefusal?
        let clip: MIDIClipRefusal?
        let automation: AutomationRenderRefusal?
    }

    /// A clock map whose anchor, transport and tempo map are at the generations of `observed`.
    private static func clock(at observed: ClockGenerationSnapshot) throws -> MusicalClockMap {
        let anchor = ClockAnchor(
            sample: SampleStamp(clock: primary, generation: observed.sample, frame: 0), host: HostStamp(ticks: 0),
            musical: MusicalStamp(transport: observed.transport, musicalMap: observed.musicalMap, ticks: 0,
                                  loopIteration: 0)
        )
        let map = try MusicalMap(clock: musical, revision: observed.musicalMap,
                                 segments: [TempoSegment(atTicks: 0, microsPerQuarter: 500_000)])
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: 48_000,
                                   currentSample: observed.sample, currentTransport: observed.transport)
    }

    /// A block renderer on a lane without breakpoints: its first render checks only the generations.
    private static func automationRenderer() throws -> AutomationBlockRenderer {
        let descriptor = try ParameterDescriptor(.init(
            id: ParameterID(validated: "ch.01.fdr"), unit: .normalized, lower: 0, upper: 1, defaultValue: 0,
            ceiling: nil, curve: .linear, ramp: .step, controlClass: .live, verification: .unverified
        ))
        let lane = try AutomationLane(descriptor: descriptor, breakpoints: [])
        return AutomationBlockRenderer(
            arbiter: try ParameterArbiter(lane: lane, mode: .touch, resume: .glide(ticks: 100)), loop: nil
        )
    }

    private static func verdict<Refusal: StaleClockRefusal>(_ validate: () throws(Refusal) -> Void) -> Refusal? {
        do throws(Refusal) {
            try validate()
            return nil
        } catch {
            return error
        }
    }

    /// What each real validator says about `clock` when `live` is the live snapshot, which each of them takes as it is.
    private static func verdicts(of clock: MusicalClockMap, against live: ClockGenerationSnapshot) throws -> Verdicts {
        var renderer = try automationRenderer()
        return Verdicts(
            metronome: verdict { () throws(MetronomeRefusal) in
                try MetronomeGrid.validate(clock, current: live)
            },
            clip: verdict { () throws(MIDIClipRefusal) in
                try MIDIClipPlacement.validate(clock, current: live)
            },
            automation: verdict { () throws(AutomationRenderRefusal) in
                _ = try renderer.render(from: 0, to: 64, clock: clock, current: live)
            }
        )
    }

    private static func refusal<Refusal: StaleClockRefusal>(firstStale axis: ClockGenerationAxis?) -> Refusal? {
        switch axis {
        case .none: nil
        case .sample?: Refusal.clock(.staleSampleGeneration)
        case .transport?: Refusal.clock(.staleTransport)
        case .musicalMap?: Refusal.staleMusicalMap
        }
    }

    private static func expectedVerdicts(firstStale axis: ClockGenerationAxis?) -> Verdicts {
        Verdicts(metronome: refusal(firstStale: axis), clip: refusal(firstStale: axis),
                 automation: refusal(firstStale: axis))
    }

    /// The drift guard below runs on these: eight live snapshots, no two alike.
    @Test func theDriftGuardRunsOnEightDistinctLiveSnapshots() throws {
        let lives = try Self.triples()
        #expect(lives.count == 8)
        #expect(Set(lives).count == lives.count)
    }

    @Test func theThreeRealValidatorsRefuseAClockMapOnTheAxisTheSnapshotReportsFirst() throws {
        let values = try Self.table()
        for live in try Self.triples() {
            for mask in 0..<8 {
                let observed = Self.changing(Self.axes(inMask: mask), of: live, in: values)
                let first = ClockGenerationSnapshot.staleness(of: observed, against: live)?.firstStale
                let clock = try Self.clock(at: observed)
                #expect(try Self.verdicts(of: clock, against: live) == Self.expectedVerdicts(firstStale: first),
                        "\(live) \(mask)")
            }
        }
    }
}
