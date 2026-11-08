import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Which axes of an observed snapshot differ from the live one: every differing axis is reported, the first one is
/// named in the fixed order sample, transport, musical map, and a lower generation is as stale as a higher one.
extension ClockGenerationUnificationTests {
    private struct Expectation {
        let observed: ClockGenerationSnapshot
        let flags: Flags
        let first: ClockGenerationAxis
    }

    @Test func equalSnapshotsAreNotStale() throws {
        for snapshot in try Self.triples() {
            #expect(ClockGenerationSnapshot.staleness(of: snapshot, against: snapshot) == nil)
        }
    }

    @Test func aSnapshotIsStaleOnExactlyTheAxesThatDifferAndNamesTheFirstOfThem() throws {
        let values = try Self.table()
        for live in try Self.triples() {
            for mask in 1..<8 {
                let differing = Self.axes(inMask: mask)
                let observed = Self.changing(differing, of: live, in: values)
                #expect(Self.flags(of: observed, against: live) == Self.flags(differing: differing), "\(mask)")
                let first = ClockGenerationSnapshot.staleness(of: observed, against: live)?.firstStale
                #expect(first == differing.first, "\(mask)")
            }
        }
    }

    @Test func twoDifferingAxesAreBothReportedAndTheEarlierOneInTheFixedOrderIsFirst() throws {
        let one = Generation.initial
        let two = try Generation(2)
        let live = ClockGenerationSnapshot(sample: one, transport: one, musicalMap: one)
        let expectations = [
            Expectation(observed: ClockGenerationSnapshot(sample: two, transport: one, musicalMap: two),
                        flags: Flags(sample: true, transport: false, musicalMap: true), first: .sample),
            Expectation(observed: ClockGenerationSnapshot(sample: one, transport: two, musicalMap: two),
                        flags: Flags(sample: false, transport: true, musicalMap: true), first: .transport),
            Expectation(observed: ClockGenerationSnapshot(sample: two, transport: two, musicalMap: one),
                        flags: Flags(sample: true, transport: true, musicalMap: false), first: .sample),
            Expectation(observed: ClockGenerationSnapshot(sample: two, transport: two, musicalMap: two),
                        flags: Flags(sample: true, transport: true, musicalMap: true), first: .sample)
        ]
        for expectation in expectations {
            #expect(Self.flags(of: expectation.observed, against: live) == expectation.flags, "\(expectation.first)")
            let report = ClockGenerationSnapshot.staleness(of: expectation.observed, against: live)
            #expect(report?.firstStale == expectation.first, "\(expectation.flags)")
        }
    }

    @Test func aLowerGenerationThanLiveIsStaleOnEveryAxis() throws {
        let triples = try Self.triples()
        let base = try #require(triples.first)
        for (lower, higher) in Self.orderedPairs(of: try Self.table()) {
            for axis in Self.axes {
                let observed = Self.replacing(axis, of: base, with: lower)
                let live = Self.replacing(axis, of: base, with: higher)
                #expect(Self.flags(of: observed, against: live) == Self.flags(differing: [axis]), "\(axis) \(lower)")
            }
        }
    }

    @Test func aHigherGenerationThanLiveIsStaleOnEveryAxis() throws {
        let triples = try Self.triples()
        let base = try #require(triples.first)
        for (lower, higher) in Self.orderedPairs(of: try Self.table()) {
            for axis in Self.axes {
                let observed = Self.replacing(axis, of: base, with: higher)
                let live = Self.replacing(axis, of: base, with: lower)
                #expect(Self.flags(of: observed, against: live) == Self.flags(differing: [axis]), "\(axis) \(higher)")
            }
        }
    }

    @Test func stalenessDoesNotDependOnWhichOfTwoSnapshotsIsLive() throws {
        let snapshots = try Self.triples()
        for observed in snapshots {
            for live in snapshots {
                let forward = ClockGenerationSnapshot.staleness(of: observed, against: live)
                let backward = ClockGenerationSnapshot.staleness(of: live, against: observed)
                #expect(forward == backward)
            }
        }
    }
}
