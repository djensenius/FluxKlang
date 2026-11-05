//
//  SpatialMaskTests.swift
//  FluxKlangTests
//
//  The mask invariant (#113 S1): muting or soloing speakers through the legacy
//  bridge only zeroes the masked outputs. Every survivor keeps its unmasked gain
//  bit for bit — no renormalisation, no auto-boost — across every golden
//  layout, every golden placement and every mask subset.
//

import CoreGraphics
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct SpatialMaskTests {
    /// Every non-empty subset of `count` speakers, as column index sets.
    static func subsets(of count: Int) -> [Set<Int>] {
        (1..<(1 << count)).map { bits in Set((0..<count).filter { bits & (1 << $0) != 0 }) }
    }

    static func power(_ row: [Double]) -> Double { row.reduce(0) { $0 + $1 * $1 } }

    /// Checks one masked plan against the unmasked plan: masked columns are
    /// exactly 0, survivors are bit-identical, and no row gains power.
    static func expectNoBoost(
        _ masked: SpatialRenderPlan, unmasked: SpatialRenderPlan, silenced: Set<Int>, label: String
    ) {
        #expect(masked.rowCount == unmasked.rowCount && masked.speakerCount == unmasked.speakerCount)
        for row in 0..<unmasked.rowCount {
            for column in 0..<unmasked.speakerCount {
                let gain = masked.gain(row: row, speaker: column)
                let law = unmasked.gain(row: row, speaker: column)
                #expect(gain == (silenced.contains(column) ? 0 : law), "\(label) row \(row) column \(column)")
            }
            #expect(power(masked.row(row)) <= power(unmasked.row(row)), "\(label) row \(row)")
        }
    }

    static func masks(_ columns: Set<Int>, _ ids: [UUID], _ state: SpeakerMaskState) -> [LegacySpeakerMask] {
        columns.sorted().map { LegacySpeakerMask(speaker: ids[$0], state: state) }
    }

    @Test(arguments: 0..<5)
    func mutingAnySubsetNeverBoostsSurvivors(layoutIndex: Int) throws {
        let layout = SpatialMappingTests.layouts[layoutIndex]
        let ids = try SpatialMappingTests.speakerInputs(layout).map(\.id)
        let unmasked = try SpatialMappingTests.bridge(layout).plan()
        let subsets = Self.subsets(of: ids.count)
        #expect(subsets.count == (1 << ids.count) - 1)
        for muted in subsets {
            let bridge = try SpatialMappingTests.bridge(layout, masks: Self.masks(muted, ids, .muted))
            #expect(bridge.request.masks.renormalizeSurvivors == false)
            Self.expectNoBoost(try bridge.plan(), unmasked: unmasked, silenced: muted,
                               label: "\(layout.name) muted \(muted.sorted())")
        }
    }

    @Test(arguments: 0..<5)
    func soloingAnySubsetNeverBoostsSurvivors(layoutIndex: Int) throws {
        let layout = SpatialMappingTests.layouts[layoutIndex]
        let ids = try SpatialMappingTests.speakerInputs(layout).map(\.id)
        let unmasked = try SpatialMappingTests.bridge(layout).plan()
        let all = Set(ids.indices)
        for soloed in Self.subsets(of: ids.count) {
            let bridge = try SpatialMappingTests.bridge(layout, masks: Self.masks(soloed, ids, .soloed))
            Self.expectNoBoost(try bridge.plan(), unmasked: unmasked, silenced: all.subtracting(soloed),
                               label: "\(layout.name) soloed \(soloed.sorted())")
        }
    }

    /// Mute wins over solo; muting a soloed speaker silences it without
    /// boosting the remaining soloed speakers.
    @Test func muteOverSoloNeverBoostsSurvivors() throws {
        let layout = SpatialMappingTests.ring
        let ids = try SpatialMappingTests.speakerInputs(layout).map(\.id)
        let unmasked = try SpatialMappingTests.bridge(layout).plan()
        let all = Set(ids.indices)
        for soloed in Self.subsets(of: ids.count) {
            for muted in Self.subsets(of: ids.count) where !muted.isDisjoint(with: soloed) {
                let masks = Self.masks(soloed, ids, .soloed) + Self.masks(muted, ids, .muted)
                let plan = try SpatialMappingTests.bridge(layout, masks: masks).plan()
                let silenced = all.subtracting(soloed).union(muted)
                Self.expectNoBoost(plan, unmasked: unmasked, silenced: silenced,
                                   label: "soloed \(soloed.sorted()) muted \(muted.sorted())")
            }
        }
    }

    /// The legacy model path: muting a speaker of the standard quad leaves the
    /// other speakers at exactly their unmuted gains, including a stereo source
    /// and a non-bus speaker that never pans.
    @Test func legacyModelMutesNeverBoostSurvivors() throws {
        var array = SpeakerArray.standardQuad
        array.speakers.append(Speaker(name: "Main", node: .main(1), position: CGPoint(x: 0.5, y: 0.5)))
        let sources = [
            SpatialSource(name: "Pad", mode: .stereo, left: .channel(5), right: .channel(6),
                          position: CGPoint(x: 0.6, y: 0.2), width: 0.9),
            SpatialSource(name: "Bell", left: .channel(7), position: CGPoint(x: 0.1, y: 0.8))
        ]
        let unmasked = try LegacySpatialRenderBridge.make(array: array, sources: sources).plan()
        for muted in Self.subsets(of: array.speakers.count) {
            let ids = muted.sorted().map { array.speakers[$0].id }
            let plan = try LegacySpatialRenderBridge.make(array: array, sources: sources, muted: ids).plan()
            Self.expectNoBoost(plan, unmasked: unmasked, silenced: muted, label: "model muted \(muted.sorted())")
        }
    }
}
