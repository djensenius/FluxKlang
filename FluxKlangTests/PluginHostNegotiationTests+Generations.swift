import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginHostNegotiationTests {
    private static func generationValues(_ value: CapabilityGeneration) -> [Int] {
        [value.resources.value, value.sampleRate.value, value.latency.value]
    }

    @Test("generation axes list resources, sampleRate and latency with their raw values")
    func generationAxesCasesAndRawValues() {
        #expect(CapabilityAxis.allCases == [.resources, .sampleRate, .latency])
        #expect(CapabilityAxis.allCases.map(\.rawValue) == ["resources", "sampleRate", "latency"])
    }

    @Test("generation initial has every axis at generation 1")
    func generationInitialIsOneOnEveryAxis() {
        #expect(Self.generationValues(.initial) == [1, 1, 1])
        #expect(CapabilityGeneration.initial.resources == Generation.initial)
        #expect(CapabilityGeneration.initial.sampleRate == Generation.initial)
        #expect(CapabilityGeneration.initial.latency == Generation.initial)
    }

    @Test("generation advancing steps only the named axis by exactly one")
    func generationAdvancingStepsOnlyThatAxis() throws {
        let start = try Self.makeGeneration(10, 20, 30)
        let expected: [CapabilityAxis: [Int]] = [
            .resources: [11, 20, 30], .sampleRate: [10, 21, 30], .latency: [10, 20, 31]
        ]
        for axis in CapabilityAxis.allCases {
            let advanced = try start.advancing(axis)
            #expect(Self.generationValues(advanced) == expected[axis])
            #expect(Self.generationValues(start) == [10, 20, 30])
        }
    }

    @Test("generation advancing at the maximum minus one succeeds and the next advance overflows unchanged")
    func generationAdvancingOverflowBoundary() throws {
        let top = Generation.maximumValue
        let nearTop = try Self.makeGeneration(top - 1, top - 1, top - 1)
        for axis in CapabilityAxis.allCases {
            let atTop = try nearTop.advancing(axis)
            let steppedValues = Self.generationValues(atTop).filter { $0 == top }
            #expect(steppedValues == [top])
            let before = atTop
            #expect(throws: RevisionError.overflow) { try atTop.advancing(axis) }
            #expect(atTop == before)
            // The other axes still have headroom after one axis saturated.
            let others = CapabilityAxis.allCases.filter { $0 != axis }
            for other in others { #expect(throws: Never.self) { try atTop.advancing(other) } }
        }
    }

    @Test("generation staleAxes lists exactly the differing axes for all eight combinations")
    func generationStaleAxesForEveryCombination() throws {
        let local = try Self.makeGeneration(1, 1, 1)
        let table: [(live: [Int], stale: [CapabilityAxis])] = [
            ([1, 1, 1], []),
            ([2, 1, 1], [.resources]),
            ([1, 2, 1], [.sampleRate]),
            ([1, 1, 2], [.latency]),
            ([2, 2, 1], [.resources, .sampleRate]),
            ([2, 1, 2], [.resources, .latency]),
            ([1, 2, 2], [.sampleRate, .latency]),
            ([2, 2, 2], [.resources, .sampleRate, .latency])
        ]
        for row in table {
            let live = try Self.makeGeneration(row.live[0], row.live[1], row.live[2])
            #expect(local.staleAxes(comparedTo: live) == row.stale)
        }
    }

    @Test("generation staleAxes treats an older and a newer live value alike, by equality")
    func generationStaleAxesIsEqualityNotOrder() throws {
        let local = try Self.makeGeneration(5, 5, 5)
        let older = try Self.makeGeneration(4, 5, 5)
        let newer = try Self.makeGeneration(6, 5, 5)
        #expect(local.staleAxes(comparedTo: older) == [.resources])
        #expect(local.staleAxes(comparedTo: newer) == [.resources])
        #expect(local.staleAxes(comparedTo: local).isEmpty)
    }

    @Test("generation advancing then comparing marks exactly the advanced axis stale")
    func generationAdvancedAxisIsTheOnlyStaleAxis() throws {
        for axis in CapabilityAxis.allCases {
            let live = try CapabilityGeneration.initial.advancing(axis)
            #expect(CapabilityGeneration.initial.staleAxes(comparedTo: live) == [axis])
        }
    }
}
