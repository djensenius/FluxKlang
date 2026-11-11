import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// What these tests need of the local mirror the snapshot still replaces (the automation one until GU1b-3).
private protocol GenerationMirror: Equatable {
    init(sample: Generation, transport: Generation, musicalMap: Generation)
    init(_ snapshot: ClockGenerationSnapshot)
    var sample: Generation { get }
    var transport: Generation { get }
    var musicalMap: Generation { get }
    var snapshot: ClockGenerationSnapshot { get }
}

extension AutomationRenderGenerations: GenerationMirror {
    fileprivate var snapshot: ClockGenerationSnapshot { ClockGenerationSnapshot(self) }
}

/// The refusals the three real validators share for a clock map of another generation.
private protocol StaleClockRefusal: Error, Equatable {
    static func clock(_ error: ClockMapError) -> Self
    static var staleMusicalMap: Self { get }
}

extension MetronomeRefusal: StaleClockRefusal {}
extension MIDIClipRefusal: StaleClockRefusal {}
extension AutomationRenderRefusal: StaleClockRefusal {}

/// The adapters between the snapshot and the mirror it still replaces, in both directions, and the drift guard: the
/// snapshot and the automation mirror mean the same thing, and the three real validators (the metronome's takes the
/// snapshot itself since GU1b-1, the MIDI clip's since GU1b-2) refuse a clock map of another generation on the axis
/// the snapshot reports as stale first.
extension ClockGenerationUnificationTests {
    private struct Verdicts: Equatable {
        let metronome: MetronomeRefusal?
        let clip: MIDIClipRefusal?
        let automation: AutomationRenderRefusal?
    }

    private static func expectRoundTrips<Local: GenerationMirror>(_ type: Local.Type) throws {
        for snapshot in try triples() {
            #expect(Local(snapshot).snapshot == snapshot, "\(Local.self) \(snapshot)")
            let mirror = Local(sample: snapshot.sample, transport: snapshot.transport, musicalMap: snapshot.musicalMap)
            #expect(Local(mirror.snapshot) == mirror, "\(Local.self) \(mirror)")
        }
    }

    private static func expectFieldsAreCarriedByName<Local: GenerationMirror>(_ type: Local.Type) throws {
        for snapshot in try triples() {
            let fromSnapshot = Local(snapshot)
            #expect(fromSnapshot.sample == snapshot.sample, "\(Local.self) sample from the snapshot")
            #expect(fromSnapshot.transport == snapshot.transport, "\(Local.self) transport from the snapshot")
            #expect(fromSnapshot.musicalMap == snapshot.musicalMap, "\(Local.self) musicalMap from the snapshot")
            let mirror = Local(sample: snapshot.sample, transport: snapshot.transport, musicalMap: snapshot.musicalMap)
            let toSnapshot = mirror.snapshot
            #expect(toSnapshot.sample == mirror.sample, "\(Local.self) sample to the snapshot")
            #expect(toSnapshot.transport == mirror.transport, "\(Local.self) transport to the snapshot")
            #expect(toSnapshot.musicalMap == mirror.musicalMap, "\(Local.self) musicalMap to the snapshot")
        }
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

    /// What each real validator says about `clock` when `live` is the live snapshot, which the metronome and the MIDI
    /// clip take as it is and the automation renderer turns into its own mirror.
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
                _ = try renderer.render(from: 0, to: 64, clock: clock, current: AutomationRenderGenerations(live))
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

    @Test func theAutomationMirrorRoundTripsThroughTheSnapshotInBothDirections() throws {
        try Self.expectRoundTrips(AutomationRenderGenerations.self)
    }

    @Test func eachAutomationMirrorFieldIsTheSnapshotFieldOfTheSameNameInBothDirections() throws {
        try Self.expectFieldsAreCarriedByName(AutomationRenderGenerations.self)
    }

    /// The metronome's and the MIDI clip's side is the snapshot itself since GU1b-1 and GU1b-2; the automation side
    /// goes through its mirror.
    @Test func theAutomationMirrorAndTheSnapshotCompareEqualForTheSameInputs() throws {
        var seen: [ClockGenerationSnapshot] = []
        for input in try Self.triples() {
            let snapshot = ClockGenerationSnapshot(
                sample: input.sample, transport: input.transport, musicalMap: input.musicalMap
            )
            let automation = AutomationRenderGenerations(
                sample: input.sample, transport: input.transport, musicalMap: input.musicalMap
            )
            #expect(snapshot == ClockGenerationSnapshot(automation), "\(input)")
            seen.append(snapshot)
        }
        #expect(Set(seen).count == seen.count)
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
